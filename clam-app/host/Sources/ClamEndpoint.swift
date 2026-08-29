import Foundation

/// 一个"后端在哪"的答案。壳自己不 spawn 后端（托管形态见 `BackendManager`），
/// 这里只负责找到它。
struct ClamEndpoint: Equatable, Sendable {
    /// 这个答案是从哪来的（诊断用；flag 优先于发现文件）。
    enum Source: String, Sendable {
        case flag       // 命令行 --clam-endpoint（clam-app 插件拉起时传入）
        case discovery  // endpoint 发现文件（用户手动双击 App 时走这条）
        case manual     // 用户在连接页里敲的地址（一次性目标，不落偏好）
        case fixed      // 连接偏好 `clam.connection.mode = fixed` 钉死的那一个
    }

    let httpBase: URL
    /// M4 的桥路径，M1 只透传不使用。
    let bridgePath: String
    let pid: Int?
    let startedAt: String?
    let profile: String?
    /// 写这份发现文件的那个 dsh 的 `clam-app/host` 目录（老版本插件没有这个字段）。
    let hostDir: String?
    /// 这个 dsh 期望的 App bundle 路径（老版本插件没有这个字段）。
    ///
    /// dev 形态是本 worktree 的构建产物，release 形态（`CLAM_RELEASE=1` 的常驻
    /// daemon）是 `/Applications/Surfclam.app`。
    let appPath: String?
    let source: Source

    /// 这套 dsh 是不是"我这一套"——它期望伺候的壳就是本进程。
    ///
    /// **多 worktree 并存时这件事必须问清楚**：插件源码由 dsh 那边的桥登记、
    /// 由壳这边编译装载，连错 dsh = 编译并跑起邻居 worktree 的插件，
    /// 而失败时那条编译错误会原样落进本进程的日志，看上去就像是自己写坏了。
    /// flag 递来的端点天然是自己那套（拉起本进程的就是它），所以直接算真。
    ///
    /// 两条判据，**任一成立即算自己那套**：
    ///
    ///  1. `appPath` == 本 bundle 路径。开发期与安装期都成立，是首选。
    ///  2. `hostDir` == `ClamPaths.ownHostDir`。老版本 clam-app 写的发现文件里
    ///     没有 `appPath`，靠这条向后兼容；而它对装到 `/Applications` 的 Release
    ///     产物**必然失败**——那份 bundle 不在任何 worktree 的
    ///     `build/Build/Products/` 之下，`ownHostDir` 根本推不出来。
    ///
    /// 缺了第 1 条的后果不是报错而是**安静地连错**：`isOwn` 恒假 → 候选只能按
    /// `startedAt` 倒序排 → 装好的壳挑中最近启动的邻居 dsh。
    var isOwn: Bool {
        if source == .flag { return true }
        if let appPath, Self.samePath(appPath, Bundle.main.bundlePath) { return true }
        guard let own = ClamPaths.ownHostDir, let hostDir else { return false }
        return Self.samePath(hostDir, own)
    }

    /// 两个路径是不是同一个东西。解符号链接再比——`/Applications` 与 worktree
    /// 都可能躺在链接后面，纯字符串比较会给出假阴性（同样是安静的连错）。
    /// 路径不存在时 `resolvingSymlinksInPath` 原样返回，退化成标准化比较。
    private static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().standardizedFileURL.path
            == URL(fileURLWithPath: b).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// 端口号。连接页只以端口称呼一个后端（"端口 3080"）——主机永远是本机，
    /// 而 profile / worktree / pid 都是开发者概念，不上主界面（计划 §3 口径 1）。
    var port: Int? { httpBase.port }

    /// 发现文件里那个 ISO8601 启动时刻。解析不出来 = nil（连接页那一行就不显示）。
    var startedAtDate: Date? {
        guard let startedAt else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: startedAt) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: startedAt)
    }

    /// 描述给诊断面板/日志看的一行。
    ///
    /// **刻意不带任何自然语言**：里面只有 URL、profile 名、pid 这些技术标识，
    /// 两种界面语言下长得一模一样。"这不是本 worktree 那一套"那句警告因此
    /// 不在这里拼——它是文案，归 `L.diagEndpointNotOwn`（诊断面板）与调用方的
    /// 日志各自加（日志一律留中文，见 Strings.swift 顶注）。
    var summary: String {
        var parts: [String] = []
        if let profile { parts.append("profile \(profile)") }
        if let pid { parts.append("pid \(pid)") }
        guard !parts.isEmpty else { return httpBase.absoluteString }
        return httpBase.absoluteString + " (" + parts.joined(separator: ", ") + ")"
    }
}

/// 三级定位：命令行 flag → endpoint 发现文件 → 都没有（引导页）。
/// 每一级给出的都只是"候选"，真伪由 `probe` 的一次 GET 判定——
/// flag 里的端口可能属于一个已经退出的 dsh。
enum EndpointLocator {
    static let defaultBridgePath = "/clam/bridge"

    // MARK: - 候选

    /// 按优先级排出所有候选；调用方逐个 probe，第一个健康的即答案。
    ///
    /// flag 永远最优先：它是拉起本进程的那个 dsh 亲手递过来的，在多 worktree
    /// 并存时也只会指向"我这一套"。发现文件是给手动双击起来的壳兜底的。
    static func candidates() -> [ClamEndpoint] {
        var out: [ClamEndpoint] = []
        if let flag = flagEndpoint() { out.append(flag) }
        for disc in discoveredEndpoints() where !out.contains(where: { $0.httpBase == disc.httpBase }) {
            out.append(disc)
        }
        return out
    }

    /// `--clam-endpoint <url>`（也吃 `--clam-endpoint=<url>`）；
    /// 可选 `--clam-bridge-path <path>`。
    static func flagEndpoint() -> ClamEndpoint? {
        let args = ProcessInfo.processInfo.arguments
        guard let raw = value(of: "--clam-endpoint", in: args),
              let url = URL(string: raw), url.scheme != nil, url.host != nil else { return nil }
        return ClamEndpoint(httpBase: url,
                            bridgePath: value(of: "--clam-bridge-path", in: args) ?? defaultBridgePath,
                            pid: nil, startedAt: nil, profile: nil, hostDir: nil, appPath: nil,
                            source: .flag)
    }

    private static func value(of flag: String, in args: [String]) -> String? {
        for (i, a) in args.enumerated() {
            if a == flag, i + 1 < args.count { return args[i + 1] }
            if a.hasPrefix(flag + "=") { return String(a.dropFirst(flag.count + 1)) }
        }
        return nil
    }

    /// endpoint 发现文件，一个 profile 一份。clam-app 插件在 dsh 启动时写、
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
    static func discoveredEndpoints() -> [ClamEndpoint] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: ClamPaths.endpointsDir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap(decodeEndpoint)
            .sorted {
                if $0.isOwn != $1.isOwn { return $0.isOwn }
                return ($0.startedAt ?? "") > ($1.startedAt ?? "")
            }
    }

    /// 单份发现文件 → 候选。内容坏 = nil。
    private static func decodeEndpoint(_ url: URL) -> ClamEndpoint? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = obj["httpBase"] as? String,
              let httpURL = URL(string: base), httpURL.host != nil else { return nil }
        return ClamEndpoint(httpBase: httpURL,
                            bridgePath: obj["bridgePath"] as? String ?? defaultBridgePath,
                            pid: obj["pid"] as? Int,
                            startedAt: obj["startedAt"] as? String,
                            profile: obj["profile"] as? String,
                            hostDir: obj["hostDir"] as? String,
                            appPath: obj["appPath"] as? String,
                            source: .discovery)
    }

    // MARK: - 健康判定

    /// 对 httpBase 发一次 GET。健康检查就到此为止——端口能应答就够，
    /// 进程监督归后端自己（壳已不是它的父进程）。
    ///
    /// **返回 nil = 健康**，否则是分类过的失败原因（`ConnectionController` 拿它
    /// 拼"原因"那一行，诊断面板拿它标每个候选的死活）。
    static func probe(_ endpoint: ClamEndpoint, timeout: TimeInterval = 1.5) async -> ConnectFailure? {
        var req = URLRequest(url: endpoint.httpBase)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            // http(s) 的响应必然是 HTTPURLResponse；真拿到别的东西说明这地址根本
            // 不是个 HTTP 服务，与"连不上"同类。
            guard let http = response as? HTTPURLResponse else { return .refused }
            return (200..<400).contains(http.statusCode) ? nil : .httpError(http.statusCode)
        } catch {
            return classify(error)
        }
    }

    /// URLSession 的错误码 → 失败分类。认不出来的一律当"连不上"：
    /// 界面上"连接被拒绝"比"未知错误"更接近事实（后端不在那儿）。
    private static func classify(_ error: Error) -> ConnectFailure {
        guard let urlError = error as? URLError else { return .refused }
        switch urlError.code {
        case .timedOut: return .timeout
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed, .badServerResponse:
            return .refused
        default: return .refused
        }
    }

    /// **并行**探测一整批候选，返回与入参同序的健康态表。
    ///
    /// 串行版（逐个 await，单个超时 1.5s）在候选多且有死候选时线性变慢：
    /// 三个死候选就是 4.5s，而轮询周期只有 2s——轮与轮会叠起来。并行之后
    /// 整轮的最坏耗时就是单个超时。
    static func probeAll(_ list: [ClamEndpoint], timeout: TimeInterval = 1.5) async -> [CandidateStatus] {
        guard !list.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, CandidateStatus).self) { group in
            for (index, endpoint) in list.enumerated() {
                group.addTask {
                    let started = Date()
                    let failure = await probe(endpoint, timeout: timeout)
                    return (index, CandidateStatus(endpoint: endpoint,
                                                   failure: failure,
                                                   elapsed: Date().timeIntervalSince(started)))
                }
            }
            // TaskGroup 的完成顺序是先到先得，而调用方要的是**优先级顺序**
            // （flag > isOwn > startedAt）——按下标回填才不会把选取规则搅乱。
            var slots = [CandidateStatus?](repeating: nil, count: list.count)
            for await (index, status) in group { slots[index] = status }
            return slots.compactMap { $0 }
        }
    }

    /// 用一个完整 URL 拼一个候选（用户手敲的地址 / `fixed` 模式钉死的那一个）。
    /// bridgePath 用默认值——发现文件之外没有别的地方能告诉我们它。
    static func manualEndpoint(_ url: URL, source: ClamEndpoint.Source) -> ClamEndpoint {
        ClamEndpoint(httpBase: url, bridgePath: defaultBridgePath,
                     pid: nil, startedAt: nil, profile: nil, hostDir: nil, appPath: nil,
                     source: source)
    }
}
