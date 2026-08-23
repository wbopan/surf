import Foundation
import Darwin

/// spawn `dsh web` 子进程：进程组隔离（killpg 一键清理整棵树）、
/// stdout/stderr 落盘、健康检查、非预期退出指数退避重启。
final class HarnessProcess {
    enum State {
        case idle
        case starting
        case running
        case restarting(attempt: Int)
        case stopped
        case failed(String)
    }

    enum ProcessError: LocalizedError {
        case spawnFailed(String)
        var errorDescription: String? {
            switch self {
            case .spawnFailed(let reason): return "进程启动失败：\(reason)"
            }
        }
    }

    private(set) var pid: pid_t = -1
    private(set) var port: Int = 0
    let logURL: URL

    var onState: ((State) -> Void)?

    private var _state: State = .idle
    var state: State {
        get { _state }
        set {
            _state = newValue
            onState?(newValue)
        }
    }

    private var exitSource: DispatchSourceProcess?
    private var isIntentionalStop = false
    private var restartAttempts = 0
    private var entry: URL?
    private var runWithNode = false
    private var node: NodeResolver.NodeRuntime?
    private var home: URL?

    init(logURL: URL) {
        self.logURL = logURL
    }

    // MARK: - 启动

    /// 拉起 `dsh web --host 127.0.0.1 --port <p> --no-open`。
    /// 可重复调用（先 terminate 再 start 实现重启）。
    func start(entry: URL, node: NodeResolver.NodeRuntime, runWithNode: Bool, home: URL, port: Int) throws {
        self.entry = entry
        self.node = node
        self.runWithNode = runWithNode
        self.home = home
        self.port = port
        isIntentionalStop = false
        restartAttempts = 0
        try spawn()
    }

    private func spawn() throws {
        guard let entry, let node, let home else { return }
        let baseArgs = ["web", "--host", "127.0.0.1", "--port", String(port), "--no-open"]
        let exe = runWithNode ? node.nodePath : entry.path
        let args = runWithNode ? [entry.path] + baseArgs : baseArgs

        // 环境：PATH 前置 node 目录（插件等子进程需要）
        var env = ProcessInfo.processInfo.environment
        let nodeDir = (node.nodePath as NSString).deletingLastPathComponent
        if let path = env["PATH"] {
            env["PATH"] = nodeDir + ":" + path
        } else {
            env["PATH"] = nodeDir
        }
        env["HOME"] = home.path

        // 文件动作：stdout/stderr → 日志（追加），stdin → /dev/null，cwd → home
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        _ = logURL.path.withCString { c in
            posix_spawn_file_actions_addopen(&actions, 1, c, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            posix_spawn_file_actions_addopen(&actions, 2, c, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        }
        _ = "/dev/null".withCString { c in
            posix_spawn_file_actions_addopen(&actions, 0, c, O_RDONLY, 0)
        }
        _ = home.path.withCString { c in
            posix_spawn_file_actions_addchdir(&actions, c)
        }

        // 新进程组：子进程成为组长，之后 killpg 可清理整棵树
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        var argv: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]

        var child: pid_t = 0
        let rc = posix_spawn(&child, exe, &actions, &attr, &argv, &envp)
        self.pid = child

        for p in argv { free(p) }
        for p in envp { free(p) }
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)

        guard rc == 0 else {
            self.pid = -1
            throw ProcessError.spawnFailed(String(cString: strerror(rc)))
        }
        state = .starting
        monitor()
    }

    private func monitor() {
        exitSource?.cancel()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.exitSource?.cancel()
            self.exitSource = nil
            let status = source.data.rawValue
            DispatchQueue.main.async { self.handleExit(status) }
        }
        exitSource = source
        source.resume()
    }

    private func handleExit(_ status: UInt) {
        if isIntentionalStop {
            state = .stopped
            return
        }
        if restartAttempts < 3 {
            restartAttempts += 1
            let delay = min(pow(2.0, Double(restartAttempts - 1)) * 0.5, 10.0)
            state = .restarting(attempt: restartAttempts)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                do {
                    try self.spawn()
                } catch {
                    self.state = .failed(error.localizedDescription)
                }
            }
        } else {
            state = .failed("harness 进程反复退出（exit \(status)）")
        }
    }

    // MARK: - 停止

    /// SIGTERM 整个进程组，超时 SIGKILL。阻塞调用，勿在主线程执行。
    func terminate(waitTimeout: TimeInterval = 5) {
        guard pid > 0 else { return }
        isIntentionalStop = true
        kill(-pid, SIGTERM)
        let deadline = Date().addingTimeInterval(waitTimeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 { pid = -1; return }
            usleep(50_000)
        }
        kill(-pid, SIGKILL)
        let extra = Date().addingTimeInterval(1)
        while Date() < extra {
            if kill(pid, 0) != 0 { break }
            usleep(50_000)
        }
        pid = -1
    }

    func isRunning() -> Bool {
        pid > 0 && kill(pid, 0) == 0
    }

    // MARK: - 工具

    /// 绑定 127.0.0.1:0 取一个空闲端口后立即释放（供 --port 使用）。
    static func pickFreePort() -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return 0 }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, len) }
        }
        guard bindResult == 0 else { return 0 }
        let nameResult = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        guard nameResult == 0 else { return 0 }
        return Int(addr.sin_port.bigEndian)
    }

    /// 轮询 GET / 直到 200 或超时。
    static func waitUntilHealthy(port: Int, timeout: TimeInterval, interval: TimeInterval = 0.4,
                                 completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func probe() {
            guard Date() < deadline else { completion(false); return }
            let url = URL(string: "http://127.0.0.1:\(port)/")!
            var req = URLRequest(url: url)
            req.timeoutInterval = 1.5
            URLSession.shared.dataTask(with: req) { _, response, _ in
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    completion(true)
                } else {
                    DispatchQueue.global().asyncAfter(deadline: .now() + interval, execute: probe)
                }
            }.resume()
        }
        probe()
    }
}
