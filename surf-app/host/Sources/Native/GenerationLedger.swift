import Foundation

/// 世代账本（计划 §6.2/§6.4）：装载历史与退休 image 计数。
///
/// 两个用途：诊断（"我现在跑的到底是哪一份代码"）与回收阈值（旧 dylib 按设计
/// 不 dlclose，退休多了就该找个空闲时刻自重启）。M9 才做 hash 审计与自重启，
/// 这里先把账记上。
final class GenerationLedger {
    private struct Entry: Codable {
        let plugin: String
        let module: String
        let hash: String?
        let event: String       // "load" | "retire"
        let at: String
    }

    private let url: URL
    private var entries: [Entry]
    /// 一条记录上限：账本是诊断素材，不是审计日志，不必无限长。
    private let limit = 500

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
    }

    /// 本次进程启动以来退休的 image 数（§6.4 的双阈值之一）。
    private(set) var retiredThisRun = 0

    func recordLoad(plugin: String, module: String, hash: String) {
        append(Entry(plugin: plugin, module: module, hash: hash, event: "load", at: stamp()))
    }

    func recordRetire(plugin: String, module: String) {
        retiredThisRun += 1
        append(Entry(plugin: plugin, module: module, hash: nil, event: "retire", at: stamp()))
    }

    private func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func stamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
