import AppKit
import Foundation
import Observation

/// 托管后端：让壳自己保证"有一个后端在跑"（`docs/clam-connection-plan.md` §5）。
/// 语义照 Docker Desktop——**打开即有、⌘Q 即退**。
///
/// 四件事：
///
/// 1. **spawn**：Dev 壳跑本 worktree 的 `./dev`（白捡 link / profile 判定 /
///    xcodegen 兜底那一整套安装逻辑），Release 壳跑
///    `dsh --profile surfclam --port 0 --no-open`。两者都经 login shell
///    ——GUI App 的 PATH 里没有 node 也没有 homebrew（计划 §1.7）。
/// 2. **查重**：spawn 之前先确认没有别人在管这个 profile（健康的 isOwn 端点 /
///    `io.wenbo.surfclam.dsh` 那个 LaunchAgent）。同一个 profile 的两个 dsh 会
///    **互抹 endpoint 发现文件**（计划 §1.11），抢起来是安静的数据损坏，
///    所以这一步必须先于任何 spawn 生效。
/// 3. **监护**：输出落 `logs/managed-dsh.<instanceTag>.log`；意外退出退避重启
///    （1s / 4s / 15s 三次），60s 窗口里连着败完这三次就进 `.gaveUp` 摊日志。
/// 4. **⌘Q**：SIGTERM 整个进程组 + 限时等 2s（dsh 要跑完 fiber 清理才会删
///    endpoint 文件），配合 AppDelegate 的 `.terminateLater`。
///
/// **连接归位不需要新机制**：子 dsh 照常写 endpoint 发现文件，
/// `ConnectionController` 现有的 2s 轮询自然接上（壳这边只在拉起后催一轮）。
@MainActor
@Observable
final class BackendManager {

    /// 拉不起来的原因。**分类是为了说人话**："缺什么"和"已经有人在管"是两件
    /// 完全不同的事，混成一句"不可用"会让人去查错方向。
    enum Unavailable: Equatable, Sendable {
        /// login shell 里都找不到 `dsh`。**不代装**，只如实说缺什么。
        case missingRuntime
        /// 已经有一个后端在管这个 profile，而且**探得通**（附上它是谁）。
        case externalBackend(String)
        /// 有人在管这个 profile，但此刻**连不上**（附上它是谁）。
        ///
        /// 和上一态分开，是因为对用户而言这是两件相反的事：上一态说"不用你管了"，
        /// 这一态说"它在，只是还没就绪"。**混成一句是实打过的坑**：常驻 daemon
        /// 活着、发现文件却被同 profile 的另一个 dsh 覆盖后带走，壳既发现不了它、
        /// 又因为"daemon 在跑"拒绝 spawn，而界面上写的是"后端已在运行，无需托管"
        /// ——用户面前明明是一个都没连上的引导页，那句话把人指向了完全错误的方向。
        case externalBackendUnreachable(String)
        /// spawn 本身失败（posix_spawn 报错、命令拼不出来）。
        case launchFailed(String)

        /// 诊断面板与日志用的稳定标识（不随界面语言变）。
        var key: String {
            switch self {
            case .missingRuntime: return "missingRuntime"
            case .externalBackend: return "externalBackend"
            case .externalBackendUnreachable: return "externalBackendUnreachable"
            case .launchFailed: return "launchFailed"
            }
        }

        var detail: String {
            switch self {
            case .missingRuntime: return "login shell 里找不到 dsh"
            case .externalBackend(let who): return "已由外部管理：\(who)"
            case .externalBackendUnreachable(let who): return "已由外部管理但探不通：\(who)"
            case .launchFailed(let why): return why
            }
        }
    }

    /// 托管后端此刻的状态。**界面按状态通用渲染**，加一个状态不需要改视图结构。
    enum State: Equatable, Sendable {
        case idle                          // 没在托管（缺省）
        case starting                      // 正在拉起
        case running(pid: Int32)           // 子进程在役
        case retrying(attempt: Int)        // 意外退出，退避重启中
        case gaveUp(reason: String)        // 连败三次，摊开日志等人来看
        case unavailable(Unavailable)      // 拉不起来（缺 dsh / 已被外部管理 / spawn 失败）

        /// 诊断面板与日志用的稳定标识（不随界面语言变）。
        var key: String {
            switch self {
            case .idle: return "idle"
            case .starting: return "starting"
            case .running: return "running"
            case .retrying: return "retrying"
            case .gaveUp: return "gaveUp"
            case .unavailable: return "unavailable"
            }
        }

        /// 这一态下"开启托管"还点不点得动。
        var canStart: Bool {
            switch self {
            case .idle, .gaveUp, .unavailable: return true
            case .starting, .running, .retrying: return false
            }
        }

        /// 这一态下有没有一个自己的后端（或者正在有）。
        var isActive: Bool {
            switch self {
            case .starting, .running, .retrying: return true
            case .idle, .gaveUp, .unavailable: return false
            }
        }
    }

    private(set) var state: State = .idle
    /// 状态变了。视图直接观察 `state`（`@Observable`），这个回调是给壳里
    /// 非 SwiftUI 的消费者留的（`MainWindowController` 拿它在后端起来时催一轮探测）。
    var onStateChange: ((State) -> Void)?

    /// 托管后端的日志文件。跟着**产物**分片（与壳日志同一个键）：
    /// 多 worktree 并存时两个实例的 bundle id 相同，共用一份会把邻居的输出混进来。
    static var logURL: URL {
        let name = ClamPaths.instanceTag.map { "managed-dsh.\($0).log" } ?? "managed-dsh.log"
        return ClamPaths.logsDir.appendingPathComponent(name)
    }

    /// 内存里那截日志尾巴（托管区的日志预览、`.gaveUp` 时摊给人看的那几行）。
    private(set) var recentLog: [String] = []
    private static let recentLogLimit = 200

    // MARK: - 内部账

    private var process: ManagedProcess?
    private var sink: LogSink?
    /// 当前那个子进程的身份。**输出与退出回调靠它认代**：退避重启、用户 stop
    /// 之后又 start，都会让上一代的尸体晚一步回来，认错代就会把新一代的账算错。
    private var spawnToken = 0
    /// 在飞的那一次拉起的身份（查重与 `command -v` 都要 await）。
    /// **和 `spawnToken` 是两件事**：stop 要作废"还没 spawn 的那次拉起"，
    /// 但不能顺手把"已经在跑的那个子进程的退出回调"也一起作废掉——
    /// ⌘Q 正等着那个回调来答复系统。
    private var launchToken = 0
    /// 正在飞的那一次拉起。
    private var launching = false
    /// 子进程输出的半行缓冲（读到的是字节块，不是行）。
    private var pending = ""
    /// 这次退出是我们自己要求的（stop / ⌘Q），别当成意外退出去重启。
    private var expectingExit = false
    /// 60s 窗口里的意外退出时刻表。
    private var failures: [Date] = []
    private var restartWork: DispatchWorkItem?
    /// ⌘Q 的收尾还欠系统一个答复。
    private var terminationPending = false

    /// 退避梯度。**三次**——连着败完这三次（都落在 60s 窗口里）就不再自动重试：
    /// KeepAlive 式的死循环比"停下来摊开日志"糟得多（release 计划 §5 同款教训）。
    private static let backoff: [TimeInterval] = [1, 4, 15]
    private static let failureWindow: TimeInterval = 60
    /// ⌘Q 时给后端收尾的上限。dsh 要跑完 fiber 清理才会删 endpoint 发现文件。
    private static let terminationGrace: TimeInterval = 2

    // MARK: - 动作

    /// 开启托管。查重 → 探 dsh → spawn，三步里任何一步不成都进
    /// `.unavailable` 并如实说是哪一步。
    func start() {
        guard state.canStart, !launching else { return }
        failures.removeAll()
        launch(attempt: 0)
    }

    /// 停止托管：SIGTERM 整个进程组，立刻回 idle（界面不必等它死透）。
    func stop() {
        cancelRestart()
        failures.removeAll()
        launchToken += 1        // 在飞的那次拉起就此作废
        launching = false
        if let process {
            expectingExit = true
            Log.write("停止托管后端（SIGTERM 进程组 \(process.pid)）",
                      to: ClamPaths.logURL, tag: "backend")
            process.terminate()
            // 兜底：限时还没死透就补一枪。手不能停在这儿等——主线程要画界面。
            let grace = Self.terminationGrace
            DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [weak process] in
                guard let process, process.isAlive else { return }
                Log.write("后端 \(grace) 秒内没退出，改发 SIGKILL",
                          to: ClamPaths.logURL, tag: "backend")
                process.forceKill()
            }
        }
        setState(.idle)
    }

    /// "重启后端"：退避计数清零重来。
    func restart() {
        stop()
        start()
    }

    /// 退出前的收尾。返回 true = 还需要等一等（壳那边就该走 `.terminateLater`），
    /// 等完由**这里**替它 `reply(toApplicationShouldTerminate:)`。
    ///
    /// 为什么要等：dsh 收到 SIGTERM 之后要跑完 fiber 清理才会删掉 endpoint
    /// 发现文件。不等的话磁盘上会留一份指向死进程的陈旧文件——下次开 App
    /// 的查重会照着它去 probe（探不通，最终无害），而日志里那一串失败很误导。
    func prepareForTermination() -> Bool {
        cancelRestart()
        launchToken += 1
        launching = false
        guard let process, state.isActive else {
            setState(.idle)
            return false
        }
        expectingExit = true
        terminationPending = true
        Log.write("退出前收尾：SIGTERM 进程组 \(process.pid)，最多等 \(Self.terminationGrace) 秒",
                  to: ClamPaths.logURL, tag: "backend")
        process.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.terminationGrace) { [weak self] in
            self?.finishTermination(timedOut: true)
        }
        return true
    }

    /// 诊断面板那一行（⌥⌘D）。**开发者细节都在这儿**：pid、命令、失败原因。
    var diagnosticSummary: String {
        switch state {
        case .idle: return "idle"
        case .starting: return "starting"
        case .running(let pid): return "running pid \(pid)"
        case .retrying(let attempt): return "retrying #\(attempt)"
        case .gaveUp(let reason): return "gaveUp（\(reason)）"
        case .unavailable(let why): return "unavailable（\(why.detail)）"
        }
    }

    // MARK: - 拉起

    private func launch(attempt: Int) {
        launching = true
        setState(attempt == 0 ? .starting : .retrying(attempt: attempt))
        launchToken += 1
        let generation = launchToken
        Task { @MainActor [weak self] in
            guard let self else { return }
            // ① 查重先行。**安全关键**：这台机器上很可能正开着 `./dev` 或那个
            // 常驻 LaunchAgent，抢同一个 profile 会互抹 endpoint 发现文件。
            let external = Self.skipDedup ? nil : await Self.externalBackend()
            guard generation == self.launchToken else { return }
            if let external {
                self.launching = false
                Log.write("不 spawn：\(external.detail)", to: ClamPaths.logURL, tag: "backend")
                self.setState(.unavailable(external))
                return
            }
            // ② 命令。探不到 dsh 就如实说缺什么，不盲拉。
            let plan = await Self.resolvePlan()
            guard generation == self.launchToken else { return }
            self.launching = false
            guard let plan else {
                Log.write("不 spawn：login shell 里找不到 dsh", to: ClamPaths.logURL, tag: "backend")
                self.setState(.unavailable(.missingRuntime))
                return
            }
            self.spawn(plan)
        }
    }

    private func spawn(_ plan: SpawnPlan) {
        // 上一个还没死透（stop 之后立刻 start）就补一枪：两个后端抢同一个
        // profile 是最该避免的局面。
        if let stale = process {
            stale.forceKill()
            process = nil
        }
        // 新一代开张：上一代的 expectingExit 不能留给它（stop 之后紧接着 start
        // 时，那面旗子会把新进程的意外退出误判成"我们要求的"，于是不重启）。
        expectingExit = false
        pending = ""
        spawnToken += 1
        let generation = spawnToken
        let sink = LogSink(url: Self.logURL)
        sink.header("启动托管后端：\(plan.describe)\n$ \(plan.command)")
        do {
            let child = try ManagedProcess.spawn(command: plan.command, onOutput: { [weak self] data in
                sink.append(data)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.absorb(data, generation: generation) }
                }
            }, onExit: { [weak self] exit in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.processDidExit(exit, generation: generation) }
                }
            })
            self.process = child
            self.sink = sink
            Log.write("托管后端已拉起：pid \(child.pid)（\(plan.describe)），日志 \(Self.logURL.path)",
                      to: ClamPaths.logURL, tag: "backend")
            setState(.running(pid: child.pid))
        } catch {
            let reason = String(describing: error)
            sink.header("拉起失败：\(reason)")
            sink.close()
            Log.write("托管后端拉起失败：\(reason)", to: ClamPaths.logURL, tag: "backend")
            setState(.unavailable(.launchFailed(reason)))
        }
    }

    /// 子进程说了句什么。文件那一份由 `LogSink` 在后台线程写，这里只养
    /// 内存里那截尾巴（界面与 `.gaveUp` 时摊给人看的那几行）。
    private func absorb(_ data: Data, generation: Int) {
        guard generation == spawnToken, let text = String(data: data, encoding: .utf8) else { return }
        pending += text
        while let idx = pending.firstIndex(of: "\n") {
            let line = String(pending[pending.startIndex..<idx])
            pending = String(pending[pending.index(after: idx)...])
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            recentLog.append(line)
        }
        if recentLog.count > Self.recentLogLimit {
            recentLog.removeFirst(recentLog.count - Self.recentLogLimit)
        }
    }

    // MARK: - 退出与退避

    private func processDidExit(_ exit: ManagedProcess.Exit, generation: Int) {
        guard generation == spawnToken else { return }  // 上一代的尸体，不算这一代的账
        process = nil
        sink?.footer("后端退出：\(exit.summary)")
        sink?.close()
        sink = nil

        if terminationPending {
            finishTermination(timedOut: false)
            return
        }
        if expectingExit {
            expectingExit = false
            setState(.idle)
            return
        }

        Log.write("托管后端意外退出：\(exit.summary)", to: ClamPaths.logURL, tag: "backend")
        let now = Date()
        failures = failures.filter { now.timeIntervalSince($0) < Self.failureWindow } + [now]
        guard failures.count <= Self.backoff.count else {
            let reason = "\(failures.count - 1) 次退避重启都没撑住（\(Int(Self.failureWindow))s 窗口）"
            Log.write("放弃托管：\(reason)。最近日志见 \(Self.logURL.path)",
                      to: ClamPaths.logURL, tag: "backend")
            setState(.gaveUp(reason: reason))
            return
        }
        let attempt = failures.count
        let delay = Self.backoff[attempt - 1]
        Log.write("第 \(attempt) 次重启后端，\(Int(delay)) 秒后", to: ClamPaths.logURL, tag: "backend")
        setState(.retrying(attempt: attempt))
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.launch(attempt: attempt) }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelRestart() {
        restartWork?.cancel()
        restartWork = nil
    }

    private func finishTermination(timedOut: Bool) {
        guard terminationPending else { return }
        terminationPending = false
        expectingExit = false
        if timedOut, let process, process.isAlive {
            Log.write("后端没在 \(Self.terminationGrace) 秒内退出，改发 SIGKILL",
                      to: ClamPaths.logURL, tag: "backend")
            process.forceKill()
        } else {
            Log.write("后端已退出，壳继续退出流程", to: ClamPaths.logURL, tag: "backend")
        }
        // `.terminateLater` 之后系统就等着这一句；不答复的话 App 永远退不掉。
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func setState(_ next: State) {
        guard next != state else { return }
        state = next
        Log.write("托管后端状态：\(diagnosticSummary)", to: ClamPaths.logURL, tag: "backend")
        onStateChange?(next)
    }

    // MARK: - spawn 什么

    struct SpawnPlan {
        let command: String
        /// 给日志/诊断看的一句话（不上界面）。
        let describe: String
    }

    /// 这台机器上该拉起什么。nil = 缺 dsh。
    ///
    /// **两种形态**：Dev 壳（bundle 路径推得出 worktree）跑那个 worktree 的
    /// `./dev`——安装、link、profile 判定、xcodegen 兜底全在里面，壳一件都不必抄；
    /// Release 壳跑全局 dsh。两者都 `exec`，让 pid 落在真身上（多一层 zsh
    /// 只会让日志里的 pid 对不上人）。
    private static func resolvePlan() async -> SpawnPlan? {
        if let override = commandOverride {
            return SpawnPlan(command: override, describe: "实测钩子")
        }
        guard let dsh = await which("dsh") else { return nil }
        if let worktree = worktreeRoot(),
           FileManager.default.isExecutableFile(atPath: worktree + "/dev") {
            return SpawnPlan(command: "cd \(quote(worktree)) && exec ./dev",
                             describe: "\(worktree)/dev")
        }
        // **Release 壳必须把形态传给后端**：`CLAM_RELEASE=1` 原先由常驻
        // LaunchAgent 的 plist 提供，那个 daemon 退役之后就没人设它了。缺了它
        // clam-app 会按 dev 形态跑——构建 Debug 产物、**再拉起一个
        // Surfclam Dev**（实测：双击 /Applications 里的 Release，屏幕上却多出
        // 一个 Dev 窗口，两个壳连着同一个后端）。
        // 走 `env` 而不是 `VAR=x exec`：exec 是特殊内建，前缀赋值的语义微妙，
        // 显式一层 env 没有歧义。
        let cmd = isDevShell
            ? "exec \(quote(dsh)) --profile surfclam --port 0 --no-open"
            : "exec /usr/bin/env CLAM_RELEASE=1 \(quote(dsh)) --profile surfclam --port 0 --no-open"
        return SpawnPlan(command: cmd, describe: "\(dsh) --profile surfclam")
    }

    /// `<worktree>/clam-app/host` → `<worktree>`。Release 安装包为 nil。
    private static func worktreeRoot() -> String? {
        guard let hostDir = ClamPaths.ownHostDir else { return nil }
        let url = URL(fileURLWithPath: hostDir).deletingLastPathComponent()  // clam-app
            .deletingLastPathComponent()                                      // worktree
        return url.path
    }

    /// 单引号包一层给 shell。路径里真有单引号也不会破功。
    private static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// login shell 里的 `command -v`。**必须走 login shell**：GUI App 的 PATH
    /// 只有 `/usr/bin:/bin:/usr/sbin:/sbin`，homebrew 与 node 都不在里面。
    private static func which(_ name: String) async -> String? {
        await Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-lc", "command -v \(name)"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            do { try proc.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return path.isEmpty ? nil : path
        }.value
    }

    // MARK: - 查重（计划 §1.11：同 profile 的两个 dsh 会互抹发现文件）

    /// 已经有人在管这个 profile 吗？返回非 nil = 别 spawn，那句话直接进日志。
    ///
    /// **带可达性分类**：两条判据强弱不同，混成一个 `String?` 就没法说人话
    /// （见 `Unavailable.externalBackendUnreachable`）。
    private static func externalBackend() async -> Unavailable? {
        // 两条一起跑（都是几十毫秒的外部调用）。**先报端点**：那是"确实有个活的
        // 后端在这个 profile 上"的硬事实，日志里带着地址与 pid，比一个 daemon
        // 标签好查得多。daemon 那条兜的是"在跑但端点还没出现（或者不见了）"。
        async let endpoint = healthyOwnEndpoint()
        async let daemon = launchAgentRunning()
        if let endpoint = await endpoint { return .externalBackend(endpoint) }
        // 走到这儿 = 一个健康的 isOwn 端点都没有。daemon 仍在跑的话，
        // 它就是"在，但连不上"——绝不能报成"无需托管"。
        if let daemon = await daemon { return .externalBackendUnreachable(daemon) }
        return nil
    }

    /// release 形态那个常驻 LaunchAgent（`docs/release-install-plan.md`）。
    /// 它和托管是**互斥**的两种合法形态：它在跑就轮不到我们。
    /// **`nonisolated`**：查重那两下跑在 `Task.detached` 里（外部命令是阻塞的，
    /// 不该占着主线程），从那里读一个 `@MainActor` 类的静态常量会告警。
    nonisolated static let daemonLabel = "io.wenbo.surfclam.dsh"

    private static func launchAgentRunning() async -> String? {
        await Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            proc.arguments = ["print", "gui/\(getuid())/\(daemonLabel)"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            do { try proc.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            // 没装这个 daemon 时 launchctl 直接非零退出。装了但没在跑
            // （state = not running）也不算——那种时候 spawn 是安全的。
            guard proc.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8),
                  text.contains("state = running") else { return nil }
            return "常驻后端 \(daemonLabel) 正在运行"
        }.value
    }

    /// 发现文件里"我这一套"的那些端点，有没有一个是活的。
    /// 只看 isOwn：邻居 worktree 用的是别的 profile，不冲突。
    private static func healthyOwnEndpoint() async -> String? {
        let own = EndpointLocator.discoveredEndpoints().filter(\.isOwn)
        guard !own.isEmpty else { return nil }
        let statuses = await EndpointLocator.probeAll(own)
        guard let live = statuses.first(where: \.isHealthy) else { return nil }
        return "已有后端在跑：\(live.endpoint.summary)"
    }

    // MARK: - 实测钩子（只有 Dev 壳认这两个 flag）

    /// 是不是 Dev 壳。**判据是 bundle id 的 `.dev` 后缀，不是 `#if DEBUG`**：
    /// 这个工程从来没定义过 `DEBUG`（project.yml 里没设
    /// `SWIFT_ACTIVE_COMPILATION_CONDITIONS`，Debug 产物里 `#if DEBUG` 整块
    /// 都不存在——`strings` 查得到，实测），拿它当门等于把钩子门到不存在。
    private static let isDevShell = Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false

    /// `--clam-backend-command '<shell 命令>'`：拿一个无害的假进程替掉真 spawn，
    /// 用来实测状态迁移 / 日志采集 / 退避三连败 / 进程组信号。
    /// **绝不能在真 profile 上 spawn 一个和用户的 dsh 打架的后端**（计划 §1.11），
    /// 所以那些实测一律走这条路。给了它就跳过 `command -v dsh`（假进程不需要 dsh）。
    private static let commandOverride: String? =
        isDevShell ? argument("--clam-backend-command") : nil

    /// `--clam-backend-skip-dedup`：跳过查重。**只给实测用**——开发机上多半
    /// 正跑着真后端，不跳过就永远走不到 spawn 那一步。
    private static let skipDedup = isDevShell
        && ProcessInfo.processInfo.arguments.contains("--clam-backend-skip-dedup")

    private static func argument(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        for (i, a) in args.enumerated() {
            if a == flag, i + 1 < args.count { return args[i + 1] }
            if a.hasPrefix(flag + "=") { return String(a.dropFirst(flag.count + 1)) }
        }
        return nil
    }
}

// MARK: - 日志落盘

/// 子进程输出的落盘端。**串行队列 + 常开的 FileHandle**：输出是按块来的，
/// 每块都开关一次文件既慢又会把顺序搅乱。
private final class LogSink {
    private let queue = DispatchQueue(label: "io.wenbo.surfclam.backend-log")
    private var handle: FileHandle?
    /// 超过这个大小就从头来过。托管后端可以连着跑很多天，日志不该无限长。
    private static let rotateAbove = 4 * 1024 * 1024

    init(url: URL) {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        if !fm.fileExists(atPath: url.path) || size > Self.rotateAbove {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: url.path)
        handle?.seekToEndOfFile()
    }

    func header(_ text: String) { write("\n===== \(Self.stamp()) \(text) =====\n") }
    func footer(_ text: String) { write("===== \(Self.stamp()) \(text) =====\n") }

    func append(_ data: Data) {
        queue.async { [weak self] in
            self?.handle?.write(data)
        }
    }

    /// **同步**收尾：⌘Q 那条路上，收尸紧接着就是
    /// `reply(toApplicationShouldTerminate:)`，进程随即消失——异步 flush 的话
    /// 那行"后端退出"永远落不到磁盘上（实测：日志停在最后一行 tick）。
    func close() {
        queue.sync {
            try? handle?.close()
            handle = nil
        }
    }

    private func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        append(data)
    }

    private static func stamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
