import Foundation

/// bundle 外 dsh 安装管理：npm 版本目录 + 符号链接原子切换（自更新核心）。
/// 安装布局：<AppSupport>/harness/versions/<semver>/  ← npm --prefix 安装
///           <AppSupport>/harness/current            ← 指向当前版本的符号链接
/// 绝不原地 mutate：新版本装进新目录，校验通过后再切链接，保留上一版可回滚。
final class HarnessManager {
    struct InstalledHarness {
        let version: String
        let entry: URL       // dsh 可执行入口（shim 或 lib/bin.js）
        let runWithNode: Bool // true 时用 `node <entry>` 运行（纯 JS 载荷）
    }

    enum UpdateResult {
        case upToDate(current: String)
        case updated(from: String, to: String)
        case failed(String)
    }

    enum HarnessError: LocalizedError {
        case npmMissing
        case installFailed(String, String)
        case noEntry(String)
        case unknown

        var errorDescription: String? {
            switch self {
            case .npmMissing:
                return "未找到 npm"
            case .installFailed(let v, let detail):
                return "安装 dsh@\(v) 失败：\(detail.isEmpty ? "未知原因" : String(detail.suffix(400)))"
            case .noEntry(let v):
                return "版本 \(v) 目录内未找到 dsh 入口"
            case .unknown:
                return "未知错误"
            }
        }
    }

    let appSupport: URL
    let node: NodeResolver.NodeRuntime
    let logURL: URL

    var harnessRoot: URL { appSupport.appendingPathComponent("harness", isDirectory: true) }
    var versionsDir: URL { harnessRoot.appendingPathComponent("versions", isDirectory: true) }
    var currentLink: URL { harnessRoot.appendingPathComponent("current") }
    var npmCache: URL { appSupport.appendingPathComponent("npm-cache", isDirectory: true) }

    init(appSupport: URL, node: NodeResolver.NodeRuntime) {
        self.appSupport = appSupport
        self.node = node
        self.logURL = appSupport.appendingPathComponent("logs/harness.log")
        let fm = FileManager.default
        try? fm.createDirectory(at: versionsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: npmCache, withIntermediateDirectories: true)
        try? fm.createDirectory(at: appSupport.appendingPathComponent("logs", isDirectory: true), withIntermediateDirectories: true)
    }

    // MARK: - 解析当前安装

    /// 解析 current 链接指向的安装；未安装返回 nil。
    func resolveCurrent() -> InstalledHarness? {
        let dest = currentLink.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: dest.path),
              dest.path.contains(versionsDir.path) else { return nil }
        let version = dest.lastPathComponent
        guard let entry = entryURL(in: dest) else { return nil }
        let runWithNode = entry.pathExtension == "js"
        return InstalledHarness(version: version, entry: entry, runWithNode: runWithNode)
    }

    func currentVersion() -> String? {
        resolveCurrent()?.version
    }

    /// 在版本目录内探测 dsh 入口（npm --prefix 的两种布局 + 纯 JS 兜底）。
    func entryURL(in versionDir: URL) -> URL? {
        let candidates = [
            versionDir.appendingPathComponent("bin/dsh"),
            versionDir.appendingPathComponent("node_modules/.bin/dsh"),
            versionDir.appendingPathComponent("node_modules/@deepseek-ai/dsh/lib/bin.js"),
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c.path) {
            return c
        }
        return nil
    }

    // MARK: - 安装 / 更新

    /// 首次启动：确保已安装，返回当前入口。无 current 时安装 registry 最新版。
    func ensureInstalled() async throws -> InstalledHarness {
        if let current = resolveCurrent() { return current }
        let latest = (try? await latestVersionFromRegistry()) ?? "latest"
        let version = try await install(latest)
        try switchCurrent(to: version)
        guard let installed = resolveCurrent() else { throw HarnessError.unknown }
        Log.write("首次安装完成：dsh@\(installed.version)，入口 \(installed.entry.path)", to: logURL)
        return installed
    }

    /// registry dist-tags.latest（npm view --json）。
    func latestVersionFromRegistry() async throws -> String? {
        guard let npm = node.npmPath else { throw HarnessError.npmMissing }
        let result = await Shell.run(
            executable: npm,
            arguments: ["view", "@deepseek-ai/dsh", "dist-tags.latest", "--json"],
            timeout: 60
        )
        guard result.status == 0, let out = result.stdoutString?
            .trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty else { return nil }
        // --json 输出形如 "0.1.1-rc.2"（带引号）；防御式剥离
        let cleaned = out
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .split(separator: "\n").first.map(String.init) ?? out
        return cleaned
    }

    /// 安装指定版本到独立目录。version 可为 "latest"。返回实际版本目录名。
    func install(_ version: String) async throws -> String {
        let dir = versionsDir.appendingPathComponent(version, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path), entryURL(in: dir) != nil {
            return version
        }
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        guard let npm = node.npmPath else { throw HarnessError.npmMissing }
        let args = [
            "install",
            "--prefix", dir.path,
            "--cache", npmCache.path,
            "--no-audit", "--no-fund",
            "--loglevel=error",
            "@deepseek-ai/dsh@\(version)",
        ]
        let logFile = appSupport.appendingPathComponent("logs/npm-\(version).log")
        Log.write("npm install @deepseek-ai/dsh@\(version) → \(dir.path)", to: logURL)
        let result = await Shell.run(executable: npm, arguments: args, timeout: 600, logFile: logFile)
        guard result.status == 0, let entry = entryURL(in: dir) else {
            let detail = result.stderrString ?? result.stdoutString ?? ""
            throw HarnessError.installFailed(version, detail)
        }
        // 校验：`dsh --version` 退出码 0
        guard verifyEntry(entry: entry, runWithNode: entry.pathExtension == "js") else {
            throw HarnessError.installFailed(version, "版本校验失败（dsh --version 非 0）")
        }
        Log.write("dsh@\(version) 安装并校验通过（\(entry.path)）", to: logURL)
        return version
    }

    /// 原子切换 current → versions/<version>（同卷 rename）。保留 N-1 回滚。
    func switchCurrent(to version: String) throws {
        let dest = versionsDir.appendingPathComponent(version)
        guard FileManager.default.fileExists(atPath: dest.path) else {
            throw HarnessError.installFailed(version, "版本目录缺失")
        }
        let tmp = harnessRoot.appendingPathComponent("current.tmp-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: tmp, withDestinationURL: dest)
        let fm = FileManager.default
        if fm.fileExists(atPath: currentLink.path) {
            _ = try fm.replaceItemAt(currentLink, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: currentLink)
        }
        pruneOldVersions(keep: [version])
        Log.write("current → \(version)", to: logURL)
    }

    /// 清理多余版本：保留 current + 最近一个旧版。
    func pruneOldVersions(keep: [String]) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: versionsDir, includingPropertiesForKeys: nil) else { return }
        var keepSet = Set(keep)
        keepSet.insert(currentVersion() ?? "")
        let candidates = items.filter { $0.hasDirectoryPath && !keepSet.contains($0.lastPathComponent) }
        // 按 semver 取最新一个保留（回滚用），其余删除
        let sorted = candidates
            .compactMap { url -> (String, Semver)? in
                guard let s = Semver(url.lastPathComponent) else { return nil }
                return (url.lastPathComponent, s)
            }
            .sorted { $0.1 > $1.1 }
        for (name, _) in sorted.dropFirst() {
            try? fm.removeItem(at: versionsDir.appendingPathComponent(name))
        }
    }

    func installedVersions() -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: versionsDir, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.hasDirectoryPath }.map { $0.lastPathComponent }
    }

    // MARK: - 更新检查

    func checkForUpdates(force: Bool) async -> UpdateResult {
        guard let current = resolveCurrent() else {
            return .failed("harness 尚未安装")
        }
        let latest: String
        do {
            guard let l = try await latestVersionFromRegistry() else { return .failed("无法查询 npm registry") }
            latest = l
        } catch {
            return .failed("无法查询 npm registry：\(error.localizedDescription)")
        }
        guard let cur = Semver(current.version), let lat = Semver(latest) else {
            return .failed("版本解析失败：\(current.version) / \(latest)")
        }
        if lat <= cur {
            return .upToDate(current: current.version)
        }
        do {
            let version = try await install(latest)
            try switchCurrent(to: version)
            Log.write("自更新完成：\(current.version) → \(version)", to: logURL)
            return .updated(from: current.version, to: version)
        } catch {
            return .failed("安装 \(latest) 失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 校验

    /// 运行 `dsh --version`，退出码 0 视为通过。
    func verifyEntry(entry: URL, runWithNode: Bool) -> Bool {
        if runWithNode {
            return NodeResolver.runCommand(node.nodePath, [entry.path, "--version"]) != nil
        }
        return NodeResolver.runCommand(entry.path, ["--version"]) != nil
    }
}
