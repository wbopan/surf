import SurfSDK
import Foundation

/// 壳的全部**用户可见**文案，zh 与 en 并排写在同一行（审校时一眼对照）。
///
/// ## 纪律（`docs/archive/surf-i18n-plan.md` §4/§5/§8）
///
/// - **只收用户看得见的字**。`Log.write` / stderr 的日志一律留在原地、保持中文：
///   日志的读者是蹲在终端前的开发者与 agent，跟着界面语言变只会让排错时对不上账。
/// - **一条文案都不进 SurfSDK**：SDK 只有 `SurfLocale` 这个词汇，表各家自己带
///   （壳这一份就是本文件，插件各有各的 `swift/Strings.swift`）。
/// - **带插值/复数的条目写成方法**，不搞 `{name}` 模板替换——Swift 的字符串插值
///   本身就是模板，多一层只是多一处会漏参数的地方。
/// - **漏写 en 编译不过**：typed struct 就是完备性检查，不需要额外的 lint。
/// - 这里没有任何 `LocalizedStringKey`：全是 `String`，SwiftUI 那个隐式重载歧义坑
///   （`surf-settings/README.md` 记过案）在这种形态下自动消失——但别顺手把中文
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

    let locale: SurfLocale

    init(_ locale: SurfLocale) { self.locale = locale }

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
    /// 界面上一律称"后端"，不称 dsh（连接页的口径，计划 §3 口径 1）。
    var menuReconnect: String { t("重新连接后端", "Reconnect to Backend") }
    var menuOpenLogs: String { t("打开日志文件夹", "Open Log Folder") }  // 原：打开日志目录
    var menuDiagnostics: String { t("诊断信息…", "Diagnostics…") }
    var menuHide: String { t("隐藏 \(AppInfo.displayName)", "Hide \(AppInfo.displayName)") }
    var menuHideOthers: String { t("隐藏其他", "Hide Others") }
    var menuShowAll: String { t("全部显示", "Show All") }
    var menuQuit: String { t("退出 \(AppInfo.displayName)", "Quit \(AppInfo.displayName)") }

    // MARK: - 菜单栏：文件

    // **业务菜单项的文案不在这儿**：新建/重命名/归档会话、聚焦搜索、整个「会话」
    // 菜单都随插件的命令声明走（`SurfCommand.label`，见 setupMenus 顶注）。
    // 壳只保留自己那些永远在场的项——它们在任何插件配置下都必须可用。

    var menuFile: String { t("文件", "File") }
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
    var menuZoomIn: String { t("放大", "Zoom In") }
    var menuZoomOut: String { t("缩小", "Zoom Out") }
    var menuActualSize: String { t("实际大小", "Actual Size") }

    // MARK: - 菜单栏：窗口 / 帮助

    var menuWindow: String { t("窗口", "Window") }
    var menuMinimize: String { t("最小化", "Minimize") }
    var menuZoomWindow: String { t("缩放", "Zoom") }
    var menuHelp: String { t("帮助", "Help") }
    var menuKeyboardShortcuts: String { t("键盘快捷键", "Keyboard Shortcuts") }

    // MARK: - 连接页（没连上后端时铺满窗口的那一屏）

    // **三条口径**（`docs/archive/surf-connection-plan.md` §3，用户裁决，全部强制）：
    //  1. 面向最终用户：这一节里不出现 ./dev、worktree、profile、pid、hash
    //     ——那些是开发者概念，只活在 ⌥⌘D 诊断面板与日志里。一律称"后端"。
    //  2. 贴系统 App 的密度：短句、事实性，不写"无需操作""发现即自动接入"
    //     这类安抚性废话。
    //  3. zh 逐字来自设计稿（`.scratch/design-connection/*.dc.html`），改文案先改设计稿。

    // 引导连接页

    /// **产品名可以出现**（用户点名要 dsh 这个词）：要藏的是 worktree / profile
    /// 这类开发流程词汇，不是被连的那个东西自己的名字。
    var connIdleTitle: String { t("尚未连接 dsh 后端", "No dsh Backend Connected") }
    var connSearching: String { t("正在查找本机的后端…", "Looking for a backend on this Mac…") }
    /// 发现列表右上角那一行。整屏只剩这一处转圈（M7 起标题区不再有 spinner）。
    var connSearchingShort: String { t("正在查找…", "Searching…") }
    /// 有明确目标（手敲的地址 / 钉死的 URL）却连不上时替掉转圈那一行。
    func connUnreachable(_ address: String) -> String {
        t("无法连接到 \(address)", "Can't reach \(address)")
    }

    var connManagedCardTitle: String {
        t("让 \(AppInfo.displayName) 托管", "Let \(AppInfo.displayName) Manage It")
    }
    var connManagedCardDetail: String {
        t("后端随 \(AppInfo.displayName) 自动启动和退出。",
          "The backend starts and quits with \(AppInfo.displayName).")
    }
    var connManagedStart: String { t("开启托管", "Start Backend") }
    var connManagedStop: String { t("停止托管", "Stop Backend") }
    // 托管状态那一行：界面按状态通用渲染，一态一句（BackendManager.State）。
    var connManagedStarting: String { t("正在启动后端…", "Starting the backend…") }
    var connManagedRunning: String { t("后端运行中。", "The backend is running.") }
    func connManagedRetrying(_ attempt: Int) -> String {
        t("后端已退出，正在第 \(attempt) 次重启…",
          "The backend quit — restart attempt \(attempt)…")
    }
    var connManagedGaveUp: String {
        t("多次启动失败，已停止重试。", "Gave up after repeated failures.")
    }
    /// 拉不起来的三种原因（`BackendManager.Unavailable`）。**如实说缺什么**，
    /// 别把按钮做成没反应。程序名 dsh 在这里是必要的——不说清缺什么就没法照办；
    /// 壳自己也**不代装**（计划裁决②：第一期只服务已经装好后端的本机开发者）。
    var connManagedNoRuntime: String {
        t("未找到后端程序（dsh）。", "Backend program (dsh) not found.")
    }
    /// 装 dsh 的那一行命令。**两种语言下都是这一串**：它是命令，不是文案。
    /// 版本钉死（dsh 没有任何版本协商机制，钉版本就是全部机制）。
    var connInstallDshCommand: String { "npm i -g @deepseek-ai/dsh@0.1.1-rc.2" }
    /// 命令下面那一行。**这句非有不可**：`zsh -lc` 读 `.zshenv`/`.zprofile`/
    /// `.zlogin` 而不读 `.zshrc`，node 只配在 `.zshrc` 里的机器上 dsh 就是查不到
    /// ——不说清楚的话用户会坚称"我明明装了"。
    var connInstallDshHint: String {
        t("已经装过？登录 Shell 不读 ~/.zshrc。把 node 的路径写进 ~/.zprofile 再重新检测。",
          "Already installed? Login shells don't read ~/.zshrc. Add node's path to ~/.zprofile, then check again.")
    }
    var connCopyCommand: String { t("拷贝", "Copy") }
    var connCopiedCommand: String { t("已拷贝", "Copied") }
    /// 缺 dsh 那一态下换掉「开启托管」的按钮标题：这一下的意思是"再查一次"。
    var connManagedRecheck: String { t("重新检测", "Check Again") }
    /// profile 自举没过（`BackendManager.Unavailable.bootstrapFailed`）。
    /// 原因五花八门（旧 profile 残留、磁盘不可写），一句话说不完，指向日志。
    var connManagedBootstrapFailed: String {
        t("后端环境准备失败，详见日志。", "Couldn't prepare the backend environment — see the log.")
    }
    /// 已经有一个后端在管这个 profile：托管不该去抢（会互抹 endpoint 发现文件）。
    var connManagedExternal: String {
        t("后端已在运行，无需托管。", "A backend is already running — no need to manage one.")
    }
    /// 有人在管这个 profile，但探不通。**别写成上面那句**：用户面前是一个都没
    /// 连上的引导页，"无需托管"会把人指向完全错误的方向。如实说它在、还连不上。
    var connManagedExternalUnreachable: String {
        t("后端在运行，但还连不上。",
          "A backend is running but is not reachable yet.")
    }
    var connManagedFailed: String {
        t("后端启动失败，详见日志。", "The backend failed to start — see the log.")
    }

    var connManualCardTitle: String { t("连接到已有的后端", "Connect to an Existing Backend") }
    var connManualCardDetail: String {
        t("通过地址接入正在运行的后端。", "Join a backend that is already running, by address.")
    }
    /// 输入框占位符。**两种语言下都是这一串**：它是个地址范例，不是文案。
    var connManualPlaceholder: String { "http://127.0.0.1:3080" }
    var connManualInvalid: String { t("地址无效", "Invalid address") }

    var connDiscoveredHeader: String { t("发现的后端", "Discovered Backends") }
    func connPort(_ port: Int) -> String { t("端口 \(port)", "Port \(port)") }
    /// `moment` 是格式化好的时刻（"30 分钟前" / "昨天 20:14"）。
    func connStartedAt(_ moment: String) -> String { t("\(moment)启动", "started \(moment)") }
    var connConnect: String { t("连接", "Connect") }

    /// 面板底部那枚复选框：**它就是 `surf.connection.mode == auto` 的投影**，
    /// 不是"这一次要不要自动"。勾上当场接入，取消清回未设置。
    var connAutoAdopt: String { t("自动接入发现的后端", "Automatically join a discovered backend") }
    /// 面板下方那枚复选框：管本次动作落不落盘（托管例外，它本就必须落）。
    var connRememberDefault: String { t("设为默认方式", "Make This the Default") }
    var connRememberDefaultHint: String { t("下次打开时直接使用", "Used directly next time you open the app") }

    var connFooterDiagnostics: String { t("诊断面板 ⌥⌘D", "Diagnostics ⌥⌘D") }
    var connFooterLogs: String { t("打开日志目录", "Open Logs") }

    // 连接中断页

    var connDisconnectedTitle: String { t("已与后端断开连接", "Disconnected from the Backend") }
    var connReconnecting: String { t("正在尝试重新连接…", "Trying to reconnect…") }
    var connSectionDiagnostics: String { t("诊断", "Diagnostics") }

    var connRowBackend: String { t("后端", "Backend") }
    var connRowAddress: String { t("地址", "Address") }
    var connRowReason: String { t("原因", "Reason") }
    var connRowDisconnectedAt: String { t("断开于", "Disconnected") }
    var connRowRetry: String { t("自动重连", "Auto-reconnect") }

    var connBackendLocal: String { t("本机", "This Mac") }
    var connBackendManaged: String {
        t("本机 · 由 \(AppInfo.displayName) 托管", "This Mac · managed by \(AppInfo.displayName)")
    }
    func connBackendRemote(_ host: String) -> String { host }

    var connReasonRefused: String {
        t("连接被拒绝 · 后端进程已退出", "Connection refused · the backend process has quit")
    }
    /// 引导页那一行用的短版：那里还从没连上过，说不出"进程已退出"。
    var connReasonRefusedShort: String { t("连接被拒绝", "Connection refused") }
    var connReasonTimeout: String { t("连接超时", "Connection timed out") }
    func connReasonHTTP(_ code: Int) -> String {
        t("服务器返回 \(code)", "Server returned \(code)")
    }
    /// 桥被拒的用户话术：说"缺组件"而不是"握手失败"（术语），并附启动命令
    /// （connProfileHint*）。典型场景是手动连了 `dsh web`（用户实测提出）。
    var connReasonBridge: String {
        t("该后端不含 Surf 组件", "The backend doesn't include the Surf components")
    }
    /// 正确的启动命令提示，拆成前后缀好把命令段排成等宽字。
    var connProfileHintPrefix: String { t("请用 ", "Start the backend with ") }
    var connProfileHintSuffix: String { t(" 启动后端", "") }
    var connProfileCommand: String { "dsh --profile surf" }
    var connReasonUserRequested: String { t("已手动断开", "Disconnected manually") }
    /// 干净退出的后端会删掉自己的 endpoint 文件，后续轮无候选可 probe、
    /// 产不出 ConnectFailure——这时原因取自 DisconnectReason 而不是"未知"。
    var connReasonProcessGone: String { t("后端进程已退出", "The backend process has quit") }
    var connReasonBridgeLost: String { t("连接中断", "Connection lost") }
    var connReasonUnknown: String { t("未知", "Unknown") }

    /// `moment` 是断开的时刻（"今天 14:32"），`previous` 是此前连了多久（可空）。
    func connDisconnectedAt(_ moment: String, previous: String?) -> String {
        guard let previous else { return moment }
        return t("\(moment) · 此前已连接 \(previous)", "\(moment) · connected for \(previous)")
    }
    func connRetryStatus(attempts: Int, nextIn: Int) -> String {
        t("已试 \(attempts) 次 · 下一次 \(nextIn) 秒后",
          "\(attempts) attempt\(attempts == 1 ? "" : "s") · next in \(nextIn)s")
    }
    var connChooseOther: String { t("连接其他后端…", "Connect to Another Backend…") }

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
        t("端点：未连接（连接页在场）", "Endpoint: not connected (connection screen showing)")
    }
    /// 状态机那一幕的稳定标识（`ConnectionPhase.key`），不翻译——它是个技术词。
    func diagPhase(_ phase: String) -> String { t("连接状态：\(phase)", "Connection phase: \(phase)") }
    func diagMode(_ mode: String, target: String?) -> String {
        let suffix = target.map { " → \($0)" } ?? ""
        return t("连接模式：\(mode)\(suffix)", "Connection mode: \(mode)\(suffix)")
    }
    func diagLastFailure(_ text: String) -> String { t("最近失败：\(text)", "Last failure: \(text)") }
    func diagAttempts(_ count: Int) -> String {
        t("连续失败轮次：\(count)", "Consecutive failed rounds: \(count)")
    }
    /// 并行探测的结果表（每行 `URL 健康/失败 耗时`）。**开发者细节留在这里**
    /// ——worktree、profile、pid、isOwn 一概不上主界面（计划 §3 口径 1）。
    func diagCandidates(_ list: String) -> String {
        t("候选（并行探测）：\(list)", "Candidates (parallel probe): \(list)")
    }
    func diagBackendManager(_ state: String) -> String {
        t("托管后端：\(state)", "Managed backend: \(state)")
    }
    /// 端点摘要后缀：连上的这套 dsh 不是本 worktree 那一套（`SurfEndpoint.isOwn`）。
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
    /// 页面 URL 上那些查询参数（由插件经 `surf.web.query` 说了算，壳不解释）。
    /// `text` 已经拼成 `a=1&b=2` 的样子，空的时候是"（无）"。
    func diagWebQuery(_ text: String) -> String {
        t("页面查询参数：\(text)", "Page query: \(text)")
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
    /// 此刻被占着的槽。**壳只认得 `root`**，别的槽名是插件之间的约定，
    /// 所以这一行照抄 registry 现有的占用，不预设任何槽名。
    func diagSlots(_ list: String) -> String {
        t("已占用的槽：\(list)", "Occupied slots: \(list)")
    }
    /// 插件声明的命令（菜单项 + 快捷键）。第三方"我这条注册上了吗"在这行里有答案。
    func diagCommands(_ count: Int, detail: String) -> String {
        t("命令声明：\(count) 条（\(detail)）", "Declared commands: \(count) (\(detail))")
    }

    var diagSectionShellBuild: String { t("── 壳自身构建 ──", "── Shell Build ──") }
    func diagLastBuild(_ detail: String) -> String { t("最近播报：\(detail)", "Last report: \(detail)") }
    var diagBuildLogTail: String { t("日志尾巴：", "Log tail:") }
    var diagNoBuild: String {
        t("本次连接期间没有重建过（surf-app 没播报过 app-build）",
          "No rebuild during this connection (surf-app never reported app-build)")
    }

    var diagSectionPaths: String { t("── 路径 ──", "── Paths ──") }
    func diagLogPath(_ path: String) -> String { t("日志：\(path)", "Log: \(path)") }
    func diagEndpointsPath(_ path: String) -> String { t("发现文件：\(path)", "Discovery files: \(path)") }
    func diagDiscovered(_ list: String) -> String { t("发现的 dsh：\(list)", "Discovered dsh: \(list)") }
    var diagDiscoveredNone: String { t("无", "none") }

    // MARK: - 快捷键面板（⌘/）

    var shortcutsTitle: String { t("键盘快捷键", "Keyboard Shortcuts") }
    /// 不在任何 NSMenu 里、由页面自己吃掉的按键单列一节。
    /// **这一节里每一行的文案都来自插件的命令声明**，壳只出这个小标题。
    var shortcutsInPage: String { t("页面内", "In Page") }
    var shortcutsDisabled: String { t("已禁用", "Disabled") }
    /// 空格键没有可读字形，键帽写成词。
    var keySpace: String { t("空格", "Space") }
}
