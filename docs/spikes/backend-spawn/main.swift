import Foundation

// 隔离验证台：壳的 `ManagedProcess`（原文件直接编进来，不抄一份）到底
// ①有没有让子进程自成进程组、②killpg 送不送得到"孙子"、③输出与退出码收不收得到。
// 用法见 README.md。

let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
let command = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "exec \(here)/fake-dev.sh"

func shell(_ line: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", line]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

let ownPGID = getpgrp()
print("spike pid=\(getpid()) pgid=\(ownPGID)")
print("命令：\(command)")

let done = DispatchSemaphore(value: 0)
let lock = NSLock()
nonisolated(unsafe) var transcript = ""
nonisolated(unsafe) var exitSummary = "（还没退出）"

let child = try ManagedProcess.spawn(command: command, onOutput: { data in
    let text = String(data: data, encoding: .utf8) ?? ""
    lock.lock(); transcript += text; lock.unlock()
    FileHandle.standardOutput.write(Data(("  | " + text).utf8))
}, onExit: { exit in
    exitSummary = exit.summary + (exit.isClean ? "（体面）" : "（不体面）")
    done.signal()
})

print("spawn 出来的 pid=\(child.pid)")
Thread.sleep(forTimeInterval: 1.0)

// ① 进程组：子进程该是自己那一组的组长，而且**不是**壳这一组。
let childPGID = shell("ps -o pgid= -p \(child.pid) | tr -d ' '")
print("断言① 子进程 pgid=\(childPGID) 自己的 pid=\(child.pid) 壳 pgid=\(ownPGID)"
      + (childPGID == "\(child.pid)" && childPGID != "\(ownPGID)" ? " ✅" : " ❌"))

// ② 整组的成员（外层 + 内层都该在）。
let members = shell("ps -ax -o pid,pgid,command | awk '$2 == \(child.pid) { print $1 }' | tr '\\n' ' '")
print("断言② 组内成员：\(members)"
      + (members.split(separator: " ").count >= 2 ? " ✅（外层 + 内层都在）" : " ❌（只有一层）"))

// ③ killpg：TERM 送整组，孙子那一层也该收到。
print("→ terminate()（killpg SIGTERM）")
child.terminate()
let waited = done.wait(timeout: .now() + 3)
print("断言③ 收尸：\(waited == .success ? "\(exitSummary) ✅" : "3s 内没等到 ❌")")

lock.lock()
let sawInnerTerm = transcript.contains("inner got TERM")
lock.unlock()
if command.contains("fake-dev") {
    print("断言④ 内层收到 TERM：" + (sawInnerTerm ? "是 ✅" : "否 ❌（信号漏了孙子进程）"))
}

Thread.sleep(forTimeInterval: 0.3)
let leftovers = shell("ps -ax -o pid,pgid | awk '$2 == \(child.pid) { print $1 }' | tr '\\n' ' '")
print("断言⑤ 组内残留：\(leftovers.isEmpty ? "无 ✅" : leftovers + " ❌")")
print("断言⑥ 壳自己还活着：pid=\(getpid()) ✅（killpg 没波及本组）")
