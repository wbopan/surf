import AppKit
import SwiftUI

/// 系统 `NSSearchField` 的 SwiftUI 包装。**一点都不自绘。**
///
/// macOS 26 的搜索框是个内置的液态玻璃胶囊：点下去会胀一下、有光效、有聚焦动画，
/// 外加放大镜、清除按钮、取消响应、⌘F 语义、无障碍角色和输入法行为。
/// 这一整套没有一样是拼得出来的——所以这里除了转发文字，什么都不做。
///
/// ## 外框做到 36pt 的正解：`.controlSize(.extraLarge)` 必须设在 **SwiftUI 环境**里
///
/// 曾经试过五条路全量到 24pt，一度断言"cell 只按自然高度画"。**那个断言是错的**，
/// 真相分两半（离屏渲染逐像素量过）：
///
/// 1. macOS 26 的 `NSSearchField` 根本不走 cell 绘制：内部是一个
///    `_NSCoreHostingView<AppKitSearchField>`（SwiftUI 实现）占满整个 frame，
///    胶囊高度只跟 `controlSize` 走——regular=24pt / large=28pt / **extraLarge=36pt**
///    （intrinsicContentSize 同步变），字号、`frame(height:)`、`layout()` 强撑
///    对它一概无效。所以覆写 `NSSearchFieldCell` 的那些 rect 方法是死路，别再试。
/// 2. `makeNSView` 里设 `field.controlSize = .extraLarge` **会被 SwiftUI 悄悄清掉**：
///    NSViewRepresentable 每轮 update 都把环境的 `controlSize`（默认 `.regular`）
///    回写进 NSControl。实测 makeNSView 设了 raw 4，updateNSView 时已被打回 raw 0——
///    这就是当年 `.large`/`.extraLarge` "设了没反应"的全部原因，不报错、不警告。
///
/// 所以唯一有效的写法是在 SwiftUI 侧加 `.controlSize(.extraLarge)`（见 `body`）：
/// 环境值本身就是 extraLarge，回写反而替我们把值钉住。外框仍是系统自己画的
/// 液态玻璃胶囊，按压胀缩、光效、聚焦动画分毫未动。
///
/// 没走 SwiftUI 的 `.searchable`：那个要 `NavigationSplitView` / `NavigationStack`
/// 的上下文才会出现，而本视图是被 `NSHostingController` 直接塞进
/// `NSSplitViewItem(sidebarWithViewController:)` 的——没有导航容器，`.searchable`
/// 会安静地什么都不画。
struct SidebarSearchField: View {
    @Binding var text: String
    /// 占位词由调用方给（文案表在 `Strings.swift`，这里不留字面量）。
    let placeholder: String

    var body: some View {
        Representable(text: $text, placeholder: placeholder)
            // 36pt 外框的开关就这一行；直接贴在 representable 上，
            // 上游谁再设 controlSize 也盖不过来（环境取最近者）。
            .controlSize(.extraLarge)
    }

    private struct Representable: NSViewRepresentable {
        @Binding var text: String
        var placeholder: String

        func makeNSView(context: Context) -> NSSearchField {
            let field = NSSearchField()
            field.placeholderString = placeholder
            field.delegate = context.coordinator
            field.sendsSearchStringImmediately = true
            field.sendsWholeSearchString = false
            // 这里不设 controlSize：设了也会被环境回写覆盖（见顶部注释第 2 条）。
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setAccessibilityIdentifier("sidebar.search")
            return field
        }

        func updateNSView(_ field: NSSearchField, context: Context) {
            // 只在真不一样时写：无条件赋值会在输入法组字期间把候选框打断。
            if field.stringValue != text { field.stringValue = text }
            // 换语言时占位词要跟着换：`makeNSView` 只跑一次，光设在那里的话
            // 语言变了框里还写着上一门语言的「搜索」。
            if field.placeholderString != placeholder { field.placeholderString = placeholder }
        }

        func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

        final class Coordinator: NSObject, NSSearchFieldDelegate {
            private let text: Binding<String>

            init(text: Binding<String>) { self.text = text }

            func controlTextDidChange(_ notification: Notification) {
                guard let field = notification.object as? NSSearchField else { return }
                text.wrappedValue = field.stringValue
            }
        }
    }
}
