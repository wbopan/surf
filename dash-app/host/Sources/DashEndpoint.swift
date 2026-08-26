import Foundation

/// 一个"dsh 在哪"的答案。M1 起壳不再 spawn dsh，只负责找到它。
struct DashEndpoint: Equatable {
    /// 这个答案是从哪来的（诊断用；flag 优先于发现文件）。
    enum Source: String {
        case flag       // 命令行 --dash-endpoint（dash-app 插件拉起时传入）
        case discovery  // endpoint 发现文件（用户手动双击 App 时走这条）
    }

    let httpBase: URL
    /// M4 的桥路径，M1 只透传不使用。
    let bridgePath: String
    let pid: Int?
    let startedAt: String?
    let profile: String?
    /// 写这份发现文件的那个 dsh 的 `dash-app/host` 目录（老版本插件没有这个字段）。
    let hostDir: String?
    let source: Source

    /// 这套 dsh 是不是"我这一套"——它的 dash-app 与本产物出自同一个 worktree。
    ///
    /// **多 worktree 并存时这件事必须问清楚**：插件源码由 dsh 那边的桥登记、
    /// 由壳这边编译装载，连错 dsh = 编译并跑起邻居 worktree 的插件，
    /// 而失败时那条编译错误会原样落进本进程的日志，看上去就像是自己写坏了。
    /// flag 递来的端点天然是自己那套（拉起本进程的就是它），所以直接算真。
    var isOwn: Bool {
        if source == .flag { return true }
        guard let own = DashPaths.ownHostDir, let hostDir else { return false }
        return URL(fileURLWithPath: hostDir).standardizedFileURL.path
            == URL(fileURLWithPath: own).standardizedFileURL.path
    }

    /// 描述给引导页/日志看的一行。
    var summary: String {
        var s = httpBase.absoluteString
        if let profile { s += "（profile \(profile)" }
        if let pid { s += profile == nil ? "（pid \(pid)" : "，pid \(pid)" }
        if profile != nil || pid != nil { s += "）" }
        if !isOwn { s += " ⚠️ 不是本 worktree 那一套" }
        return s
    }
}

/// 三级定位：命令行 flag → endpoint 发现文件 → 都没有（引导页）。
/// 每一级给出的都只是"候选"，真伪由 `probe` 的一次 GET 判定——
/// flag 里的端口可能属于一个已经退出的 dsh。
enum EndpointLocator {
    static let defaultBridgePath = "/dash/bridge"

    // MARK: - 候选

    /// 按优先级排出所有候选；调用方逐个 probe，第一个健康的即答案。
    ///
    /// flag 永远最优先：它是拉起本进程的那个 dsh 亲手递过来的，在多 worktree
    /// 并存时也只会指向"我这一套"。发现文件是给手动双击起来的壳兜底的。
    static func candidates() -> [DashEndpoint] {
        var out: [DashEndpoint] = []
        if let flag = flagEndpoint() { out.append(flag) }
        for disc in discoveredEndpoints() where !out.contains(where: { $0.httpBase == disc.httpBase }) {
            out.append(disc)
        }
        return out
    }

    /// `--dash-endpoint <url>`（也吃 `--dash-endpoint=<url>`）；
    /// 可选 `--dash-bridge-path <path>`。
    static func flagEndpoint() -> DashEndpoint? {
        let args = ProcessInfo.processInfo.arguments
        guard let raw = value(of: "--dash-endpoint", in: args),
              let url = URL(string: raw), url.scheme != nil, url.host != nil else { return nil }
        return DashEndpoint(httpBase: url,
                            bridgePath: value(of: "--dash-bridge-path", in: args) ?? defaultBridgePath,
                            pid: nil, startedAt: nil, profile: nil, hostDir: nil, source: .flag)
    }

    private static func value(of flag: String, in args: [String]) -> String? {
        for (i, a) in args.enumerated() {
            if a == flag, i + 1 < args.count { return args[i + 1] }
            if a.hasPrefix(flag + "=") { return String(a.dropFirst(flag.count + 1)) }
        }
        return nil
    }

    /// endpoint 发现文件，一个 profile 一份。dash-app 插件在 dsh 启动时写、
    /// 退出时删；被 kill -9 的 dsh 会留下陈旧的一份，所以这里只管排出候选，
    /// 死活交给 `probe` 判——扫不到、读坏了、JSON 不成形都当作没有，不崩不报错。
    ///
    /// **先按"是不是我这一套"（`isOwn`），再按 `startedAt` 倒序。**
    ///
    /// 只按 startedAt 排的话，多 worktree 并存时手动双击起来的壳会连上
    /// 最近启动的那个 dsh——很可能是邻居的。那不是个安静的错误：壳会去编译
    /// 邻居 worktree 的插件源码，编译失败时错误落进自己的日志，读日志的人
    /// 完全看不出它属于别人家。同 worktree 的那套永远该排在最前。
    ///
    /// 自己那套没在跑时仍然会退到邻居（总比引导页有用），但 `summary` 会标出来。
    static func discoveredEndpoints() -> [DashEndpoint] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: DashPaths.endpointsDir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap(decodeEndpoint)
            .sorted {
                if $0.isOwn != $1.isOwn { return $0.isOwn }
                return ($0.startedAt ?? "") > ($1.startedAt ?? "")
            }
    }

    /// 单份发现文件 → 候选。内容坏 = nil。
    private static func decodeEndpoint(_ url: URL) -> DashEndpoint? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = obj["httpBase"] as? String,
              let httpURL = URL(string: base), httpURL.host != nil else { return nil }
        return DashEndpoint(httpBase: httpURL,
                            bridgePath: obj["bridgePath"] as? String ?? defaultBridgePath,
                            pid: obj["pid"] as? Int,
                            startedAt: obj["startedAt"] as? String,
                            profile: obj["profile"] as? String,
                            hostDir: obj["hostDir"] as? String,
                            source: .discovery)
    }

    // MARK: - 健康判定

    /// 对 httpBase 发一次 GET。M1 的健康检查就到此为止——
    /// 端口能应答就够，进程监督归 dsh 自己（壳已不是它的父进程）。
    static func probe(_ endpoint: DashEndpoint, timeout: TimeInterval = 1.5) async -> Bool {
        var req = URLRequest(url: endpoint.httpBase)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<400).contains(http.statusCode)
        } catch {
            return false
        }
    }

    /// 走完三级，返回第一个健康的候选；全不健康返回 nil（= 引导页）。
    static func locateHealthy() async -> DashEndpoint? {
        for candidate in candidates() {
            if await probe(candidate) { return candidate }
        }
        return nil
    }
}
