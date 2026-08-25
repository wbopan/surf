import DashSDK
import SwiftUI

/// 壳挂在窗口上的那一个 SwiftUI 根：把 `root` 槽的视图搬上屏，仅此而已。
///
/// `.id(version)` 是世代替换的落地点（§6.3-2）：插件换代 → 版本号跳变 →
/// SwiftUI 整棵重建、`@State` 归零，需要活过替换的状态由 `DashStore`
/// 或 TS 半身 rehydrate。
///
/// registry 是 `@Observable`，body 里读它即建立依赖，槽一变自动重绘。
struct ShellRootView: View {
    let registry: DashRegistry

    var body: some View {
        if let view = registry.view(for: "root") {
            view.id(registry.version(of: "root"))
        } else {
            // 壳自己的终极逃生舱不在这里——没人占 root 时壳根本不挂载本视图，
            // 露出底下的全出血 WebView。
            Color.clear
        }
    }
}
