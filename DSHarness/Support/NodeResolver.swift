import Foundation

/// Node.js 运行时定位：按序探测用户设置 → Homebrew 路径，校验版本满足
/// dsh engines（^22.19.0 || >=24.0.0）。
enum NodeResolver {
    static let nodePathKey = "nodePath"

    struct NodeRuntime {
        let nodePath: String
        let npmPath: String?
        let version: String
        var versionDescription: String { version }  // 如 "v26.0.0"
    }

    enum ResolverError: LocalizedError {
        case nodeNotFound([String])
        case versionTooOld(String)
        case npmNotFound

        var errorDescription: String? {
            switch self {
            case .nodeNotFound(let candidates):
                return "未找到 Node.js（已探测：\(candidates.joined(separator: "、"))）。请先安装：brew install node"
            case .versionTooOld(let v):
                return "Node.js \(v) 版本过旧，dsh 需要 ^22.19.0 或 >=24.0.0"
            case .npmNotFound:
                return "未找到 npm（应在 Node 同目录或 PATH 中）"
            }
        }
    }

    /// 探测顺序：用户设置 → /opt/homebrew/bin/node → /usr/local/bin/node
    static func candidates() -> [String] {
        var list: [String] = []
        if let p = UserDefaults.standard.string(forKey: nodePathKey), !p.isEmpty {
            list.append(p)
        }
        list.append("/opt/homebrew/bin/node")
        list.append("/usr/local/bin/node")
        return list
    }

    static func resolve() -> Result<NodeRuntime, ResolverError> {
        for path in candidates() {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            guard let version = runVersion(path) else { continue }
            let vn = parseVersion(version)
            if satisfies(vn) {
                return .success(NodeRuntime(nodePath: path, npmPath: npmPath(for: path), version: version))
            }
            return .failure(.versionTooOld(version))
        }
        return .failure(.nodeNotFound(candidates()))
    }

    /// npm 通常与 node 同目录（Homebrew 布局 /opt/homebrew/bin/{node,npm}）。
    static func npmPath(for nodePath: String) -> String? {
        let dir = (nodePath as NSString).deletingLastPathComponent
        let sibling = (dir as NSString).appendingPathComponent("npm")
        if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        // PATH 兜底
        if let which = runCommand("/usr/bin/which", ["npm"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !which.isEmpty,
           FileManager.default.isExecutableFile(atPath: which) {
            return which
        }
        return nil
    }

    static func runVersion(_ node: String) -> String? {
        runCommand(node, ["--version"])?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseVersion(_ v: String) -> (major: Int, minor: Int) {
        let t = v.hasPrefix("v") ? String(v.dropFirst()) : v
        let parts = t.split(separator: ".").compactMap { Int($0) }
        return (parts.first ?? 0, parts.count > 1 ? parts[1] : 0)
    }

    /// dsh engines：^22.19.0 || >=24.0.0
    static func satisfies(_ v: (major: Int, minor: Int)) -> Bool {
        if v.major >= 24 { return true }
        if v.major == 22 { return v.minor >= 19 }
        return false
    }

    /// 同步运行命令并捕获 stdout（退出码非 0 返回 nil）。输出量必须小。
    static func runCommand(_ launch: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
