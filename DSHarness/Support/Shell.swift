import Foundation

/// 外部命令异步执行器：输出捕获 + 超时 + 可选日志落盘。
struct ShellResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
    var stdoutString: String? { String(data: stdout, encoding: .utf8) }
    var stderrString: String? { String(data: stderr, encoding: .utf8) }
}

enum Shell {
    /// 运行命令直到结束。超时(timeout>0)时终止进程并返回 status = -1。
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 300,
        logFile: URL? = nil
    ) async -> ShellResult {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            if let environment { env.merge(environment) { _, new in new } }
            p.environment = env
            if let currentDirectory { p.currentDirectoryURL = currentDirectory }

            let outPipe = Pipe()
            let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe

            // 用类容器避免并发闭包捕获可变 var 的警告
            final class Buffer {
                let lock = NSLock()
                var out = Data()
                var err = Data()
                var log: FileHandle?
            }
            let buffer = Buffer()
            if let logFile {
                FileManager.default.createFile(atPath: logFile.path, contents: nil)
                buffer.log = FileHandle(forWritingAtPath: logFile.path)
            }
            outPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty else { return }
                buffer.lock.lock(); buffer.out.append(d); buffer.lock.unlock()
                buffer.log?.write(d)
            }
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty else { return }
                buffer.lock.lock(); buffer.err.append(d); buffer.lock.unlock()
                buffer.log?.write(d)
            }

            var finished = false
            let finish: (Int32) -> Void = { status in
                guard !finished else { return }
                finished = true
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                try? buffer.log?.close()
                buffer.lock.lock()
                let o = buffer.out
                let e = buffer.err
                buffer.lock.unlock()
                cont.resume(returning: ShellResult(status: status, stdout: o, stderr: e))
            }

            var timer: DispatchSourceTimer?
            if timeout > 0 {
                let t = DispatchSource.makeTimerSource(queue: .global())
                t.schedule(deadline: .now() + timeout)
                t.setEventHandler { p.terminate(); finish(-1) }
                t.resume()
                timer = t
            }

            p.terminationHandler = { proc in
                timer?.cancel()
                finish(proc.terminationStatus)
            }
            do {
                try p.run()
            } catch {
                timer?.cancel()
                finish(-2)
            }
        }
    }
}
