// 同一个验证台的「修复对照组」：webView 覆写 performKeyEquivalent，
// 先拿一份**只装插件命令的影子菜单**去匹配，命中就当场触发、不给 WebKit。
//
//   swiftc -o /tmp/keyeqfix fix.swift -framework AppKit -framework WebKit && /tmp/keyeqfix
//
// 要看三件事：
//   ① ⌘⇧⌫ 触发菜单；② textarea 里的字**没被删掉**；③ 裸 ⌫ / ⌘⌫ 照常删字。

import AppKit
import WebKit

let kVKDelete: CGKeyCode = 51
let kVKANSI_A: CGKeyCode = 0

final class ProbeWebView: WKWebView {
    /// 影子菜单匹配器。命中 = 这个键位是插件声明的命令，网页不该看见它。
    var claimKeyEquivalent: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if claimKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

struct Case { let label: String; let key: CGKeyCode; let flags: CGEventFlags }

/// 壳里 `MenuCommandBox` 的替身：挂在 `representedObject` 上，
/// 同时也是"这条菜单项是插件贡献的"的判据。
final class Box: NSObject { let command: String; init(_ c: String) { command = c } }

final class Delegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var web: ProbeWebView!
    var fired: [String] = []
    /// 只装"插件命令"的影子菜单：不进 NSApp.mainMenu，只用来做键位匹配。
    let shadow = NSMenu()

    let cases: [Case] = [
        Case(label: "⌘⇧⌫（影子菜单里有）", key: kVKDelete, flags: [.maskCommand, .maskShift]),
        Case(label: "⌘⌫（影子菜单里没有）", key: kVKDelete, flags: [.maskCommand]),
        Case(label: "裸⌫", key: kVKDelete, flags: []),
        Case(label: "⌘⇧A（影子菜单里有）", key: kVKANSI_A, flags: [.maskCommand, .maskShift]),
    ]

    func applicationDidFinishLaunching(_ note: Notification) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        func add(_ menu: NSMenu, _ title: String, _ keyEq: String, _ mask: NSEvent.ModifierFlags) {
            let it = menu.addItem(withTitle: title, action: #selector(hit(_:)), keyEquivalent: keyEq)
            it.keyEquivalentModifierMask = mask
            it.target = self
            it.representedObject = Box(title)
        }
        add(appMenu, "M:⌘⇧⌫", "\u{08}", [.command, .shift])
        add(appMenu, "M:⌘⇧A", "a", [.command, .shift])
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu

        // 影子菜单**由主菜单克隆而来**（真实实现就是这么干的：一处真相，不会漂移）。
        // 这一段同时在验 `NSMenuItem.copy()` 到底带不带 target / action /
        // representedObject / keyEquivalentModifierMask——带不带全靠实测，
        // 文档只说 "copy of the receiver" 而没有逐字段清单。
        shadow.autoenablesItems = false
        for item in appMenu.items {
            guard item.representedObject is Box, !item.keyEquivalent.isEmpty,
                  let clone = item.copy() as? NSMenuItem else { continue }
            clone.isHidden = false   // 影子菜单永不显示，隐藏项的键位也得照样匹配
            clone.isEnabled = true
            shadow.addItem(clone)
        }
        NSLog("[fix] 影子菜单克隆了 \(shadow.items.count) 条：" + shadow.items.map {
            "\($0.title) target=\($0.target == nil ? "nil" : "有") action=\($0.action.map(NSStringFromSelector) ?? "nil") "
            + "box=\(($0.representedObject as? Box)?.command ?? "nil") mask=\($0.keyEquivalentModifierMask.rawValue)"
        }.joined(separator: " | "))

        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 300),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        web = ProbeWebView(frame: .zero)
        web.claimKeyEquivalent = { [weak self] event in
            self?.shadow.performKeyEquivalent(with: event) ?? false
        }
        web.navigationDelegate = self
        window.contentView = web
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        web.loadHTMLString("""
        <html><body style="font:14px -apple-system">
        <textarea id="t" style="width:90%;height:120px">hello world</textarea>
        <script>
          var t = document.getElementById('t');
          window.jsLog = [];
          t.addEventListener('keydown', function (e) { window.jsLog.push(e.key + (e.metaKey?'+meta':'') + (e.shiftKey?'+shift':'')); });
          t.focus(); t.setSelectionRange(11, 11);
        </script>
        </body></html>
        """, baseURL: nil)
    }

    @objc func hit(_ sender: NSMenuItem) { fired.append(sender.title) }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.step(0) }
    }

    func send(_ c: Case) {
        guard let src = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: c.key, keyDown: true) else { return }
        down.flags = c.flags
        guard let ev = NSEvent(cgEvent: down) else { return }
        NSApp.sendEvent(ev)
    }

    func step(_ i: Int) {
        guard i < cases.count else { NSApp.terminate(nil); return }
        let c = cases[i]
        web.evaluateJavaScript("t.value='hello world'; t.focus(); t.setSelectionRange(11,11); window.jsLog=[]; 'ok'") { _, _ in
            let before = self.fired.count
            self.send(c)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.web.evaluateJavaScript("JSON.stringify([t.value, window.jsLog])") { v, _ in
                    NSLog("[fix] \(c.label)  菜单:\(self.fired.count > before ? "✅触发" : "❌没触发")  页面:\(v ?? "?")")
                    self.step(i + 1)
                }
            }
        }
    }
}

let app = NSApplication.shared
let d = Delegate()
app.delegate = d
app.setActivationPolicy(.regular)
app.run()
