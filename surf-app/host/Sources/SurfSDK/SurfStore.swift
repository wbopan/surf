import Foundation

/// 每插件一个命名空间的小仓库：滚动位置、展开状态、上次选中……
///
/// **尽力而为**（计划 §0.5-1）：读失败一律当没有，等同冷启动。真相在 dsh 侧，
/// 这里存的都是"丢了不心疼"的装饰状态；一旦需要它可靠，说明那份数据放错地方了。
///
/// 落盘位置 `<AppSupport>/native-plugins/store/<插件名>.json`。
/// 插件真被卸载（不是换代）时由壳清空。
public final class SurfStore {
    private let fileURL: URL
    private var cache: [String: String]
    private let queue = DispatchQueue(label: "io.wenbo.surf.store")

    public init(directory: URL, namespace: String) {
        let safe = namespace.replacingOccurrences(of: "/", with: "_")
        self.fileURL = directory.appendingPathComponent("\(safe).json")
        self.cache = SurfStore.load(fileURL)
    }

    private static func load(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return obj
    }

    public func string(_ key: String) -> String? {
        queue.sync { cache[key] }
    }

    public func setString(_ key: String, _ value: String?) {
        queue.sync {
            if let value { cache[key] = value } else { cache.removeValue(forKey: key) }
            flushLocked()
        }
    }

    /// 任意 `Codable` 的糖（内部转 JSON 文本存）。解不出来 = 当没存过。
    public func value<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let text = string(key), let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func setValue<T: Encodable>(_ key: String, _ value: T) {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return }
        setString(key, text)
    }

    private func flushLocked() {
        guard let data = try? JSONSerialization.data(withJSONObject: cache) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
