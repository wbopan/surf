import AppKit
import ClamSDK
import Foundation

/// clam-app 播报的壳构建状态（`app-build` 帧，计划 §5.4/§7.5）。
struct AppBuildState {
    /// `building` / `ready` / `failed`；未知值一律当作"没什么可说的"。
    let status: String
    /// 新产物的源码 hash 短前缀，纯给人看。
    let hash: String?
    let durationMs: Int?
    /// clam-app 配了 `restartOnRebuild`：不必问用户，直接重启。
    let autoRestart: Bool
    /// 失败时的日志尾巴。
    let log: String?
}

/// 插件 dylib 的 C 入口签名（M2 定稿，见 `docs/native-abi.md` §1）。
private typealias ClamPluginEntry = @convention(c) () -> UnsafeMutableRawPointer

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
    let plugin: ClamPlugin
    let host: ClamHost
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
    // 共享给所有插件、跨世代稳定的三件套（住在 ClamSDK dylib 里）。
    let registry = ClamRegistry()
    let objects = ClamObjects()
    let events = ClamEventBus()

    /// 首次 snapshot 处理完毕（成功或失败都算）。boot 门控等的就是它。
    private(set) var didSettle = false

    /// 插件声明的命令（菜单项 + 默认键位）。**壳一个 id 都不认得**——建菜单、
    /// 装键位、画 ⌘/ 面板全靠这张表，插件缺席时对应的菜单项干脆不出现。
    ///
    /// 它来自 snapshot 的 `commands` 字段，**与编译无关**：一条菜单文案改了不该
    /// 让任何 Swift 半边重编（所以它没有折进 contentHash），也不该等编译跑完才生效
    /// ——因此这条线在 `apply(snapshot:)` 里就翻牌，不等 `reconcile`。
    private(set) var commands: [ClamCommand] = []

    /// 命令声明有变时调用。与 `onUpdate` 分开：这条线跟 registry、跟编译都没关系。
    var onCommands: (([ClamCommand]) -> Void)?
    /// 壳自身的构建状态（clam-app v1 经桥播报，§7.5）。壳自己看，不给插件。
    private(set) var appBuild: AppBuildState?
    /// 壳构建状态有变时调用。与 `onUpdate` 分开：这条线跟 registry 没关系。
    var onAppBuild: ((AppBuildState) -> Void)?
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
        let base = ClamPaths.appSupport.appendingPathComponent("native-plugins", isDirectory: true)
        storeDir = base.appendingPathComponent("store", isDirectory: true)
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        compiler = CompilerService(
            modulesDir: Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/ClamModules", isDirectory: true),
            frameworksDir: Bundle.main.bundleURL
                .appendingPathComponent("Contents/Frameworks", isDirectory: true),
            generationsDir: base.appendingPathComponent("generations", isDirectory: true))
        ledger = GenerationLedger(url: base.appendingPathComponent("ledger.json"))

        bridge.onFrame = { [weak self] frame in self?.handle(frame) }
        bridge.onConnected = { [weak self] connected in
            guard let self else { return }
            if connected {
                Log.write("桥已握手，拉取 snapshot", to: ClamPaths.logURL, tag: "bridge")
                self.bridge.send(["type": "snapshot"])
            } else {
                // 断桥不动 registry：UI 保持最后状态，重连后重新拉全量即可。
                Log.write("桥断开（registry 保持不动）", to: ClamPaths.logURL, tag: "bridge")
            }
            self.onUpdate?()
        }
    }

    var isBridgeConnected: Bool { bridge.isConnected }

    // MARK: - 生命周期

    func connect(baseURL: URL, bridgePath: String) {
        objects.setObject(ClamObjects.Key.endpoint, baseURL as NSURL)
        events.emit(ClamEventBus.Topic.endpointChanged, ["httpBase": baseURL.absoluteString])
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

    /// 一个进程只自己重启一次。这是断环的保险丝：任何"重启后又被告知该重启"的
    /// 情形（补发、串台、时序意外）最多多转一圈，不会变成开机-退出的死循环。
    private var didRequestRestart = false

    /// 告诉 clam-app"我这就退出，等我死透了按新产物把我拉回来"，然后退出。
    /// 顺序不能反：先退出就没人发这一帧了。
    func requestRestartApp() {
        guard !didRequestRestart else {
            Log.write("已经请求过一次重启，忽略重复请求（防重启环）",
                      to: ClamPaths.logURL, tag: "app-build")
            return
        }
        didRequestRestart = true
        bridge.send(["type": "app-restart"])
        // 给 WS 一拍把帧真正写出去；桥收不到这帧的话，退出后就没人拉我们了。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
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

        case "app-build":
            let state = AppBuildState(
                status: frame["status"] as? String ?? "?",
                hash: frame["hash"] as? String,
                durationMs: frame["durationMs"] as? Int,
                autoRestart: frame["autoRestart"] as? Bool ?? false,
                log: frame["log"] as? String)
            appBuild = state
            Log.write("壳构建：\(state.status)\(state.hash.map { " \($0)" } ?? "")",
                      to: ClamPaths.logURL, tag: "app-build")
            onAppBuild?(state)

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
        applyCommands(rows)
        let sources: [PluginSource] = rows.compactMap { row in
            guard let name = row["name"] as? String,
                  let module = row["module"] as? String,
                  let files = row["files"] as? [String: String],
                  let hash = row["contentHash"] as? String else { return nil }
            return PluginSource(name: name, module: module, files: files,
                                deps: row["swiftDeps"] as? [String] ?? [],
                                sharedModules: row["sharedModules"] as? [String] ?? [],
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

    /// 收下 snapshot 里的命令声明。
    ///
    /// **同一个 id 由多家声明时先到的赢**：同一条命令可以有好几个可能的执行者
    /// （「打开设置」既能开原生窗口也能弹页内 modal），谁在场都该有那一项。
    /// clam-app 那边拼设置 schema
    /// 时用的是同一条规则——两边算出来的必须是同一张表，否则会出现"设置里能配、
    /// 壳却不认得"的键。
    private func applyCommands(_ rows: [[String: Any]]) {
        var seen = Set<String>()
        var next: [ClamCommand] = []
        for row in rows {
            guard let owner = row["name"] as? String else { continue }
            for raw in row["commands"] as? [[String: Any]] ?? [] {
                guard let command = ClamCommand(owner: owner, raw: raw) else { continue }
                guard seen.insert(command.id).inserted else {
                    // 重复声明本身不是错（见上），但**内容不一致就是账对不上**，
                    // 而症状是"谁先挂载就听谁的"——不记一行没人查得出来。
                    if let first = next.first(where: { $0.id == command.id }),
                       first.key != command.key || first.label != command.label {
                        Log.write("命令 \(command.id) 被 \(first.owner) 与 \(owner) 各声明一份且内容不同，"
                                  + "按 \(first.owner) 那份走", to: ClamPaths.logURL, tag: "menu")
                    }
                    continue
                }
                next.append(command)
            }
        }
        guard next != commands else { return }
        commands = next
        Log.write("命令声明 \(next.count) 条："
                  + next.map { "\($0.owner)/\($0.id)" }.joined(separator: " "),
                  to: ClamPaths.logURL, tag: "menu")
        onCommands?(next)
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
                          to: ClamPaths.logURL, tag: "plugin")
                bridge.send(["type": "compile-result", "plugin": source.name,
                             "contentHash": hash, "ok": false, "log": log])
                // 失败即保持上一代在役（§0.5-5：坏的插件不许拖垮系统）。
            }
        }

        // snapshot 里没有的 = 被禁用/卸载：松手让它退休。
        let names = Set(sources.map(\.name))
        for (name, plugin) in loaded where !names.contains(name) {
            Log.write("插件 \(name) 已从登记表消失，退休第 \(plugin.generation) 代",
                      to: ClamPaths.logURL, tag: "plugin")
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
        guard let symbol = dlsym(image, "clam_plugin_entry") else {
            throw CompileError.failed(log: "找不到 clam_plugin_entry 符号（插件没写 @_cdecl 入口？）")
        }
        let entry = unsafeBitCast(symbol, to: ClamPluginEntry.self)
        let object = Unmanaged<AnyObject>.fromOpaque(entry()).takeRetainedValue()
        guard let plugin = object as? ClamPlugin else {
            throw CompileError.failed(log: "入口返回的对象没有实现 ClamPlugin（SDK 版本不匹配？）")
        }

        let name = source.name
        let host = ClamHost(
            plugin: name,
            generation: generation,
            registry: registry,
            objects: objects,
            events: events,
            store: ClamStore(directory: storeDir, namespace: name),
            bridge: ClamBridge(send: { [weak self] action, payload in
                self?.bridge.send(["type": "invoke", "plugin": name,
                                   "action": action, "payload": payload])
            }),
            log: { message in
                Log.write("[\(name) g\(generation)] \(message)", to: ClamPaths.logURL, tag: "plugin")
            })

        let handle = plugin.activate(host: host)

        let previous = loaded[name]
        loaded[name] = LoadedPlugin(name: name, module: compiled.module,
                                    contentHash: compiled.contentHash, generation: generation,
                                    directory: compiled.directory,
                                    handle: handle, plugin: plugin, host: host, image: image)
        if let previous {
            // 松手：旧 handle 析构 → 旧注册自行退场（且只退自己那份，见
            // ClamRegistry.register 的 token 校验）。旧 dylib 留在内存里。
            ledger.recordRetire(plugin: name, module: previous.module)
            Log.write("插件 \(name) 换代 g\(previous.generation) → g\(generation)（\(compiled.module)）",
                      to: ClamPaths.logURL, tag: "plugin")
        } else {
            Log.write("插件 \(name) 装载 g\(generation)（\(compiled.module)"
                      + "\(compiled.fromCache ? "，缓存命中" : "")）",
                      to: ClamPaths.logURL, tag: "plugin")
        }
        ledger.recordLoad(plugin: name, module: compiled.module, hash: compiled.contentHash)
        onUpdate?()
    }

    // MARK: - 诊断

    /// 给诊断面板看的一行行摘要。**"我现在跑的到底是哪一份代码"**——
    /// 世代号 + module 名（含内容 hash）合起来就是答案，这也是 §6.2
    /// "内容寻址与世代隔离是同一件事的两面"在人眼层面的体现。
    var diagnostics: [String] {
        loaded.values.sorted { $0.name < $1.name }.map {
            // module 名末尾就是 contentHash 的短前缀（§6.2），不再单列一次。
            "\($0.name)  g\($0.generation)  \($0.module)"
        }
    }

    /// 本次运行退休掉的 image 数（旧 dylib 按设计不 dlclose，见 §6.4）。
    var retiredThisRun: Int { ledger.retiredThisRun }

    /// 在役插件数。
    var loadedCount: Int { loaded.count }
}
