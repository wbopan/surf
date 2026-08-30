import Foundation

/// 壳自己 spawn 出来的一个受监护子进程：**自成进程组**、输出合流成一条管道、
/// 退出可被感知。`BackendManager` 用它托管后端（`docs/archive/surf-connection-plan.md` §5）。
///
/// **为什么不用 `Foundation.Process`**：`Process` 没有任何办法让子进程自成进程组
/// ——它内部 posix_spawn 时不设 `POSIX_SPAWN_SETPGROUP`，子进程于是继承**壳自己**
/// 的进程组。那种形态下两条路都是死的：`killpg` 会连壳一起杀；只 `kill` 子进程又
/// 漏掉孙子进程——托管跑的 `./dev` 是 `node → spawnSync(dsh)` 两层，node 收到
/// SIGTERM 时正阻塞在 waitpid 里，默认处置直接终止它，dsh 变成孤儿继续占着端口，
/// 而壳这边一切"看上去"都很正常。macOS 也没有 `setsid(1)` 可借（那是 Linux 的）。
///
/// 所以这里直接调 posix_spawn，`posix_spawnattr_setpgroup(&attr, 0)` 让子进程
/// 自己当组长（pgid == pid），之后 `killpg(pid, …)` 精确覆盖整棵子树、一个信号
/// 也落不到壳身上。实测结论见 `docs/spikes/backend-spawn/README.md`。
final class ManagedProcess {

    /// 子进程怎么没的。
    struct Exit: Sendable {
        /// 正常退出的返回码（被信号打断时为 nil）。
        let code: Int32?
        /// 打断它的信号（正常退出时为 nil）。
        let signal: Int32?

        init(status: Int32) {
            // WIFEXITED / WEXITSTATUS 是宏，Swift 里引不到，按 wait(2) 的位布局自己拆。
            if status & 0x7F == 0 {
                code = (status >> 8) & 0xFF
                signal = nil
            } else {
                code = nil
                signal = status & 0x7F
            }
        }

        var summary: String {
            if let signal { return "signal \(signal)" }
            return "code \(code ?? -1)"
        }

        /// 是不是"我们要求它走、它照办了"那一类的收场。
        var isClean: Bool {
            code == 0 || signal == SIGTERM || signal == SIGINT
        }
    }

    enum SpawnError: Error, CustomStringConvertible {
        case pipeFailed(Int32)
        case spawnFailed(Int32)

        var description: String {
            switch self {
            case .pipeFailed(let e): return "pipe() 失败：\(String(cString: strerror(e)))"
            case .spawnFailed(let e): return "posix_spawn 失败：\(String(cString: strerror(e)))"
            }
        }
    }

    /// 子进程 pid，同时也是它的进程组 id（它自己是组长）。
    let pid: pid_t

    private init(pid: pid_t) { self.pid = pid }

    /// 经 **login shell** 拉起一条命令。
    ///
    /// `-l` 是必须的：GUI App 的 PATH 只有 `/usr/bin:/bin:/usr/sbin:/sbin`，
    /// 里面没有 node、没有 homebrew（计划 §1.7）。`zsh -lc` 会读 `.zshenv` /
    /// `.zprofile` / `.zlogin`（**不读 `.zshrc`**——那是交互式 shell 才读的），
    /// 本机实测足以解出 `/opt/homebrew/bin/dsh` 与 node。
    ///
    /// `onOutput` / `onExit` 都在**后台线程**上调用，调用方自己回主线程。
    static func spawn(command: String,
                      onOutput: @escaping @Sendable (Data) -> Void,
                      onExit: @escaping @Sendable (Exit) -> Void) throws -> ManagedProcess {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw SpawnError.pipeFailed(errno) }
        let readFD = fds[0], writeFD = fds[1]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // stdin 接 /dev/null：不给它继承壳的（后端不是交互程序，读到 tty 反而会
        // 撞 SIGTTIN 停住）。stdout / stderr 合流进同一条管道——两股分开读会让
        // 日志里的因果顺序错乱，而排错时正需要那个顺序。
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 2)
        posix_spawn_file_actions_addclose(&actions, readFD)
        posix_spawn_file_actions_addclose(&actions, writeFD)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // **整件事的关键一行**：子进程自成进程组（0 = 用它自己的 pid 当 pgid）。
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        let argv = ["/bin/zsh", "-lc", command]
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgv.append(nil)
        var cEnv: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment
            .map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        defer {
            for p in cArgv where p != nil { free(p) }
            for p in cEnv where p != nil { free(p) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/zsh", &actions, &attr, cArgv, cEnv)
        close(writeFD)
        guard rc == 0 else {
            close(readFD)
            throw SpawnError.spawnFailed(rc)
        }

        let process = ManagedProcess(pid: pid)

        // 读一条管道要一根线程：DispatchIO 也行，但这里读的是一个长期存在的
        // 子进程，一根阻塞线程更好读、也不会和主线程的生命周期纠缠。
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(readFD, $0.baseAddress, $0.count) }
                if n > 0 {
                    onOutput(Data(buffer[0..<n]))
                } else if n == 0 {
                    break                       // 写端全关 = 子进程（连同它的孩子）没了
                } else if errno != EINTR {
                    break
                }
            }
            close(readFD)
        }

        // 收尸也要一根线程。**只能有一个 waitpid 的人**：多处 wait 同一个 pid 会
        // 互相偷走退出状态。
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            onExit(Exit(status: status))
        }

        return process
    }

    /// 还活着吗（信号 0 = 只做权限与存在性检查）。
    var isAlive: Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// 请整个进程组体面退出。
    ///
    /// **一定是 `killpg` 而不是 `kill`**：托管的 `./dev` 底下还挂着真正的 dsh，
    /// 只 TERM 外层 node 会把 dsh 留成孤儿（实测，见 spike README）。
    /// 组不在了（子进程已经退出）就退回单发一枪，两者都失败就当它已经走了。
    func terminate() { signalGroup(SIGTERM) }

    /// 不体面的那一枪（限时等不到时用）。
    func forceKill() { signalGroup(SIGKILL) }

    private func signalGroup(_ sig: Int32) {
        if killpg(pid, sig) == 0 { return }
        if errno == ESRCH { _ = kill(pid, sig) }
    }
}
