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
    /// 主从版式左边那根**源列表**：白底、一圈细边框、圆角，底下可以收一条 `+ −`。
    ///
    /// **外框是自己画的，没用 `.listStyle(.bordered)`。** 本来用的是 bordered，
    /// 但那样 `+ −` 只能挂在框外——`.safeAreaInset` 塞不进 bordered list 的边框，
    /// 得到的是一条没对齐、还比列表宽的浮条。而参考里的 Accounts 那一列，
    /// 加减按钮明明在框**里面**（框底一条横线，按钮在线下）。想要那个形状，
    /// 只能 `.plain` + 自己给背景、圆角、描边。
    ///
    /// 行分隔线由各页在 row 上 `.listRowSeparator(.hidden)` 关掉：源列表是一串
    /// 平级的东西，条条画线只是把它切碎；分隔线是给多列的表用的。
    func sourceListChrome<Footer: View>(width: CGFloat,
                                        @ViewBuilder footer: () -> Footer) -> some View {
        VStack(spacing: 0) {
            sourceListBody()
            Divider()
            // `NSViewRepresentable` 在 SwiftUI 里默认居中，得自己顶到左边去。
            HStack(spacing: 0) {
                footer()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
        }
        .sourceListFrame(width: width)
    }

    func sourceListChrome(width: CGFloat) -> some View {
        sourceListBody().sourceListFrame(width: width)
    }

    private func sourceListBody() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sourceListFrame(width: CGFloat) -> some View {
        background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .frame(width: width)
    }
}

/// 源列表底下那条 `+ −`——**在框里面**，紧贴底边那条横线下方。
///
/// 用的是真的 `NSSegmentedControl`（`.smallSquare` + momentary），不是两个
/// `Button` 摆一起。参考图里那对加减中间有一条竖分隔线，那正是分段控件的段间线；
/// 手搓两个按钮再补一条 `Divider()` 能画得很像，但按下态、段宽、图标度量、
/// 禁用时的灰度全得自己维护，而且**永远差一点**——macOS 每代都在改这些材质。
/// 这是整扇窗里"看着像自己画的"最明显的一处，换成系统控件就没有这个问题了。
struct SourceListFooter: NSViewRepresentable {
    /// 两段的 AX 描述。**没有默认值**：AX 描述也是用户"看得见"的字
    /// （旁白会念出来），漏给一个就是漏翻一处，让编译器提醒。
    let addLabel: String
    let removeLabel: String
    var add: (() -> Void)?
    var addHelp = ""
    var remove: (() -> Void)?
    var removeHelp = ""
    var canRemove = false

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = 2
        control.segmentStyle = .smallSquare
        // momentary = 按下就弹回，不留选中态。源列表页脚是动作，不是模式开关。
        control.trackingMode = .momentary
        control.setWidth(26, forSegment: 0)
        control.setWidth(26, forSegment: 1)
        control.target = context.coordinator
        control.action = #selector(Coordinator.fire(_:))
        control.setAccessibilityIdentifier("settings.sourcelist")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.add = add
        context.coordinator.remove = remove
        // **图标在 update 里装，不在 make 里**：AX 描述跟着语言变，而
        // `makeNSView` 一个视图只跑一次——搁在那儿的话换语言之后旁白还念旧词，
        // 而且不报错（这类"设了没反应"的失败在本仓库有一串先例）。
        control.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: addLabel),
                         forSegment: 0)
        control.setImage(NSImage(systemSymbolName: "minus", accessibilityDescription: removeLabel),
                         forSegment: 1)
        control.setEnabled(add != nil, forSegment: 0)
        control.setEnabled(remove != nil && canRemove, forSegment: 1)
        control.setToolTip(addHelp.isEmpty ? nil : addHelp, forSegment: 0)
        control.setToolTip(removeHelp.isEmpty ? nil : removeHelp, forSegment: 1)
    }

    /// **必须实现**：不给 `sizeThatFits`，`NSViewRepresentable` 会吃掉父容器给的
    /// 全部宽度，于是这对加减在列表底下居中——`HStack { footer; Spacer() }` 也顶不动它，
    /// 因为它自己就撑满了。返回控件的固有尺寸，靠左才有意义。
    func sizeThatFits(_ proposal: ProposedViewSize,
                      nsView: NSSegmentedControl,
                      context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var add: (() -> Void)?
        var remove: (() -> Void)?

        @objc func fire(_ sender: NSSegmentedControl) {
            switch sender.selectedSegment {
            case 0: add?()
            case 1: remove?()
            default: break
            }
        }
    }
}

/// 源列表里的分组头。
///
/// 行分隔线撤掉之后，`Section` 自带的头部间距就不够了——「创造模式」和下一组的
/// 「自定义」几乎贴在一起，读不出这是两组。补一点上间距，让分组靠留白成立，
/// 而不是靠一条横线。
struct SourceListSectionHeader: View {
    let title: String

    var body: some View {
        Text(title).padding(.top, 8)
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
///
/// 用 SF Symbol 而不是 `Circle()`：同样是个圆点，但符号走系统的字形度量，
/// 跟着行内文字的基线和字号走，也跟着系统的符号渲染设置变。手画的 `Circle`
/// 得自己钉一个 7×7 并祈祷它在每个字号下都对得上行高。
struct StatusDot: View {
    let color: Color
    var help: String = ""

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 7))
            .foregroundStyle(color)
            .help(help)
    }
}
