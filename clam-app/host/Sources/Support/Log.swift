import Foundation

/// 极简日志：控制台 + 可选文件。
enum Log {
    private static let lock = NSLock()
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func write(_ message: String, to url: URL? = nil, tag: String = "dash") {
        let line = "\(formatter.string(from: Date())) [\(tag)] \(message)\n"
        print(line, terminator: "")
        guard let url else { return }
        lock.lock()
        defer { lock.unlock() }
        if let h = FileHandle(forWritingAtPath: url.path) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }
}
