import AppKit
import Foundation

/// 壳菜单快捷键的执行端。壳的菜单只 emit `menuCommand`（词汇表在壳的
/// `MainWindowController.setupMenus()` 注释里），会话导航 / 归档 / 重命名 /
/// 聚焦搜索的**能力**都在 sidebar 这边——投影顺序、选中态、筛选状态恰好也全在这边。
///
/// 生命周期锚：本对象被 `menuCommand` 订阅闭包强持有，订阅由 `ClamPluginHandle`
/// 按住；换代时旧订阅撤销、旧实例随之回收（不占槽对象的锚见 CLAUDE.md 踩坑记录）。
///
/// 导航的顺序真相是 `SidebarFilterState.orderedSessions`——和列表画出来的
/// 是同一份世界：⌘1 跳到的必须是屏幕上数出来的第一条。
@MainActor
final class SidebarShortcuts {
    private let model: AppSidebarModel
    private let filter: SidebarFilterState
    private let log: (String) -> Void

    init(model: AppSidebarModel, filter: SidebarFilterState, log: @escaping (String) -> Void) {
        self.model = model
        self.filter = filter
        self.log = log
    }

    func handle(command: String, payload: [String: Any]) {
        // 每条命令记一行：快捷键"按了没反应"时，这行是分辨"命令没到"和
        // "到了但目标不存在（beep）"的唯一凭据。用户触发、频率低，不算噪音。
        if command != "openSettings", command != "newSession" {
            log("菜单命令：\(command)")
        }
        switch command {
        case "prevSession": step(-1)
        case "nextSession": step(1)
        case "selectSessionAt":
            if let index = payload["index"] as? Int { select(at: index) }
        case "nextPendingSession": nextPending()
        case "archiveSession": archiveCurrent()
        case "renameSession": renameCurrent()
        case "focusSearch": focusSearch()
        default: break // 别家的命令（newSession/openSettings 归 clam-layout）
        }
    }

    // MARK: - 导航

    private var ordered: [SidebarSession] { filter.orderedSessions(from: model.groups) }

    /// 循环步进（对齐 Codex 桌面版 ⌘⇧[ ] 的环形语义）。
    /// 没有选中、或选中行已被筛掉时，从头（向后）/尾（向前）进入列表。
    private func step(_ delta: Int) {
        let list = ordered
        guard !list.isEmpty else { return NSSound.beep() }
        guard let current = model.selectedSessionId,
              let index = list.firstIndex(where: { $0.id == current }) else {
            model.activate(sessionId: (delta > 0 ? list.first : list.last)!.id)
            return
        }
        model.activate(sessionId: list[(index + delta + list.count) % list.count].id)
    }

    /// ⌘1-9：跳到展示序第 N 条（1 起）。超出范围就 beep——静默无事会被当成没按上。
    private func select(at index: Int) {
        let list = ordered
        guard index >= 1, index <= list.count else { return NSSound.beep() }
        model.activate(sessionId: list[index - 1].id)
    }

    /// ⌘⌥A：从当前选中往后循环找第一个待处理（`needsAttention`）会话。
    /// 判据与「待处理」胶囊同源（待批准/待回答/出错/跑完没看），没有就 beep。
    private func nextPending() {
        let list = ordered
        guard !list.isEmpty else { return NSSound.beep() }
        let start = model.selectedSessionId
            .flatMap { id in list.firstIndex { $0.id == id } } ?? -1
        for offset in 1...list.count {
            let candidate = list[(start + offset + list.count) % list.count]
            if candidate.status.needsAttention {
                model.activate(sessionId: candidate.id)
                return
            }
        }
        NSSound.beep()
    }

    // MARK: - 归档 / 重命名（作用于当前选中会话）

    private func currentSession() -> SidebarSession? {
        guard let id = model.selectedSessionId else { return nil }
        for group in model.groups {
            if let session = group.sessions.first(where: { $0.id == id }) { return session }
        }
        return nil
    }

    /// 不确认，直接归档（用户定的，对齐 web 行菜单）：归档是可逆动作——
    /// 「筛选 › 显示已归档」里随时找得回来，为它弹窗是拿打断换不着的安全。
    private func archiveCurrent() {
        guard let session = currentSession() else { return NSSound.beep() }
        model.archive(sessionId: session.id)
    }

    private func renameCurrent() {
        guard let session = currentSession() else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = "重命名会话"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = session.displayTitle
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        present(alert) { [model] response in
            guard response == .alertFirstButtonReturn else { return }
            let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title != session.title else { return }
            model.renameSession(id: session.id, title: title)
        }
    }

    /// sheet 优先（挂在主窗口上，不冒出游离的模态框）；没窗口可挂就 runModal 兜底。
    private func present(_ alert: NSAlert,
                         completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    // MARK: - 聚焦搜索

    /// ⌥⌘F：让侧边栏搜索框成为第一响应者。按 accessibilityIdentifier 现找而不是
    /// 记引用——SwiftUI 视图每代重建，攥着的引用会指向已卸载的旧实例。
    private func focusSearch() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let field = findSearchField(in: window.contentView) else { return NSSound.beep() }
        window.makeFirstResponder(field)
    }

    private func findSearchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let field = view as? NSSearchField,
           field.accessibilityIdentifier() == "sidebar.search" {
            return field
        }
        for sub in view.subviews {
            if let hit = findSearchField(in: sub) { return hit }
        }
        return nil
    }
}
