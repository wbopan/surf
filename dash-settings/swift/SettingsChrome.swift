import AppKit
import SwiftUI

/// 版式的公用件：只跨控件列的分隔线、源列表的外框与页脚、真的 NSSearchField。
///
/// 抽出来是因为**这套语法要四页一致**才成立（草图见 docs/design/settings-layout/）。
/// 各页各写一遍的下场上一版见过了：一页表单、一页灰色圆角列表、一页手风琴、
/// 一页两列卡片网格——内容都对，四种排版没一种是 macOS 偏好设置那套语法。

/// 一条**只跨控件列**的分隔线。
///
/// 参考设计里这条线从控件列起点开始、到右边距结束——它分的是**控件的组**，
/// 不是页面。`Divider()` 直接放进 `Form` 会横穿整窗（连右对齐的标签列一起劈），
/// 那是"页面分节"的语气；每两三行来一次，整页就被切成了碎片。
///
/// 实现是一行空标签的 `LabeledContent`：`.columns` 样式把标签放左列、内容放右列，
/// 线自然只占右列。**别改成 `Divider().padding(.leading, 170)`**——标签列宽度是
/// `Form` 按内容算出来的，硬编码一个数迟早对不上，而且详情栏的标签列本来就更窄。
struct FormRule: View {
    var body: some View {
        LabeledContent {
            // **不能用 `Divider()`**：它的方向跟着父容器的布局轴走，而
            // `LabeledContent` 内部是 HStack——放进去会得到一条**竖线**
            // （实测：页面上多了三条一指高的竖杠，不报错，就是画错了方向）。
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        } label: {
            // **label 不能是 `EmptyView()`**：那样 `LabeledContent` 整个塌掉，
            // 线会从窗口左边距一直画到右边距（实测过，用红色 3pt 线看出来的）。
            // 要的是「只跨控件列」——给一个零尺寸但**真实存在**的 label，
            // 它照常占住标签列，线就从控件列的起点开始。
            Color.clear.frame(width: 0, height: 0)
        }
    }
}

extension View {
    /// 主从版式左边那根**带边框的源列表**，底下可以挂一条 `+ −`。
    ///
    /// `.listStyle(.bordered)` 就是参考设计里 Accounts 那一列：一圈细边框、圆角、
    /// 选中整行着色，键盘上下键与 ⌘/⇧ 多选都是系统给的。
    ///
    /// **不开 `alternatesRowBackgrounds`**：隔行底色是给多列的表用的（参考设计里
    /// 「共享给你」那张），单列源列表开了只是吵。同一个开关，两种控件，结论相反。
    ///
    /// footer 走 `VStack` 而**不是 `.safeAreaInset`**：SwiftUI 的 bordered list
    /// 不把 inset 收进自己那圈边框里，`.safeAreaInset` 只会得到一条**没对齐、
    /// 还比列表宽**的浮条（实测：`+ −` 跑到列表左边缘外面去了）。macOS 这一代的
    /// 写法本来也是按钮在框外下方（用户与群组、Mimestream 都是），照做就行。
    func sourceListChrome<Footer: View>(width: CGFloat,
                                        @ViewBuilder footer: () -> Footer) -> some View {
        VStack(spacing: 5) {
            listStyle(.bordered).frame(maxWidth: .infinity, maxHeight: .infinity)
            footer()
        }
        .frame(width: width)
    }

    func sourceListChrome(width: CGFloat) -> some View {
        sourceListChrome(width: width) { EmptyView() }
    }
}

/// 源列表底下那条 `+ −`。
///
/// 一对无边框小按钮，靠左，紧贴列表下沿——**没有背景条也没有中缝竖线**。
/// 加了 `.background(.bar)` 会把它变成半截工具条，跟上面那圈细边框对不上，
/// 看着像掉下来的另一个控件。
struct SourceListFooter: View {
    var add: (() -> Void)?
    var addHelp = ""
    var remove: (() -> Void)?
    var removeHelp = ""
    var canRemove = false

    var body: some View {
        HStack(spacing: 2) {
            if let add { button("plus", help: addHelp, enabled: true, action: add) }
            if let remove { button("minus", help: removeHelp, enabled: canRemove, action: remove) }
            Spacer(minLength: 0)
        }
    }

    private func button(_ symbol: String, help: String,
                        enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
        .accessibilityIdentifier("settings.sourcelist.\(symbol)")
    }
}

/// 详情栏顶上那行标题：名字 + 机器标识 + 一句说明。
struct DetailHeader: View {
    let title: String
    var subtitle: String?
    var identifier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(title).font(.body.weight(.semibold))
                if let identifier {
                    Text(identifier).font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 真的 `NSSearchField`。
///
/// SwiftUI 这边只有 `.searchable`，而它要把搜索框塞进**导航容器的工具栏**
/// ——我们这扇窗的工具栏是 `NSTabViewController` 用 `.toolbar` 样式自己建的那排标签，
/// SwiftUI 够不着它，于是 `.searchable` 在这儿一个像素都不会画（不报错，就是没有）。
/// 所以包一层 `NSSearchField` 不是绕路，是拿到这个原生控件的**唯一**路子：
/// 放大镜、清除按钮、占位符行为、Esc 清空全是系统给的。
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        // 边打边过滤。`sendsWholeSearchString = true` 会变成"敲完回车才搜"，
        // 171 条的清单要的是前者。
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        // 只在真的不一样时写回去：无条件赋值会在每次重绘时把插入点顶到行尾。
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = prompt
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

/// 状态点。绿 = 好，红 = 缺东西，灰 = 不知道 / 没在跑。
struct StatusDot: View {
    let color: Color
    var help: String = ""

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7).help(help)
    }
}
