import Foundation

/// 桥递下来的一份 Swift 载荷源码。
struct PluginSource {
    /// 插件名，如 `clam-sidebar`。
    let name: String
    /// 基础 module 名，如 `ClamSidebar`（桥算，壳只用）。
    let module: String
    /// 相对路径 → utf8 源码。
    let files: [String: String]
    /// Swift module 依赖（插件名），按拓扑序已排在本插件之前。
    let deps: [String]
    /// 本插件声明用到的共享 module（桥已排序去重；DSHKit 退役后暂无住户，机制保留）。
    /// **不含 `ClamSDK`**——那是无条件的 ABI，见 `CompilerService`。
    let sharedModules: [String]
    /// 桥算的内容 hash（**已折进依赖的 hash**，级联重编靠它）。
    let bridgeHash: String
    let schemaVersion: Int
}

/// 一次编译的产物。
struct CompiledPlugin {
    let name: String
    /// 带世代后缀的实际 module 名，如 `ClamSidebar_h9f31c0aa12b4`。
    /// 后缀取自 contentHash：内容一样就是同一个 module，内容一变就是新 module
    /// ——世代隔离与内容寻址缓存由同一个事实提供。
    let module: String
    let directory: URL
    let dylibURL: URL
    let contentHash: String
    /// 这份产物是从哪儿来的。**"零编译启动"的证据就是这一栏**：正式形态下
    /// 五个插件应当全是 `.prebuilt`，一次 swiftc 都不跑。
    let origin: Origin

    /// 产物的来路。
    enum Origin: String {
        /// 用户缓存（`native-plugins/generations/`）——上一次现场编译留下的。
        case cache = "用户缓存"
        /// App bundle 里随分发走的预编译产物（`Resources/ClamPlugins/`）。
        case prebuilt = "bundle 预编译"
        /// 这一次真的跑了 swiftc。
        case compiled = "现场编译"
    }

    /// 这次没跑 swiftc（诊断文案与桥的回报都只关心这一位）。
    var fromCache: Bool { origin != .compiled }
}

enum CompileError: Error {
    /// 编译失败，带 swiftc 的完整输出。
    case failed(log: String)
    case noSources
    /// 本机没有 Swift 工具链，而缓存与 bundle 内预编译产物都没命中。
    ///
    /// **这不是错误，是缺一块能力**（分发计划 §3.2）：现场编译此后是"可选能力"
    /// 而不是"启动前提"。正式形态下用户机器上多半没有 swiftc，正常路径是命中
    /// bundle 里的预编译产物；走到这里说明那份产物也不在（换了源码、或者包坏了）。
    case noToolchain
}

/// 壳内编译机：把桥送来的 Swift 源码就地编成 dylib（计划 §6）。
///
/// 内容寻址：`contentHash` 决定产物目录**和 module 名**，所以
/// - 内容没变 → 目录已在 → 跳过 swiftc，直接用（重启后秒载）；
/// - 内容变了 → 新 module 名 → 与旧代天然类型隔离（M2 断言 4）；
/// - 上游变了 → 桥算的 hash 已折进上游 hash → 下游 hash 必变 → 强制级联重编
///   （M2 断言 6 的沉默认知分裂由此杜绝）。
actor CompilerService {
    /// ABI module：每个插件无条件链接、变了所有插件都必须重编的那一个。
    /// 其余共享 module 一律按 `PluginSource.sharedModules` 声明处理。
    static let abiModule = "ClamSDK"

    /// 共享 module 的 `.swiftmodule`/`.swiftinterface`（bundle 内）。
    private let modulesDir: URL
    /// 共享 module 的 dylib（bundle 内 Contents/Frameworks）。
    private let frameworksDir: URL

    /// 产物的一种落点。
    ///
    /// **两种布局是同构的**（`<Module>/…/<hash12>/`，产物之间永远是"兄弟"），
    /// 所以插件间依赖那条 `@loader_path` 相对 rpath 在两边都自动成立
    /// ——`rpathReference(to:from:)` 按真实相对位置算，不写死任何一种布局。
    enum ProductRoot {
        /// 用户缓存：`<AppSupport>/native-plugins/generations/<Module>/<hash12>/`。
        case cache(URL)
        /// bundle 内预编译：`<App>.app/Contents/Resources/ClamPlugins/<Module>/prebuilt/<hash12>/`。
        case prebuilt(URL)

        var origin: CompiledPlugin.Origin {
            switch self {
            case .cache: .cache
            case .prebuilt: .prebuilt
            }
        }

        /// 这个落点存不存源码副本。用户缓存存（出问题时能看到当时到底编的是什么）；
        /// bundle 里不存——那份源码已经在 `Resources/ClamNode/<pkg>/swift/` 了，
        /// 再来一份是白白给每个用户多发 ~490 KB。
        var keepsSources: Bool {
            switch self {
            case .cache: true
            case .prebuilt: false
            }
        }

        func directory(module: String, hash12: String) -> URL {
            switch self {
            case .cache(let root):
                root.appendingPathComponent(module, isDirectory: true)
                    .appendingPathComponent(hash12, isDirectory: true)
            case .prebuilt(let root):
                root.appendingPathComponent(module, isDirectory: true)
                    .appendingPathComponent("prebuilt", isDirectory: true)
                    .appendingPathComponent(hash12, isDirectory: true)
            }
        }
    }

    /// 找现成产物的顺序。**用户缓存排第一**：用户自己改了插件源码、壳现场编出来的
    /// 那一份，必须赢过 bundle 里随分发走的默认实现（分发计划 §3.2）。
    private let searchRoots: [ProductRoot]
    /// 真要编译时写到哪儿。壳写用户缓存；构建期的预编译工具写 bundle。
    private let writeRoot: ProductRoot

    private var toolchainFingerprintCache: String?
    private var sharedModuleFingerprintCache: [String: String] = [:]
    private var targetTripleCache: String?
    private var toolchainAvailableCache: Bool?

    init(modulesDir: URL, frameworksDir: URL,
         searchRoots: [ProductRoot], writeRoot: ProductRoot) {
        self.modulesDir = modulesDir
        self.frameworksDir = frameworksDir
        self.searchRoots = searchRoots
        self.writeRoot = writeRoot
    }

    // MARK: - 内容寻址

    /// 完整内容 hash = 桥的 hash（源码 + 依赖 + 共享 module 声明）
    /// + 本机工具链基线 + **本插件声明用到的**共享 module 的接口摘要。
    ///
    /// 换 Xcode 或重编 ClamSDK 之后必须全量重编，否则 `.swiftmodule` 会对不上。
    /// 但重编某个共享 module 只该波及 import 它的插件——所以共享 module 的摘要
    /// 按声明逐个折进来，而不是把 `ClamModules/` 里的东西一股脑算成一个数。
    func contentHash(for source: PluginSource) async -> String {
        var hasher = SHA256Hasher()
        hasher.update(source.module)
        hasher.update(source.bridgeHash)
        hasher.update(String(source.schemaVersion))
        hasher.update(toolchainFingerprint())
        for module in source.sharedModules where module != Self.abiModule {
            hasher.update("shared:\(module)=\(sharedModuleFingerprint(module))")
        }
        return hasher.finalizeHex()
    }

    /// module 名后缀用 hash 前 12 位（十六进制，天然是合法标识符字符）。
    private func moduleName(_ base: String, _ hash: String) -> String {
        "\(base)_h\(hash.prefix(12))"
    }

    // MARK: - 编译

    /// 编一个插件。**先按 `searchRoots` 找现成的**（用户缓存 → bundle 内预编译），
    /// 都没有才跑 swiftc。
    /// - Parameter resolved: 已编好的依赖（插件名 → 产物），用于 `-I/-L/-module-alias`。
    func compile(_ source: PluginSource,
                 resolved: [String: CompiledPlugin]) async throws -> CompiledPlugin {
        guard !source.files.isEmpty else { throw CompileError.noSources }

        let hash = await contentHash(for: source)
        let module = moduleName(source.module, hash)
        let hash12 = String(hash.prefix(12))

        for root in searchRoots {
            let dir = root.directory(module: source.module, hash12: hash12)
            let dylib = dir.appendingPathComponent("lib\(module).dylib")
            guard FileManager.default.fileExists(atPath: dylib.path) else { continue }
            return CompiledPlugin(name: source.name, module: module, directory: dir,
                                  dylibURL: dylib, contentHash: hash, origin: root.origin)
        }

        // 现场编译此后是**可选能力**而不是启动前提（分发计划 §3.2）：正式形态下
        // 上面那一轮就该命中 bundle 里的预编译产物，走到这里说明它不在。
        // 没有工具链时缺的是"这一个插件的原生半边"，不是整个原生侧。
        guard toolchainAvailable() else { throw CompileError.noToolchain }

        let dir = writeRoot.directory(module: source.module, hash12: hash12)
        let dylib = dir.appendingPathComponent("lib\(module).dylib")

        // 源码落盘。用户缓存留一份当诊断素材（出问题时能看到当时到底编的是什么）；
        // 写进 bundle 的预编译产物不留——那份源码已经在 `Resources/ClamNode/` 里了。
        let srcDir = writeRoot.keepsSources
            ? dir.appendingPathComponent("src", isDirectory: true)
            : URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("clam-prebuild-\(module)", isDirectory: true)
        try? FileManager.default.removeItem(at: srcDir)
        defer { if !writeRoot.keepsSources { try? FileManager.default.removeItem(at: srcDir) } }
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        var sourcePaths: [String] = []
        for (rel, content) in source.files.sorted(by: { $0.key < $1.key }) {
            let url = srcDir.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            sourcePaths.append(url.path)
        }

        var args = sourcePaths
        args += ["-module-name", module,
                 "-emit-library", "-o", dylib.path,
                 "-emit-module", "-emit-module-path",
                 dir.appendingPathComponent("\(module).swiftmodule").path]
        // 共享 module：编译期 -I 找 .swiftmodule，链接期 -L 找 bundle 里的 dylib，
        // 运行期靠 -rpath 落到同一个文件上（同一份 image = 类型身份一致）。
        // ClamSDK 无条件（它是 ABI 本身）；其余按插件声明加，没声明的不链接
        // ——import 了共享 module 却忘了声明 sharedModules，swiftc 会带行号报错，
        // 比默认全给更早暴露问题。
        args += ["-I", modulesDir.path, "-L", frameworksDir.path, "-l\(Self.abiModule)"]
        for module in source.sharedModules where module != Self.abiModule {
            args += ["-l\(module)"]
        }
        // rpath 一律写成**可搬运**的形式：产物要能随 App bundle 分发（预编译方案，
        // docs/archive/distribution-plan.md §3.2），烘焙一条构建机的绝对路径进去
        // 就等于把它钉死在那台机器上。
        // 共享 module 永远在 `<App>.app/Contents/Frameworks`，而 `@executable_path` 展开的
        // 是**主可执行文件**（壳）的位置——与这份 dylib 自己躺在哪里（用户缓存 / bundle 内
        // 预编译目录）无关，所以这条对两种落点都成立。壳自己链接 ClamSDK 用的也正是这条
        // （见 project.yml 的 LD_RUNPATH_SEARCH_PATHS，实测 `otool -l` 一致）。
        args += ["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]
        // 插件间依赖：源码里写 `import ClamLayout`，这里用 -module-alias 绑到
        // 具体世代，世代号对插件作者完全透明（M2 §2 定稿）。
        for dep in source.deps {
            guard let compiled = resolved[dep] else { continue }
            args += ["-I", compiled.directory.path,
                     "-L", compiled.directory.path,
                     "-l\(compiled.module)",
                     "-module-alias", "\(baseModule(compiled.module))=\(compiled.module)"]
            args += ["-Xlinker", "-rpath", "-Xlinker",
                     rpathReference(to: compiled.directory, from: dir)]
        }
        args += ["-Xlinker", "-install_name", "-Xlinker", "@rpath/lib\(module).dylib"]
        args += ["-target", await targetTriple(), "-language-mode", "5", "-Onone", "-g"]

        let started = Date()
        Log.write("现场编译 \(source.name) → \(module)", to: ClamPaths.logURL, tag: "compile")
        let result = try runSwiftc(args)
        let log = result.output
        if writeRoot.keepsSources {
            try? log.write(to: dir.appendingPathComponent("build.log"),
                           atomically: true, encoding: .utf8)
        }

        guard result.status == 0, FileManager.default.fileExists(atPath: dylib.path) else {
            // 失败的目录留着会让下次误判成缓存命中，清掉。
            try? FileManager.default.removeItem(at: dir)
            throw CompileError.failed(log: log)
        }

        Log.write(String(format: "编译 %@ 完成 %.2fs → %@", source.name,
                         Date().timeIntervalSince(started), module),
                  to: ClamPaths.logURL, tag: "compile")
        return CompiledPlugin(name: source.name, module: module, directory: dir,
                              dylibURL: dylib, contentHash: hash, origin: .compiled)
    }

    /// 本机有没有可用的 swiftc。
    ///
    /// **只在真要编译之前问一次**——正式形态下五个插件全部命中 bundle 里的预编译
    /// 产物，这个函数一次都不会被调用，所以"零编译启动"连 `xcrun` 都不会 spawn。
    ///
    /// 判据是 `xcrun --find swiftc` 的**退出码 + 结果文件真的可执行**，不是
    /// `swiftc --version` 的输出：`/usr/bin/xcrun` 在没有工具链的机器上照样存在、
    /// 照样能跑，只是把 `xcrun: error: missing DEVELOPER_DIR path: …` 当 stdout
    /// 吐出来（实测）——只看"跑起来了"会把那段错误文本当成成功。
    private func toolchainAvailable() -> Bool {
        if let cached = toolchainAvailableCache { return cached }
        var available = false
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "swiftc"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let path = (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            available = process.terminationStatus == 0 && !path.isEmpty
                && FileManager.default.isExecutableFile(atPath: path)
        } catch {
            available = false
        }
        toolchainAvailableCache = available
        return available
    }

    /// 插件间依赖那条 rpath，写成 `@loader_path` 相对形式。
    ///
    /// **运行期真正管用的机制不是这条 rpath，是"依赖先装"。** 壳按拓扑序 dlopen
    /// （`NativePluginHost.reconcile`），而 dyld 在解析 `@rpath/libClamLayout_h….dylib`
    /// 之前先看**已装载的 image 里有没有同名 install_name**，有就直接复用——
    /// 与 rpath 能不能解析、与 `RTLD_LOCAL` 都无关（2026-08-30 实测：把 rpath 指向一个
    /// 根本不存在的目录，先 dlopen 依赖再 dlopen 依赖方，照样成功；不先装依赖才会报
    /// "Library not loaded"）。所以这条 rpath 的作用域是"这份 dylib 被单独装载时"
    /// ——验证工具、将来的按需装载。
    ///
    /// 既然如此就该写成可搬运的：两份产物在同一棵树里的相对位置是**结构性**的
    /// （用户缓存 `generations/<Module>/<hash12>/`，bundle 内预编译
    /// `ClamPlugins/<Module>/prebuilt/<hash12>/`，都是"兄弟目录"），而绝对路径在换一台
    /// 机器、甚至只是把 App 拖到别的文件夹之后就一定是错的。**相对路径在任何情形下都不
    /// 比绝对路径差**：两者一起搬 → 相对还对、绝对已错；只搬一边 → 两者都错，而那时
    /// 兜底的是上面那条"依赖先装"。
    ///
    /// 唯一退回绝对路径的情形是两者除了 `/` 没有公共祖先（跨卷等），那时它们无论如何
    /// 都不是同一棵可分发的树。
    private func rpathReference(to depDir: URL, from outputDir: URL) -> String {
        let dep = depDir.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let out = outputDir.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var shared = 0
        while shared < dep.count, shared < out.count, dep[shared] == out[shared] { shared += 1 }
        // pathComponents 的第 0 个是 "/"；只共享它 = 没有任何公共祖先。
        guard shared > 1 else { return depDir.path }
        let ups = Array(repeating: "..", count: out.count - shared)
        return (["@loader_path"] + ups + dep[shared...]).joined(separator: "/")
    }

    /// `ClamLayout_h9f31c0aa12b4` → `ClamLayout`（-module-alias 的左边）。
    private func baseModule(_ module: String) -> String {
        guard let range = module.range(of: "_h", options: .backwards) else { return module }
        return String(module[module.startIndex..<range.lowerBound])
    }

    // MARK: - 工具链

    /// 目标三元组直接从 ClamSDK 的 `.swiftinterface` 头里抄——那是共享 module
    /// 实际用的那个，抄它就不可能对不上（写死常量迟早会与 build-modules.sh 漂移）。
    private func targetTriple() async -> String {
        if let cached = targetTripleCache { return cached }
        let fallback = "arm64-apple-macos27.0"
        let interface = modulesDir.appendingPathComponent("\(Self.abiModule).swiftinterface")
        guard let text = try? String(contentsOf: interface, encoding: .utf8) else {
            targetTripleCache = fallback
            return fallback
        }
        for line in text.split(separator: "\n").prefix(8) {
            guard line.hasPrefix("// swift-module-flags:") else { continue }
            let tokens = line.split(separator: " ").map(String.init)
            if let index = tokens.firstIndex(of: "-target"), index + 1 < tokens.count {
                targetTripleCache = tokens[index + 1]
                return tokens[index + 1]
            }
        }
        targetTripleCache = fallback
        return fallback
    }

    /// **所有**插件共享的编译基线：ABI 版本 + ClamSDK 的接口。
    ///
    /// 只有 ClamSDK 在这里。它是壳↔插件的 ABI 本身，每个插件都链接它，变了谁都得重编。
    /// 其余共享 module 按插件声明单独折进 `contentHash`
    /// ——把整个 `ClamModules/` 一股脑算进来，就等于让改一行共享 module 把从不
    /// import 它的插件也全量重编一遍。
    ///
    /// **这里不查本机 `swiftc --version`**（2026-08-30 删掉，docs/archive/distribution-plan.md §3.2）。
    /// 两条理由：
    ///
    /// 1. **它让预编译分发不可能成立**。contentHash 要在构建机与用户机上算出同一个数，
    ///    随 bundle 分发的那份 dylib 才可能被认出来；本机 swiftc 版本按定义两边不同。
    ///    更糟的是无工具链的机器上它不是"取不到值"而是**取到垃圾值**：`/usr/bin/xcrun`
    ///    仍在，`Process.run()` 不抛，`runSwiftc` 只是返回非零状态**并把错误文本当作
    ///    output**（实测：`xcrun: error: missing DEVELOPER_DIR path: …`），那段带本机
    ///    路径的错误文本被原样哈希进去。
    /// 2. **信号没有丢**。`ClamSDK.swiftinterface` 的文件头里就写着编它的那个编译器
    ///    （`// swift-compiler-version: Apple Swift version 6.4 (swiftlang-…)`）与目标
    ///    三元组，而 `scripts/build-modules.sh` 的跳过判据里**含 `xcrun swiftc --version`**
    ///    ——换工具链必然重编 ClamSDK、必然改写这份 interface、于是所有插件的
    ///    contentHash 必然失效。`targetTriple()` 早就在演示同一个模式：真相取自随
    ///    bundle 走的那份文件，而不是本机环境。
    ///
    /// **取舍**：同源码 + 同 ClamSDK、只换 swiftc 而**不重编 ClamSDK**，会被认作同一个
    /// hash（缓存命中、不重编）。这条路只在有人手动绕开 build-modules.sh 时才走得到；
    /// 真出问题也是响亮的 `.swiftmodule` 版本不匹配，不是沉默的认知分裂。
    private func toolchainFingerprint() -> String {
        if let cached = toolchainFingerprintCache { return cached }
        var hasher = SHA256Hasher()
        hasher.update(String(clamABIVersionForFingerprint))
        hasher.update(sharedModuleFingerprint(Self.abiModule))
        let value = hasher.finalizeHex()
        toolchainFingerprintCache = value
        return value
    }

    /// 单个共享 module 的接口摘要（`.swiftinterface` 内容；缺文件时是稳定的 `missing`
    /// ——这样声明了一个 bundle 里没有的 module 不会让 hash 每次都变，
    /// 而 swiftc 会在编译时带行号报出 "no such module"）。
    private func sharedModuleFingerprint(_ module: String) -> String {
        if let cached = sharedModuleFingerprintCache[module] { return cached }
        let url = modulesDir.appendingPathComponent("\(module).swiftinterface")
        var hasher = SHA256Hasher()
        hasher.update(module)
        if let data = try? Data(contentsOf: url) {
            hasher.update(data)
        } else {
            hasher.update("missing")
        }
        let value = hasher.finalizeHex()
        sharedModuleFingerprintCache[module] = value
        return value
    }

    // MARK: - 子进程

    private struct RunResult { let status: Int32; let output: String }

    private func runSwiftc(_ args: [String]) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc"] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // 先读干管道再 wait：swiftc 的诊断输出可以塞满 64KB 管道缓冲，
        // 先 wait 会双方互等（经典死锁）。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RunResult(status: process.terminationStatus,
                         output: String(data: data, encoding: .utf8) ?? "")
    }
}

/// 编译指纹里带上 ABI 版本：SDK 语义变了就全量重编。
/// （直接引用 `clamABIVersion` 会把 ClamSDK 拖进本文件的 import，没必要。）
private let clamABIVersionForFingerprint = 1
