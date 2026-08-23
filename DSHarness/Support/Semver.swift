import Foundation

/// 极简 semver 解析（够用即可：dsh 是 0.x.y[-pre]）。
struct Semver: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    init?(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: String
        let pre: [String]
        if let dash = s.firstIndex(of: "-") {
            base = String(s[..<dash])
            pre = s[s.index(after: dash)...].split(separator: ".").map(String.init)
        } else {
            base = s
            pre = []
        }
        let parts = base.split(separator: ".").map { Int($0) ?? -1 }
        guard parts.count >= 1, parts[0] >= 0 else { return nil }
        major = parts[0]
        minor = parts.count > 1 ? parts[1] : 0
        patch = parts.count > 2 ? parts[2] : 0
        prerelease = pre
    }

    var description: String {
        var s = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty { s += "-" + prerelease.joined(separator: ".") }
        return s
    }

    static func < (lhs: Semver, rhs: Semver) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty && !rhs.prerelease.isEmpty { return false }
        if !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return true }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) {
            let ai = Int(a), bi = Int(b)
            if let ai, let bi, ai != bi { return ai < bi }
            if ai == nil && bi != nil { return true }  // 数字段 < 字母段（npm 规则）
            if ai != nil && bi == nil { return false }
            if ai == nil && bi == nil && a != b { return a < b }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
