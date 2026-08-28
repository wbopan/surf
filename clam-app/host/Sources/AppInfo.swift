import Foundation

/// App 身份信息统一入口：名字跟随 PRODUCT_NAME（Debug=Surfclam Dev，
/// Release=Surfclam），避免 Swift 里散落硬编码。
enum AppInfo {
    /// 显示名（窗口标题、菜单、“关于”等）。
    static let displayName: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? "Surfclam"

    /// 构建时间戳（prebuild 脚本写入 Resources/BuildTimestamp.txt）。
    static let buildTimestamp: String = {
        guard let url = Bundle.main.url(forResource: "BuildTimestamp", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return "" }
        return text
    }()
}
