import ClamSDK
import Foundation

/// 壳的全部**用户可见**文案，zh 与 en 并排写在同一行（审校时一眼对照）。
///
/// ## 纪律（`docs/clam-i18n-plan.md` §4/§5/§8）
///
/// - **只收用户看得见的字**。`Log.write` / stderr 的日志一律留在原地、保持中文：
///   日志的读者是蹲在终端前的开发者与 agent，跟着界面语言变只会让排错时对不上账。
/// - **一条文案都不进 ClamSDK**：SDK 只有 `ClamLocale` 这个词汇，表各家自己带
///   （壳这一份就是本文件，插件各有各的 `swift/Strings.swift`）。
/// - **带插值/复数的条目写成方法**，不搞 `{name}` 模板替换——Swift 的字符串插值
///   本身就是模板，多一层只是多一处会漏参数的地方。
/// - **漏写 en 编译不过**：typed struct 就是完备性检查，不需要额外的 lint。
/// - 这里没有任何 `LocalizedStringKey`：全是 `String`，SwiftUI 那个隐式重载歧义坑
///   （`clam-settings/README.md` 记过案）在这种形态下自动消失——但别顺手把中文
///   字面量写回视图里。
///
/// ## 取值的地方
///
/// 壳持有 `MainWindowController.activeLocale`（真相来自 dsh 的 `locale` 设置，
/// 决议链见计划 §3），`strings` 属性现算一份 `L`。语言一变，壳重建所有语言相关
/// 表面（菜单栏、提示条、面板）——见 `rebuildLocalizedSurfaces()`。
///
/// ## 打磨过的条目带 `// 原：…` 注释
///
/// 这一遍不是机械搬运：zh 按 Apple 简体中文风格正式化（对照 macOS 系统 App 用词、
/// 菜单项动词开头、省略号只用于"还要再问一步"、不用"您"）。**语气改动较大的条目
/// 在行尾标出原文**，方便 i6 汇总成审校表交用户裁决。
struct L {

    let locale: ClamLocale

    init(_ locale: ClamLocale) { self.locale = locale }

    /// 二选一。写成函数只为让 zh / en 挤在同一行——没有任何查表逻辑。
    private func t(_ zh: String, _ en: String) -> String { locale == .zh ? zh : en }

    // MARK: - 通用按钮

    var ok: String { t("好", "OK") }  // 原：知道了（"壳重建失败"那条提示条上的按钮）
    var cancel: String { t("取消", "Cancel") }
    var copy: String { t("拷贝", "Copy") }
    var close: String { t("关闭", "Close") }
    var retry: String { t("重试", "Try Again") }  // 原：立即重试

    // MARK: - 菜单栏：应用菜单

    var menuAbout: String { t("关于 \(AppInfo.displayName)", "About \(AppInfo.displayName)") }
    var menuSettings: String { t("设置…", "Settings…") }
    var menuReconnect: String { t("重新连接 dsh", "Reconnect to dsh") }
    var menuOpenLogs: String { t("打开日志文件夹", "Open Log Folder") }  // 原：打开日志目录
    var menuDiagnostics: String { t("诊断信息…", "Diagnostics…") }
    var menuHide: String { t("隐藏 \(AppInfo.displayName)", "Hide \(AppInfo.displayName)") }
    var menuHideOthers: String { t("隐藏其他", "Hide Others") }
    var menuShowAll: String { t("全部显示", "Show All") }
    var menuQuit: String { t("退出 \(AppInfo.displayName)", "Quit \(AppInfo.displayName)") }

    // MARK: - 菜单栏：文件

    var menuFile: String { t("文件", "File") }
    var menuNewSession: String { t("新建会话", "New Session") }
    var menuRenameSession: String { t("重命名会话…", "Rename Session…") }
    var menuArchiveSession: String { t("归档会话", "Archive Session") }
    var menuCloseWindow: String { t("关闭窗口", "Close Window") }

    // MARK: - 菜单栏：编辑

    var menuEdit: String { t("编辑", "Edit") }
    var menuUndo: String { t("撤销", "Undo") }
    var menuRedo: String { t("重做", "Redo") }
    var menuCut: String { t("剪切", "Cut") }
    var menuCopy: String { t("拷贝", "Copy") }
    var menuPaste: String { t("粘贴", "Paste") }
    var menuDelete: String { t("删除", "Delete") }
    var menuSelectAll: String { t("全选", "Select All") }

    // MARK: - 菜单栏：显示

    var menuView: String { t("显示", "View") }
    var menuReloadPage: String { t("重新载入页面", "Reload Page") }
    /// macOS 系统术语是"边栏"（访达 → 显示 → 显示边栏），不是"侧边栏"。
    var menuToggleSidebar: String { t("切换边栏", "Toggle Sidebar") }  // 原：切换侧边栏
    var menuFocusSearch: String { t("聚焦搜索", "Focus Search") }
    var menuZoomIn: String { t("放大", "Zoom In") }
    var menuZoomOut: String { t("缩小", "Zoom Out") }
    var menuActualSize: String { t("实际大小", "Actual Size") }

    // MARK: - 菜单栏：会话

    var menuSession: String { t("会话", "Session") }
    var menuPrevSession: String { t("上一个会话", "Previous Session") }
    var menuNextSession: String { t("下一个会话", "Next Session") }
    var menuNextPendingSession: String { t("下一个待处理会话", "Next Pending Session") }
    /// ⌘1…⌘9 那九个隐藏项。隐藏归隐藏，⌘/ 面板会把它们列出来，所以文案照样要翻。
    func menuSessionAt(_ n: Int) -> String { t("会话 \(n)", "Session \(n)") }

    // MARK: - 菜单栏：窗口 / 帮助

    var menuWindow: String { t("窗口", "Window") }
    var menuMinimize: String { t("最小化", "Minimize") }
    var menuZoomWindow: String { t("缩放", "Zoom") }
    var menuHelp: String { t("帮助", "Help") }
    var menuKeyboardShortcuts: String { t("键盘快捷键", "Keyboard Shortcuts") }

    // MARK: - 引导页（没连上 dsh 时铺满窗口的那一屏）

    var bootstrapSearching: String { t("正在查找 dsh…", "Looking for dsh…") }  // 原：正在寻找 dsh…
    var bootstrapReconnecting: String { t("正在重新连接 dsh…", "Reconnecting to dsh…") }

    var bootstrapDisconnectedTitle: String {
        t("已与 dsh 断开连接", "Disconnected from dsh")  // 原：与 dsh 断开连接
    }
    var bootstrapDisconnectedDetail: String {
        t("dsh 已退出或停止响应。在终端重新运行下面的命令，\(AppInfo.displayName) 会自动接回。",
          "dsh has quit or stopped responding. Run the command below in a terminal "
            + "and \(AppInfo.displayName) will reconnect automatically.")
    }  // 原：dsh 已退出或不再应答。重新运行下面的命令，X 会自动接回。

    var bootstrapNotFoundTitle: String { t("找不到 dsh", "dsh Not Found") }  // 原：未检测到 dsh
    var bootstrapNotFoundDetail: String {
        t("\(AppInfo.displayName) 是 dsh 的客户端外设，需要先在终端启动 dsh。"
            + "启动后本窗口会自动接入，无需重新打开 App。",
          "\(AppInfo.displayName) is a client for dsh, which must be running in a terminal "
            + "first. Once it starts, this window connects automatically — no need to reopen the app.")
    }  // 原：X 是 dsh 的客户端外设，需要 dsh 先在终端跑起来；启动后本页会自动接入，无需重开 App。

    var bootstrapErrorTitle: String { t("发生错误", "Something Went Wrong") }  // 原：出错了

    // MARK: - 壳更新提示条

    var shellBuilding: String { t("正在重建壳…", "Rebuilding the shell…") }
    /// `detail` 是构建 hash 与耗时，可能为空。
    func shellUpdateReady(detail: String) -> String {
        let suffix = detail.isEmpty ? "" : t("（\(detail)）", " (\(detail))")
        return t("壳有新版本\(suffix)", "New shell build available\(suffix)")
    }
    var shellRestart: String { t("重启 \(AppInfo.displayName)", "Restart \(AppInfo.displayName)") }
    var shellLater: String { t("稍后", "Later") }
    var shellBuildFailed: String { t("壳重建失败", "Shell build failed") }
    var shellViewLog: String { t("查看日志", "View Log") }  // 原：看日志

    // MARK: - 下载（浮条）与网页弹窗

    func downloadFinished(_ name: String) -> String { t("已下载 \(name)", "Downloaded \(name)") }
    var showInFinder: String { t("在访达中显示", "Show in Finder") }
    func downloadFailed(_ name: String) -> String { t("下载失败：\(name)", "Download failed: \(name)") }
    /// 连文件名都没拿到时的兜底称呼。
    var downloadFallbackName: String { t("文件", "the file") }

    // MARK: - 诊断面板（⌥⌘D）

    var diagnosticsTitle: String { t("\(AppInfo.displayName) 诊断", "\(AppInfo.displayName) Diagnostics") }
    var diagnosticsRefresh: String { t("刷新", "Refresh") }
    var diagnosticsWindowGone: String { t("（窗口已销毁）", "(window released)") }

    func diagBuildTime(_ stamp: String) -> String {
        let value = stamp.isEmpty ? t("未知", "unknown") : stamp
        return t("构建时间：\(value)", "Build time: \(value)")
    }
    var diagSectionConnection: String { t("── dsh 连接 ──", "── dsh Connection ──") }
    func diagEndpoint(_ summary: String) -> String { t("端点：\(summary)", "Endpoint: \(summary)") }
    var diagEndpointNone: String {
        t("端点：未连接（引导页在场）", "Endpoint: not connected (bootstrap screen showing)")
    }
    /// 端点摘要后缀：连上的这套 dsh 不是本 worktree 那一套（`ClamEndpoint.isOwn`）。
    /// 它是**警告**，不是标签——连错了会去编译邻居 worktree 的插件源码。
    var diagEndpointNotOwn: String {
        t(" ⚠️ 不是本 worktree 那一套", " ⚠️ not the one from this worktree")
    }
    func diagEndpointSource(_ source: String) -> String { t("来源：\(source)", "Source: \(source)") }
    func diagBridge(connected: Bool) -> String {
        t("桥：\(connected ? "已连接" : "未连接")", "Bridge: \(connected ? "connected" : "not connected")")
    }
    func diagPageBridge(ready: Bool) -> String {
        t("页内桥：\(ready ? "已就绪" : "未就绪")", "Page bridge: \(ready ? "ready" : "not ready")")
    }
    func diagSidebarGate(on: Bool) -> String {
        t("原生侧边栏门控：\(on ? "开（?clam-native-sidebar=1）" : "关（完整网页模式）")",
          "Native sidebar gate: \(on ? "on (?clam-native-sidebar=1)" : "off (full web mode)")")
    }
    /// `source` 用下面两条描述这个值是从哪一级决议来的。
    func diagLocale(_ id: String, source: String) -> String {
        t("界面语言：\(id)（\(source)）", "Interface language: \(id) (\(source))")
    }
    var diagLocaleFromSystem: String { t("系统语言", "system language") }
    var diagLocaleFromCache: String { t("缓存或页面投影", "cache or page projection") }

    var diagSectionPlugins: String { t("── 原生插件 ──", "── Native Plugins ──") }
    func diagPluginCounts(loaded: Int, retired: Int) -> String {
        t("在役 \(loaded) 个，本次运行退休 \(retired) 个 image",
          "\(loaded) loaded, \(retired) image\(retired == 1 ? "" : "s") retired this run")
    }
    var diagPluginsNone: String {
        t("（一个都没有：root 槽由壳的全出血 WebView 兜底）",
          "(none: the root slot falls back to the shell's full-bleed web view)")
    }
    func diagRootOwner(_ owner: String?) -> String {
        t("root 槽占用者：\(owner ?? "无（兜底 WebView）")",
          "root slot owner: \(owner ?? "none (fallback web view)")")
    }
    func diagSidebarOwner(_ owner: String?) -> String {
        t("sidebar 槽占用者：\(owner ?? "无")", "sidebar slot owner: \(owner ?? "none")")
    }

    var diagSectionShellBuild: String { t("── 壳自身构建 ──", "── Shell Build ──") }
    func diagLastBuild(_ detail: String) -> String { t("最近播报：\(detail)", "Last report: \(detail)") }
    var diagBuildLogTail: String { t("日志尾巴：", "Log tail:") }
    var diagNoBuild: String {
        t("本次连接期间没有重建过（clam-app 没播报过 app-build）",
          "No rebuild during this connection (clam-app never reported app-build)")
    }

    var diagSectionPaths: String { t("── 路径 ──", "── Paths ──") }
    func diagLogPath(_ path: String) -> String { t("日志：\(path)", "Log: \(path)") }
    func diagEndpointsPath(_ path: String) -> String { t("发现文件：\(path)", "Discovery files: \(path)") }
    func diagDiscovered(_ list: String) -> String { t("发现的 dsh：\(list)", "Discovered dsh: \(list)") }
    var diagDiscoveredNone: String { t("无", "none") }

    // MARK: - 快捷键面板（⌘/）

    var shortcutsTitle: String { t("键盘快捷键", "Keyboard Shortcuts") }
    /// 不在任何 NSMenu 里、由页面自己吃掉的按键单列一节。
    var shortcutsInPage: String { t("页面内", "In Page") }
    var shortcutsStopGenerating: String { t("停止生成", "Stop Generating") }  // 原：停止正在生成的回复
    var shortcutsDisabled: String { t("已禁用", "Disabled") }
    /// 空格键没有可读字形，键帽写成词。
    var keySpace: String { t("空格", "Space") }
}
