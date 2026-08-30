import AppKit
import WebKit

/// 主 WebView 的薄子类，两件事：
///
/// 1. **把插件命令的键位从 WebKit 嘴里抢回来**（`performKeyEquivalent` 覆写 +
///    `commandKeyEquivalents` 影子菜单，见下面那一段注释）；
/// 2. **把 WebKit 默认右键菜单里的浏览器味导航项裁掉**（`willOpenMenu`，
///    本注释余下部分讲的都是它）。
///
/// **为什么要裁**：WKWebView 的默认菜单是给浏览器设计的——正文空白处右键弹的是
/// "Reload"，链接上多一条 "Open Link in New Window"。surfclam 是一扇文档窗口，
/// 没有地址栏、没有后退按钮，这几条一出来就穿帮（用户按了 Reload，dsh 页面整个
/// 重载、会话滚动位置全没了，而屏幕上没有任何东西暗示这是一次"刷新网页"）。
///
/// **裁法是黑名单而不是白名单，判据是失效方向**：认不出的 identifier（以及
/// identifier 为 nil 的项，分隔符与 AppKit 自己塞的东西都是这样）**一律保留**。
/// WebKit 升级新增了菜单项，最坏结果是多出一条我们没审过的项；反过来写成白名单的话，
/// 升级改名会把 Copy 也裁掉——那是不可接受的方向。
///
/// **identifier 的字面量就等于常量名**（`WKMenuItemIdentifierReload`）。这些常量
/// 没有公开头文件、`dlsym` 也取不到（本机实测全部 MISSING），下面这张表是从**真菜单**
/// 里读回来的：`docs/spikes/apple-visual-effect/` 的 `CLAM_SPIKE_DUMP_MENU=plain|
/// selection|link` 会把每一项的 identifier 与标题转储出来。WebKit 升级后按同样办法复核。
///
/// 三条实测事实（同一份 spike 的 README 有完整记录）：
///
/// 1. **"Services" 与 "Ask Siri" 是 AppKit 在 `willOpenMenu` 之后自己加的**，
///    根本不经过我们的手——所以这里没有、也不需要"保留 Services"这回事。
/// 2. **AppKit 会自己折叠连续的分隔符**（实拍：转储里连着三条，屏幕上只有一条）。
///    下面仍然收一轮，是为了裁掉首项之后留下的**行首**分隔符——那一类没验过。
/// 3. **把菜单裁空不会露出空框**，屏幕上就是什么都不弹。这正合适：Release 下
///    `isInspectable` 是关的，正文空白处的默认菜单只有 Reload + 两条分隔符，
///    裁完就是空——而"空白处右键什么都不弹"正是原生文档 App 的行为。
final class ClamWebView: WKWebView {

    // MARK: - 键位：插件命令优先于网页

    /// **插件贡献的那些菜单项的一份克隆**，摊平成一张永不显示的菜单，
    /// 只用来做键位匹配。由 `MainWindowController.setupMenus()` 每次重建菜单时换新
    /// （见那边的 `commandKeyEquivalentMenu`），缺席 = 一条都不抢。
    ///
    /// **为什么必须有这一层**（`docs/spikes/webview-key-equivalent/` 可复跑）：
    /// AppKit 派发 keyDown 时**先走视图层级的 `performKeyEquivalent`、主菜单排在后面**，
    /// 而 WKWebView 在可编辑区域（dsh 的输入框）有焦点时会把一批带 ⌘ 的删除类组合
    /// 当成自己的编辑命令**吃掉并返回 true**——⌘⌫、⌘⇧⌫ 都在其中（前者删到行首，
    /// 后者也删到行首）。于是 clam-sidebar 声明的 ⌘⇧⌫「归档会话」
    /// **只有在焦点不在输入框时才触发**，焦点一进 composer 就静默失效：
    /// 菜单项好好地画着键符、按下去什么都不发生，还顺手把用户输了一半的字删了。
    ///
    /// **两条实测边界，别推广成"WebView 里 ⌘ 组合都到不了菜单"**：同一次运行里
    /// ⌘⇧⌦ 与 ⌘⇧A 都是 `performKeyEquivalent -> false`、菜单照常触发。
    /// 被吃掉的只有 WebKit 自己认领的那几个编辑组合，所以这里也**只抢插件声明过的**
    /// ——认不出的一律原样交给 WebKit，失效方向是"网页照常"而不是"网页哑了"。
    var commandKeyEquivalents: NSMenu?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // 命中 = 这个键位是插件声明的命令，网页不该看见它（连 keydown 都不该收到，
        // 实测确认：影子菜单命中后 textarea 的内容与 jsLog 都纹丝不动）。
        if commandKeyEquivalents?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - 右键菜单

    /// 要裁掉的项。**只裁导航**：把页面换掉、或者开出第二扇浏览器窗口的那些。
    ///
    /// 明确**不裁**、并且各有理由的几类：
    /// - `Copy` / `CopyLink` / `CopyImage` / `CopyLinkWithHighlight`：文本操作，原生同款。
    /// - `LookUp` / `Translate` / `SearchWeb` / `SpeechMenu` / `WritingTools`：
    ///   系统文本服务，原生 App（备忘录、邮件）里也是这几条。
    /// - `ShareMenu`：`NSSharingServicePicker`，真原生。
    /// - `Download*`：下载走 WebPolicy 落到 ~/Downloads，是我们支持的能力，不是穿帮。
    /// - `OpenLink`（不带 "in New Window"）：外链会被 WebPolicy 拦成
    ///   `NSWorkspace.open` 交给系统浏览器，同源的就地导航本就是正常行为。
    /// - `InspectElement`：只有 `isInspectable` 时 WebKit 才加，而那只在 Debug 开。
    private static let droppedIdentifiers: Set<String> = [
        // 页面级导航：壳没有地址栏/后退键，这三条一出现就是浏览器。
        "WKMenuItemIdentifierReload",
        "WKMenuItemIdentifierGoBack",
        "WKMenuItemIdentifierGoForward",
        // "在新窗口打开"：WebPolicy 确实能开出次级窗口，但那是给页面
        // `target="_blank"` 用的逃生舱，不该做成用户随手可及的浏览器动作。
        "WKMenuItemIdentifierOpenLinkInNewWindow",
        "WKMenuItemIdentifierOpenImageInNewWindow",
        "WKMenuItemIdentifierOpenFrameInNewWindow",
        "WKMenuItemIdentifierOpenMediaInNewWindow",
    ]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        // 先让 WebKit 把自己那套装配完（它在这一步记菜单状态），再动手裁。
        super.willOpenMenu(menu, with: event)
        for item in menu.items.reversed() {
            guard let id = item.identifier?.rawValue,
                  Self.droppedIdentifiers.contains(id) else { continue }
            menu.removeItem(item)
        }
        tidySeparators(menu)
    }

    /// 收拾裁完留下的分隔符：行首的、行尾的、连着的，只留一条。
    /// 尾部的删得放心——AppKit 往后面塞 Services 时会自带一条分隔符（实拍确认）。
    private func tidySeparators(_ menu: NSMenu) {
        var previousWasSeparator = true  // 从 true 起步 = 顺手吃掉行首的分隔符
        for item in menu.items {
            guard item.isSeparatorItem else { previousWasSeparator = false; continue }
            if previousWasSeparator { menu.removeItem(item) }
            previousWasSeparator = true
        }
        while let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(last)
        }
    }
}
