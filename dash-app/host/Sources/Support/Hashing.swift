import CryptoKit
import Foundation

/// 增量 SHA-256 的薄封装：内容寻址到处要用，省得每处都写一遍 CryptoKit 样板。
struct SHA256Hasher {
    private var hasher = SHA256()

    mutating func update(_ text: String) {
        hasher.update(data: Data(text.utf8))
        hasher.update(data: Data([0])) // 分隔符：防 "ab"+"c" 与 "a"+"bc" 撞车
    }

    mutating func update(_ data: Data) {
        hasher.update(data: data)
        hasher.update(data: Data([0]))
    }

    func finalizeHex() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
