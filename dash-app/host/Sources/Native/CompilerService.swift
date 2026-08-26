import Foundation

/// 桥递下来的一份 Swift 载荷源码。
struct PluginSource {
    /// 插件名，如 `dash-sidebar`。
    let name: String
    /// 基础 module 名，如 `DashSidebar`（桥算，壳只用）。
    let module: String
    /// 相对路径 → utf8 源码。
    let files: [String: String]
    /// Swift module 依赖（插件名），按拓扑序已排在本插件之前。
    let deps: [String]
    /// 本插件声明用到的共享 module（`DSHKit` 等，桥已排序去重）。
    /// **不含 `DashSDK`**——那是无条件的 ABI，见 `CompilerService`。
    let sharedModules: [String]
    /// 桥算的内容 hash（**已折进依赖的 hash**，级联重编靠它）。
    let bridgeHash: String
    let schemaVersion: Int
}

/// 一次编译的产物。
struct CompiledPlugin {
    let name: String
    /// 带世代后缀的实际 module 名，如 `DashSidebar_h9f31c0aa12b4`。
    /// 后缀取自 contentHash：内容一样就是同一个 module，内容一变就是新 module
    /// ——世代隔离与内容寻址缓存由同一个事实提供。
    let module: String
    let directory: URL
    let dylibURL: URL
    let contentHash: String
    /// 这次是编出来的还是缓存命中的（诊断用）。
    let fromCache: Bool
}

enum CompileError: Error {
    /// 编译失败，带 swiftc 的完整输出。
    case failed(log: String)
    case noSources
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
    static let abiModule = "DashSDK"

    /// 共享 module 的 `.swiftmodule`/`.swiftinterface`（bundle 内）。
    private let modulesDir: URL
    /// 共享 module 的 dylib（bundle 内 Contents/Frameworks）。
    private let frameworksDir: URL
    /// 世代产物根目录。
    private let generationsDir: URL

    private var toolchainFingerprintCache: String?
    private var sharedModuleFingerprintCache: [String: String] = [:]
    private var targetTripleCache: String?

    init(modulesDir: URL, frameworksDir: URL, generationsDir: URL) {
        self.modulesDir = modulesDir
        self.frameworksDir = frameworksDir
        self.generationsDir = generationsDir
    }

    // MARK: - 内容寻址

    /// 完整内容 hash = 桥的 hash（源码 + 依赖 + 共享 module 声明）
    /// + 本机工具链基线 + **本插件声明用到的**共享 module 的接口摘要。
    ///
    /// 换 Xcode 或重编 DashSDK 之后必须全量重编，否则 `.swiftmodule` 会对不上。
    /// 但重编 DSHKit 只该波及 `import DSHKit` 的插件——所以共享 module 的摘要
    /// 按声明逐个折进来，而不是把 `DashModules/` 里的东西一股脑算成一个数。
    func contentHash(for source: PluginSource) async -> String {
        var hasher = SHA256Hasher()
        hasher.update(source.module)
        hasher.update(source.bridgeHash)
        hasher.update(String(source.schemaVersion))
        hasher.update(await toolchainFingerprint())
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

    /// 编一个插件。命中缓存则不跑 swiftc。
    /// - Parameter resolved: 已编好的依赖（插件名 → 产物），用于 `-I/-L/-module-alias`。
    func compile(_ source: PluginSource,
                 resolved: [String: CompiledPlugin]) async throws -> CompiledPlugin {
        guard !source.files.isEmpty else { throw CompileError.noSources }

        let hash = await contentHash(for: source)
        let module = moduleName(source.module, hash)
        let dir = generationsDir
            .appendingPathComponent(source.module, isDirectory: true)
            .appendingPathComponent(String(hash.prefix(12)), isDirectory: true)
        let dylib = dir.appendingPathComponent("lib\(module).dylib")

        if FileManager.default.fileExists(atPath: dylib.path) {
            return CompiledPlugin(name: source.name, module: module, directory: dir,
                                  dylibURL: dylib, contentHash: hash, fromCache: true)
        }

        // 源码落盘（顺带成为诊断素材：出问题时能看到当时到底编的是什么）。
        let srcDir = dir.appendingPathComponent("src", isDirectory: true)
        try? FileManager.default.removeItem(at: srcDir)
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
        // DashSDK 无条件（它是 ABI 本身）；其余按插件声明加，没声明的不链接
        // ——写 `import DSHKit` 却忘了声明 sharedModules，swiftc 会带行号报错，
        // 比默认全给更早暴露问题。
        args += ["-I", modulesDir.path, "-L", frameworksDir.path, "-l\(Self.abiModule)"]
        for module in source.sharedModules where module != Self.abiModule {
            args += ["-l\(module)"]
        }
        args += ["-Xlinker", "-rpath", "-Xlinker", frameworksDir.path]
        // 插件间依赖：源码里写 `import DashLayout`，这里用 -module-alias 绑到
        // 具体世代，世代号对插件作者完全透明（M2 §2 定稿）。
        for dep in source.deps {
            guard let compiled = resolved[dep] else { continue }
            args += ["-I", compiled.directory.path,
                     "-L", compiled.directory.path,
                     "-l\(compiled.module)",
                     "-module-alias", "\(baseModule(compiled.module))=\(compiled.module)"]
            args += ["-Xlinker", "-rpath", "-Xlinker", compiled.directory.path]
        }
        args += ["-Xlinker", "-install_name", "-Xlinker", "@rpath/lib\(module).dylib"]
        args += ["-target", await targetTriple(), "-language-mode", "5", "-Onone", "-g"]

        let started = Date()
        let result = try runSwiftc(args)
        let log = result.output
        try? log.write(to: dir.appendingPathComponent("build.log"),
                       atomically: true, encoding: .utf8)

        guard result.status == 0, FileManager.default.fileExists(atPath: dylib.path) else {
            // 失败的目录留着会让下次误判成缓存命中，清掉。
            try? FileManager.default.removeItem(at: dir)
            throw CompileError.failed(log: log)
        }

        Log.write(String(format: "编译 %@ 完成 %.2fs → %@", source.name,
                         Date().timeIntervalSince(started), module),
                  to: DashPaths.logURL, tag: "compile")
        return CompiledPlugin(name: source.name, module: module, directory: dir,
                              dylibURL: dylib, contentHash: hash, fromCache: false)
    }

    /// `DashLayout_h9f31c0aa12b4` → `DashLayout`（-module-alias 的左边）。
    private func baseModule(_ module: String) -> String {
        guard let range = module.range(of: "_h", options: .backwards) else { return module }
        return String(module[module.startIndex..<range.lowerBound])
    }

    // MARK: - 工具链

    /// 目标三元组直接从 DashSDK 的 `.swiftinterface` 头里抄——那是共享 module
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

    /// **所有**插件共享的编译基线：ABI 版本 + swiftc 版本 + DashSDK 的接口。
    ///
    /// 只有 DashSDK 在这里。它是壳↔插件的 ABI 本身，每个插件都链接它，变了谁都得重编。
    /// 其余共享 module（DSHKit…）按插件声明单独折进 `contentHash`
    /// ——把整个 `DashModules/` 一股脑算进来，就等于让改一行 DSHKit 把从不 import 它的
    /// 插件也全量重编一遍。
    private func toolchainFingerprint() async -> String {
        if let cached = toolchainFingerprintCache { return cached }
        var hasher = SHA256Hasher()
        hasher.update(String(dashABIVersionForFingerprint))
        if let version = try? runSwiftc(["--version"]).output { hasher.update(version) }
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
/// （直接引用 `dashABIVersion` 会把 DashSDK 拖进本文件的 import，没必要。）
private let dashABIVersionForFingerprint = 1
