import DashSDK
import SwiftUI

/// 导航的一项。
///
/// **顺序即 D2**：精选「通用」在最前保证好用，`llm` 在场时「模型」跟上，
/// 然后是按 ns 平铺的全部命名空间——平铺保证零遗漏，新插件装上自动出现一页，
/// 不需要我们知道它的存在。
enum SettingsPage: Hashable {
    case general
    case models
    case namespace(String)
}

/// 设置窗口的根视图。
///
/// 用 `NavigationSplitView` 而不是自己搭 `NSSplitViewController`：选中态、hover、
/// 键盘上下导航、侧边栏材质全是白送的，自绘一份只会更差——这正是"原生设置窗口"
/// 体感的大头。
struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel
    /// 打开配置文件（壳侧的 NSWorkspace）。
    let openPath: (String) -> Void

    @State private var selection: SettingsPage? = .general

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 176, ideal: 196, max: 260)
        } detail: {
            detail
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { model.refresh() }
        .onChange(of: model.modelsAvailable) { _, available in
            // 模型页消失时别把用户晾在一张空白页上。
            if !available, selection == .models { selection = .general }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                row(.general, "通用", "gearshape")
                if model.modelsAvailable {
                    row(.models, "模型", "cube")
                }
            }
            Section("命名空间") {
                ForEach(model.namespaces) { snapshot in
                    row(.namespace(snapshot.ns), snapshot.ns, symbol(for: snapshot.ns))
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("settings.nav")
        .safeAreaInset(edge: .bottom) { footer }
    }

    private func row(_ page: SettingsPage, _ label: String, _ symbol: String) -> some View {
        Label(label, systemImage: symbol)
            .tag(page)
            .accessibilityIdentifier("settings.nav.\(identifier(for: page))")
    }

    @ViewBuilder
    private var footer: some View {
        // 只在真有文件可开时出现。非文件型 settings provider 返回 undefined，
        // 那时给一个点了没反应的按钮比没有按钮更糟。
        if model.hasDocument {
            VStack(spacing: 0) {
                Divider()
                Button {
                    model.openDocument(openPath)
                } label: {
                    Label("打开配置文件", systemImage: "doc.text")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .accessibilityIdentifier("settings.openDocument")
            }
            .background(.bar)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if !model.loaded {
            ContentUnavailableView("正在连接 dsh…", systemImage: "ellipsis.circle")
        } else {
            switch selection {
            case .general, .none:
                GeneralPage(model: model)
            case .models:
                ModelsPage(model: model)
            case .namespace(let ns):
                if let snapshot = model.namespace(ns) {
                    NamespacePage(model: model, snapshot: snapshot)
                } else {
                    // ns 消失了（插件被卸载）。说清楚，别显示一张空表单。
                    ContentUnavailableView("这个命名空间不在了",
                                           systemImage: "questionmark.folder",
                                           description: Text("提供它的插件可能已经卸载。"))
                }
            }
        }
    }

    private func identifier(for page: SettingsPage) -> String {
        switch page {
        case .general: return "general"
        case .models: return "models"
        case .namespace(let ns): return ns
        }
    }

    /// ns → SF Symbol。
    ///
    /// **认不出来的一律给通用滑块图标**：第三方插件随时会往里加 ns，
    /// 宁可图标平庸也不能让新的一页没有图标、行高不齐。
    private func symbol(for ns: String) -> String {
        switch ns {
        case "shell": return "terminal"
        case "agent-loop", "agent-presets", "agent-default-model": return "arrow.triangle.2.circlepath"
        case "permission-presets": return "lock.shield"
        case "locale": return "globe"
        case "theme": return "paintbrush"
        case "conversation": return "bubble.left.and.bubble.right"
        case "onboarding": return "flag"
        default:
            if ns.hasPrefix("llm-") { return "cube" }
            if ns.hasPrefix("web-search") { return "magnifyingglass" }
            return "slider.horizontal.3"
        }
    }
}
