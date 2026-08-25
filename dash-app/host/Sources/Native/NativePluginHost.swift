import DashSDK
import Foundation

/// 插件 dylib 的 C 入口签名（M2 定稿，见 `docs/native-abi.md` §1）。
private typealias DashPluginEntry = @convention(c) () -> UnsafeMutableRawPointer

/// 一个在役的插件世代。
private struct LoadedPlugin {
    let name: String
    let module: String
    let contentHash: String
    let generation: Int
    /// 世代产物目录（下游插件 -I/-L 指向它）。
    let directory: URL
    /// `activate` 返回的 handle。**壳持有它 = 本代在役，壳松手 = 本代退休**：
    /// 它析构时把 activate 期间攒下的注册与订阅一并撤销。
    let handle: AnyObject?
    /// 插件对象本身。与 handle 一起释放。
    let plugin: DashPlugin
    let host: DashHost
    /// dlopen 的 image。**永不 dlclose**——对 Swift 不安全（类型元数据仍被引用）；
    /// 代码页泄漏式退休，实例由 ARC 正常回收（M2 断言 3b）。
    let image: UnsafeMutableRawPointer
}

/// 壳内的原生插件宿主：桥 ↔ 编译机 ↔ 装载器 ↔ registry 的接线板。
///
/// 壳对插件世界的全部认知都在这里，`MainWindowController` 只跟它要一个
/// `root` 槽的视图，以及一句"boot 门控过了没有"。
@MainActor
final class NativePluginHost {
    // 共享给所有插件、跨世代稳定的三件套（住在 DashSDK dylib 里）。
    let registry = DashRegistry()
    let objects = DashObjects()
    let events = DashEventBus()

    /// 首次 snapshot 处理完毕（成功或失败都算）。boot 门控等的就是它。
    private(set) var didSettle = false
    /// registry 有变动 / 门控状态变化时调用（壳据此刷新 root 挂载）。
    var onUpdate: (() -> Void)?

    private let bridge = BridgeClient()
    private let compiler: CompilerService
    private let ledger: GenerationLedger
    private let storeDir: URL

    private var loaded: [String: LoadedPlugin] = [:]
    private var generationCounter = 0
    private var applying = false
    private var snapshotPending = false
    private var lastVersion = -1

    init() {
        let base = DashPaths.appSupport.appendingPathComponent("native-plugins", isDirectory: true)
        storeDir = base.appendingPathComponent("store", isDirectory: true)
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        compiler = CompilerService(
            modulesDir: Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/DashModules", isDirectory: true),
            frameworksDir: Bundle.main.bundleURL
                .appendingPathComponent("Contents/Frameworks", isDirectory: true),
            generationsDir: base.appendingPathComponent("generations", isDirectory: true))
        ledger = GenerationLedger(url: base.appendingPathComponent("ledger.json"))

        bridge.onFrame = { [weak self] frame in self?.handle(frame) }
        bridge.onConnected = { [weak self] connected in
            guard let self else { return }
            if connected {
                Log.write("桥已握手，拉取 snapshot", to: DashPaths.logURL, tag: "bridge")
                self.bridge.send(["type": "snapshot"])
            } else {
                // 断桥不动 registry：UI 保持最后状态，重连后重新拉全量即可。
                Log.write("桥断开（registry 保持不动）", to: DashPaths.logURL, tag: "bridge")
            }
            self.onUpdate?()
        }
    }

    var isBridgeConnected: Bool { bridge.isConnected }

    // MARK: - 生命周期

    func connect(baseURL: URL, bridgePath: String) {
        objects.setObject(DashObjects.Key.endpoint, baseURL as NSURL)
        events.emit(DashEventBus.Topic.endpointChanged, ["httpBase": baseURL.absoluteString])
        bridge.stop()
        bridge.start(baseURL: baseURL, path: bridgePath)
    }

    func disconnect() {
        bridge.stop()
    }

    /// 请求 dsh 重启自己（⌘⇧R 的升级版；dsh 在前台终端时等同于退出）。
    func requestRestartDsh() {
        bridge.send(["type": "restart-dsh"])
    }

    // MARK: - 帧处理

    private func handle(_ frame: [String: Any]) {
        switch frame["type"] as? String {
        case "hello":
            break // 连接状态由 BridgeClient 自己翻牌

        case "snapshot-result":
            apply(snapshot: frame)

        case "changed":
            // 只发版本不发载荷：重新拉一次全量（桥对客户端零状态）。
            let version = frame["version"] as? Int ?? -1
            guard version != lastVersion else { return }
            bridge.send(["type": "snapshot"])

        case "push":
            guard let plugin = frame["plugin"] as? String,
                  let channel = frame["channel"] as? String else { return }
            loaded[plugin]?.host.bridge.deliver(
                channel: channel, payload: frame["payload"] as? [String: Any] ?? [:])

        default:
            break // 未知帧忽略不崩
        }
    }

    private func apply(snapshot frame: [String: Any]) {
        guard let rows = frame["plugins"] as? [[String: Any]] else { return }
        let version = frame["version"] as? Int ?? -1
        let sources: [PluginSource] = rows.compactMap { row in
            guard let name = row["name"] as? String,
                  let module = row["module"] as? String,
                  let files = row["files"] as? [String: String],
                  let hash = row["contentHash"] as? String else { return nil }
            return PluginSource(name: name, module: module, files: files,
                                deps: row["swiftDeps"] as? [String] ?? [],
                                bridgeHash: hash,
                                schemaVersion: row["schemaVersion"] as? Int ?? 1)
        }

        // 同一时刻只跑一轮：编译是异步的，两轮叠罗汉会把世代顺序搅乱。
        guard !applying else { snapshotPending = true; return }
        applying = true
        lastVersion = version

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reconcile(sources)
            self.applying = false
            self.didSettle = true
            self.onUpdate?()
            if self.snapshotPending {
                self.snapshotPending = false
                self.bridge.send(["type": "snapshot"])
            }
        }
    }

    /// 把在役世代对齐到 snapshot。sources **已是拓扑序**（依赖在前）。
    private func reconcile(_ sources: [PluginSource]) async {
        var resolved: [String: CompiledPlugin] = [:]

        for source in sources {
            let hash = await compiler.contentHash(for: source)
            if let current = loaded[source.name], current.contentHash == hash {
                // 没变。但下游要拿它的 module 名做 -module-alias，得补进 resolved。
                resolved[source.name] = CompiledPlugin(
                    name: source.name, module: current.module, directory: current.directory,
                    dylibURL: current.directory
                        .appendingPathComponent("lib\(current.module).dylib"),
                    contentHash: hash, fromCache: true)
                continue
            }

            do {
                let compiled = try await compiler.compile(source, resolved: resolved)
                resolved[source.name] = compiled
                try swap(to: compiled, source: source)
                bridge.send(["type": "compile-result", "plugin": source.name,
                             "contentHash": compiled.contentHash, "ok": true,
                             "log": compiled.fromCache ? "缓存命中" : ""])
            } catch {
                let log = (error as? CompileError).flatMap { if case .failed(let l) = $0 { return l } else { return nil } }
                    ?? "\(error)"
                Log.write("插件 \(source.name) 装载失败：\(log.suffix(2000))",
                          to: DashPaths.logURL, tag: "plugin")
                bridge.send(["type": "compile-result", "plugin": source.name,
                             "contentHash": hash, "ok": false, "log": log])
                // 失败即保持上一代在役（§0.5-5：坏的插件不许拖垮系统）。
            }
        }

        // snapshot 里没有的 = 被禁用/卸载：松手让它退休。
        let names = Set(sources.map(\.name))
        for (name, plugin) in loaded where !names.contains(name) {
            Log.write("插件 \(name) 已从登记表消失，退休第 \(plugin.generation) 代",
                      to: DashPaths.logURL, tag: "plugin")
            loaded.removeValue(forKey: name)
            ledger.recordRetire(plugin: name, module: plugin.module)
        }
    }

    /// 世代替换时序（§6.3）：装载 → activate（新注册覆盖旧槽）→ 松手放旧代。
    private func swap(to compiled: CompiledPlugin, source: PluginSource) throws {
        generationCounter += 1
        let generation = generationCounter

        guard let image = dlopen(compiled.dylibURL.path, RTLD_NOW | RTLD_LOCAL) else {
            throw CompileError.failed(log: "dlopen 失败：\(String(cString: dlerror()))")
        }
        // RTLD_LOCAL + 按 image handle 取符号是必需的：每个插件都导出同名入口，
        // 走全局查找会拿到先装的那个（M2 §1）。
        guard let symbol = dlsym(image, "dash_plugin_entry") else {
            throw CompileError.failed(log: "找不到 dash_plugin_entry 符号（插件没写 @_cdecl 入口？）")
        }
        let entry = unsafeBitCast(symbol, to: DashPluginEntry.self)
        let object = Unmanaged<AnyObject>.fromOpaque(entry()).takeRetainedValue()
        guard let plugin = object as? DashPlugin else {
            throw CompileError.failed(log: "入口返回的对象没有实现 DashPlugin（SDK 版本不匹配？）")
        }

        let name = source.name
        let host = DashHost(
            plugin: name,
            generation: generation,
            registry: registry,
            objects: objects,
            events: events,
            store: DashStore(directory: storeDir, namespace: name),
            bridge: DashBridge(send: { [weak self] action, payload in
                self?.bridge.send(["type": "invoke", "plugin": name,
                                   "action": action, "payload": payload])
            }),
            log: { message in
                Log.write("[\(name) g\(generation)] \(message)", to: DashPaths.logURL, tag: "plugin")
            })

        let handle = plugin.activate(host: host)

        let previous = loaded[name]
        loaded[name] = LoadedPlugin(name: name, module: compiled.module,
                                    contentHash: compiled.contentHash, generation: generation,
                                    directory: compiled.directory,
                                    handle: handle, plugin: plugin, host: host, image: image)
        if let previous {
            // 松手：旧 handle 析构 → 旧注册自行退场（且只退自己那份，见
            // DashRegistry.register 的 token 校验）。旧 dylib 留在内存里。
            ledger.recordRetire(plugin: name, module: previous.module)
            Log.write("插件 \(name) 换代 g\(previous.generation) → g\(generation)（\(compiled.module)）",
                      to: DashPaths.logURL, tag: "plugin")
        } else {
            Log.write("插件 \(name) 装载 g\(generation)（\(compiled.module)"
                      + "\(compiled.fromCache ? "，缓存命中" : "")）",
                      to: DashPaths.logURL, tag: "plugin")
        }
        ledger.recordLoad(plugin: name, module: compiled.module, hash: compiled.contentHash)
        onUpdate?()
    }

    // MARK: - 诊断

    /// 给 boot/诊断视图看的一行行摘要。
    var diagnostics: [String] {
        loaded.values.sorted { $0.name < $1.name }.map {
            "\($0.name) g\($0.generation) \($0.module)"
        }
    }
}
