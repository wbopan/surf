import SwiftUI

/// 一个标签页的外壳：提示条 + 内容 + 自适应高度。
///
/// 版式照 macOS 偏好设置的老规矩（参考 Mimestream）：**右对齐的标签列 + 左对齐的
/// 控件列**，也就是 `Form` 的 `.columns` 样式；组与组之间用一条分隔线，不用方框。
/// 复选框没有左标签——文案就是它自己的标签。
///
/// 内容的**编排**则照 dsh Web 设置对话框（见 `SettingsTabs` 的注释）：
/// 外壳原生、编排一致，两件事互不冲突。
struct SettingsPage: View {
    @ObservedObject var model: SettingsModel
    let tab: SettingsTab
    let openPath: (String) -> Void

    /// 单页最高多少。超了页内滚动，不让窗口长到屏幕外。
    private let maxHeight: CGFloat = 640

    var body: some View {
        VStack(spacing: 0) {
            banners
            content
        }
        .frame(width: SettingsTab.windowWidth, alignment: .top)
        .accessibilityIdentifier("settings.page.\(tab.rawValue)")
    }

    @ViewBuilder
    private var content: some View {
        if !model.loaded {
            // **不显示"没有设置"**：首帧没到跟真的没有是两回事，说错了用户会去查配置。
            VStack(spacing: 8) {
                ProgressView()
                Text(model.strings.connecting).font(.callout).foregroundStyle(.secondary)
            }
            .frame(height: 180)
        } else if let height = tab.height {
            // 定高的页：页内的 List / Table 自己会滚，外面不能再套一层量高度的
            // 滚动容器（见 SettingsTab.height 的注释）。
            page
                .frame(width: SettingsTab.contentWidth, height: height, alignment: .topLeading)
                .padding(.vertical, 20)
                .padding(.horizontal, 26)
        } else {
            SelfSizingScroll(maxHeight: maxHeight) {
                page
                    // 纯表单页在 720 里**取自己的理想宽度再居中**，别摊成一条横线。
                    // `fixedSize` 之所以安全，是因为每条 hint 都有 `maxWidth` 上限
                    // ——否则"理想宽度"就成了最长那句注解的全长，居中反而更歪。
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: SettingsTab.contentWidth, alignment: .center)
                    .padding(.vertical, 20)
                    .padding(.horizontal, 26)
            }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case .general: GeneralPage(model: model, openPath: openPath)
        case .models: ModelsPage(model: model)
        case .plugins: PluginsPage(model: model)
        case .presets: PresetsPage(model: model, openPath: openPath)
        }
    }

    /// 只读与出错的提示条。**贴在页顶而不是弹窗**：设置窗口里弹模态框会打断
    /// 正在改的那一串动作，而这两类消息都不需要立刻决策。
    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 0) {
            if model.loaded && !model.writable {
                Banner(text: model.strings.readOnlyBanner, tint: .orange,
                       dismiss: model.strings.ok, action: nil)
            }
            if let notice = model.notice {
                Banner(text: notice, tint: .red, dismiss: model.strings.ok) { model.notice = nil }
            }
        }
    }
}

/// 页内滚动，但**页高跟着内容走**——直到 `maxHeight` 封顶。
///
/// 偏好设置窗口的尺寸本该等于内容尺寸（`NSTabViewController` 会把窗口动画到
/// 这个尺寸）。直接塞 `ScrollView` 会得到一个理想高度无穷大的东西，窗口就长到
/// 屏幕外去了；所以量一下内容真实高度，取 `min`。
struct SelfSizingScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: Content

    @State private var measured: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured = $0 }
        }
        // **必须显式钉在顶上**：这个 ScrollView 先以无穷高布局一次（那时 measured
        // 还是 0），再被 min(measured, maxHeight) 收窄——收窄时 SwiftUI 默认保住
        // 的是**底部**锚点，于是一进插件列表就停在第 171 条上，搜索框和标题全在
        // 视口外面。看着像"页面自己滚下去了"，其实是被裁的方向反了。
        .defaultScrollAnchor(.top)
        .frame(height: measured <= 0 ? nil : min(measured, maxHeight))
        .scrollDisabled(measured <= maxHeight)
    }
}

struct Banner: View {
    let text: String
    let tint: Color
    /// 关掉这条提示的按钮文案。**由调用方递入**：这个 view 不认识 `L`，
    /// 而它显示的 `text` 本来也是别人算好的（有时是 dsh 的原话）。
    let dismiss: String
    let action: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(tint)
            Text(text).font(.callout).textSelection(.enabled)
            Spacer(minLength: 4)
            if let action {
                Button(dismiss, action: action).controlSize(.small)  // 原：知道了
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(tint.opacity(0.10))
    }
}

/// 字段或嵌套小节。
///
/// 嵌套对象**就地展开成缩进的小节**，不做二级导航：设置树实测最深 4 层，
/// 为它造一层抽屉换来的是每次都多点一下。
struct FieldOrGroup: View {
    @ObservedObject var model: SettingsModel
    let snapshot: NamespaceSnapshot
    let path: [String]
    let node: SchemaNode

    var body: some View {
        if case .object(let fields, _) = node {
            Text(FieldNotes.title(ns: snapshot.ns, path: path, locale: model.locale))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(fields, id: \.key) { field in
                FieldOrGroup(model: model, snapshot: snapshot,
                             path: path + [field.key], node: field.node)
            }
        } else {
            FieldRow(model: model, snapshot: snapshot, path: path, node: node)
        }
    }
}
