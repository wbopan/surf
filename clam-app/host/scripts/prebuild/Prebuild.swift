import Foundation

/// 构建期的预编译入口（分发计划 M3，§3.2）。
///
/// **它不是第二个编译器。** 这个工具由 `scripts/prebuild-plugins.sh` 用 swiftc
/// 现编，编的时候把壳自己的 `Sources/Native/CompilerService.swift` 原样拉进来——
/// 所以构建机上算 contentHash、拼 swiftc 参数、写 rpath 的，与用户机器上壳运行时
/// 用的**是同一份代码文件**。抄一份"构建期专用的编译逻辑"会得到一个静默的失败模式：
/// 两边算出的 hash 差一点，预编译产物就永远命中不了，退回现场编译，而用户机器上
/// 多半根本没有 swiftc——症状是"插件全部缺席"，而两边的代码看着都对。
///
/// 桥那半边的 hash（源码 + 依赖 + 共享 module 声明）同理不重算：由
/// `prebuild-plugins.mjs` 调 `clam-bridge/lib/swift-payload.js` 算好，
/// 经 spec 递进来当 `bridgeHash`。
///
/// 用法：`clam-prebuild <spec.json>`，spec 的形状见 `Spec`。
@main
struct Prebuild {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 2 else {
            fail("用法：clam-prebuild <spec.json>")
        }
        let spec: Spec
        do {
            spec = try JSONDecoder().decode(Spec.self, from: Data(contentsOf:
                URL(fileURLWithPath: args[1])))
        } catch {
            fail("spec 读不动：\(error)")
        }

        let outputRoot = URL(fileURLWithPath: spec.outputRoot, isDirectory: true)
        // 只认 bundle 这一个落点：既是找现成产物的地方，也是写的地方。
        // **不看用户缓存**——构建机上那份是本机开发留下的，不该混进分发包。
        let compiler = CompilerService(
            modulesDir: URL(fileURLWithPath: spec.modulesDir, isDirectory: true),
            frameworksDir: URL(fileURLWithPath: spec.frameworksDir, isDirectory: true),
            searchRoots: [.prebuilt(outputRoot)],
            writeRoot: .prebuilt(outputRoot))

        var resolved: [String: CompiledPlugin] = [:]
        var entries: [Manifest.Entry] = []
        // spec.plugins 已是拓扑序（依赖在前），与桥送给壳的顺序同源。
        for plugin in spec.plugins {
            let source = PluginSource(
                name: plugin.name, module: plugin.module, files: plugin.files,
                deps: plugin.deps, sharedModules: plugin.sharedModules,
                bridgeHash: plugin.bridgeHash, schemaVersion: plugin.schemaVersion)
            do {
                let compiled = try await compiler.compile(source, resolved: resolved)
                resolved[plugin.name] = compiled
                dropDiagnosticArtifacts(besides: compiled.dylibURL)
                stripLocalSymbols(compiled.dylibURL)
                entries.append(Manifest.Entry(
                    plugin: plugin.name, module: plugin.module,
                    generatedModule: compiled.module, contentHash: compiled.contentHash,
                    dylib: relative(compiled.dylibURL, to: outputRoot)))
                print("prebuild: \(plugin.name) → \(compiled.module)"
                      + "（\(compiled.origin.rawValue)）")
            } catch {
                // **fails loud**：Release 包缺了预编译产物就是个坏包——装到用户机器上
                // 表现为"那个插件的原生半边不存在"，而 dsh 照常起、界面照常出，
                // 没有任何人会去看构建日志。
                fail("\(plugin.name) 预编译失败：\(describe(error))")
            }
        }

        prune(root: outputRoot, keep: entries)

        let manifest = Manifest(version: spec.version, generatedAt: ISO8601DateFormatter()
            .string(from: Date()), plugins: entries)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest)
                .write(to: URL(fileURLWithPath: spec.manifestPath))
        } catch {
            fail("清单写不下：\(error)")
        }
        print("prebuild: \(entries.count) 个 module → \(spec.outputRoot)")
    }

    // MARK: - spec / 清单

    private struct Spec: Decodable {
        let version: String
        /// `Contents/Resources/ClamModules`（ClamSDK 的 .swiftinterface/.swiftmodule）。
        let modulesDir: String
        /// `Contents/Frameworks`（libClamSDK.dylib）。
        let frameworksDir: String
        /// `Contents/Resources/ClamPlugins`。
        let outputRoot: String
        /// `Contents/Resources/ClamPrebuilt.json`。
        let manifestPath: String
        /// **拓扑序**（依赖在前）。
        let plugins: [Plugin]

        struct Plugin: Decodable {
            let name: String
            let module: String
            let files: [String: String]
            let deps: [String]
            let sharedModules: [String]
            let bridgeHash: String
            let schemaVersion: Int
        }
    }

    /// `Contents/Resources/ClamPrebuilt.json`：这个 bundle 里躺着哪些预编译产物。
    ///
    /// 壳不读它（壳按 contentHash 直接去路径上找，命中与否是文件系统说了算），
    /// 它是给人看的——⌥⌘D 里"我这台机器到底编没编"对不上时，第一眼看这里。
    private struct Manifest: Encodable {
        let version: String
        let generatedAt: String
        let plugins: [Entry]

        struct Entry: Encodable {
            let plugin: String
            let module: String
            let generatedModule: String
            let contentHash: String
            let dylib: String
        }
    }

    // MARK: - 收拾

    /// 扔掉只对构建机有意义的副产物。
    ///
    /// - **`.dSYM`**：`swiftc -g` 会顺手 dsymutil 出一个 `lib….dylib.dSYM/`，实测
    ///   **五个加起来 16 MB**——比 dylib 本身还大三倍，而运行期一个字节都不读
    ///   （dyld 不碰它，它只在事后符号化崩溃日志时有用）。留在 bundle 里就是每个
    ///   用户白下 16 MB。真要符号化，那份 dSYM 还在构建机的中间产物里。
    /// - **`.swiftsourceinfo`**：给 IDE 做"跳到定义"用的，运行期同样不读，
    ///   而且它里面**写着构建机上的源码绝对路径**——那是不该跟着分发包出门的东西。
    ///
    /// `.swiftmodule` / `.swiftdoc` 留着：下游插件真要现场编译时
    /// （用户改了 clam-sidebar 的源码而 clam-layout 命中预编译），
    /// swiftc 的 `-I` 就指向这里。
    private static func dropDiagnosticArtifacts(besides dylib: URL) {
        let dir = dylib.deletingLastPathComponent()
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where ["dSYM", "swiftsourceinfo"].contains(entry.pathExtension) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// `strip -x`：去掉局部符号。
    ///
    /// **2026-08-30 实测（分发计划 §2.1 那条"待验证"由此定案）**：五个 dylib
    /// 合计 5457 KB → **2653 KB**，而五个都照常 `dlopen` + `dlsym clam_plugin_entry`
    /// + 调入口拿到插件对象（在一个搬到 `/tmp` 的假 bundle 里验的，纯靠
    /// `@loader_path` 解析上游）。`-x` 只动局部符号，`clam_plugin_entry` 是全局
    /// 导出、插件间链接也走导出符号，Swift 的类型元数据住在 `__swift5_*` 段里
    /// 而不是符号表——三者都不受影响。
    ///
    /// **签名也没坏**：arm64 的 Mach-O 必须带有效签名才装载得起来，而 `strip`
    /// 会把 linker-signed 的 ad-hoc 签名重新盖一遍（实测 `codesign -v` 仍是
    /// "valid on disk"）。M5 的 Developer ID 签名排在本步骤之后，顺序天然正确。
    ///
    /// 代价是崩溃日志里这些 dylib 的栈帧不再有函数名。真要符号化，构建机上还有
    /// 那份没 strip 过的中间产物。
    private static func stripLocalSymbols(_ dylib: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["strip", "-x", dylib.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            // 不致命：没 strip 成功只是包大一点，产物本身是好的。
            print("prebuild: strip 失败（\(dylib.lastPathComponent)），产物照用")
        }
    }

    /// 删掉这一轮不再需要的产物。
    ///
    /// 内容寻址目录只增不删，而 bundle 是要发出去的——留一份上一轮的 dylib 意味着
    /// 每个用户多下几 MB 死重量。判据是"这一轮的清单里有没有它"，
    /// **而且是白名单**：`<Module>/` 底下除了 `prebuilt/` 什么都不该有。
    /// （M1 那版曾往 `<Module>/sources/` 里放过一份源码副本，M3 把源码收进了
    /// `ClamNode/<pkg>/swift/`；只按"这一轮写了什么"删的话，旧布局的残骸会
    /// 安安静静地跟着发出去。）
    private static func prune(root: URL, keep entries: [Manifest.Entry]) {
        let fm = FileManager.default
        let wanted = Set(entries.map { "\($0.module)/prebuilt/\(String($0.contentHash.prefix(12)))" })
        let modules = Set(entries.map(\.module))
        guard let moduleDirs = try? fm.contentsOfDirectory(at: root,
                                                           includingPropertiesForKeys: nil) else { return }
        for moduleDir in moduleDirs {
            let module = moduleDir.lastPathComponent
            guard modules.contains(module) else {
                try? fm.removeItem(at: moduleDir)
                continue
            }
            for child in (try? fm.contentsOfDirectory(at: moduleDir,
                                                      includingPropertiesForKeys: nil)) ?? []
            where child.lastPathComponent != "prebuilt" {
                try? fm.removeItem(at: child)
            }
            let prebuilt = moduleDir.appendingPathComponent("prebuilt", isDirectory: true)
            guard let hashDirs = try? fm.contentsOfDirectory(at: prebuilt,
                                                             includingPropertiesForKeys: nil) else { continue }
            for hashDir in hashDirs where !wanted.contains("\(module)/prebuilt/\(hashDir.lastPathComponent)") {
                try? fm.removeItem(at: hashDir)
            }
        }
    }

    // MARK: - 工具

    /// `dylib` 相对 `Resources/ClamPlugins` 的路径（清单里写相对路径：绝对路径
    /// 一进 bundle 就是错的，构建机的目录结构与用户机器毫无关系）。
    private static func relative(_ url: URL, to root: URL) -> String {
        let a = url.standardizedFileURL.pathComponents
        let b = root.standardizedFileURL.pathComponents
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        return a[i...].joined(separator: "/")
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case CompileError.failed(let log): return "\n\(log)"
        case CompileError.noSources: return "没有源码"
        case CompileError.noToolchain: return "构建机上没有 Swift 工具链（xcrun --find swiftc 失败）"
        default: return "\(error)"
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("prebuild: error: \(message)\n".utf8))
        exit(1)
    }
}

/// `CompilerService` 里唯一一处对壳的路径体系的引用。
///
/// 壳里的 `ClamPaths` 建在 `Bundle.main` 上，而这个工具的 `Bundle.main` 是它自己
/// ——把真的那份编进来只会往 `~/Library/Application Support/` 里写构建期的噪音。
/// 这里给一个 nil，`Log.write` 于是只打印到 stdout（正好进 Xcode 的构建日志）。
enum ClamPaths {
    static let logURL: URL? = nil
}
