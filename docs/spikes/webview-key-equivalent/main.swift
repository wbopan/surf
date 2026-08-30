// 隔离验证台：WKWebView 里焦点在可编辑区域时，主菜单的 keyEquivalent 还触不触发？
//
// 跑法：
//   swiftc -o /tmp/keyeq main.swift -framework AppKit -framework WebKit && /tmp/keyeq
//
// 它自己造事件（CGEvent → NSEvent → NSApp.sendEvent），不需要辅助功能权限，
// 也不依赖窗口在不在最前——走的是 NSApplication.sendEvent 这条真路径。

import AppKit
import WebKit

let kVKDelete: CGKeyCode = 51        // ⌫ 退格
let kVKForwardDelete: CGKeyCode = 117
let kVKANSI_A: CGKeyCode = 0

final class ProbeWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let r = super.performKeyEquivalent(with: event)
        NSLog("[probe]   webView.performKeyEquivalent -> \(r)")
        return r
    }
}

struct Case {
    let label: String
    let key: CGKeyCode
    let flags: CGEventFlags
}

final class Delegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var web: ProbeWebView!
    var fired: [String] = []

    let cases: [Case] = [
        Case(label: "⌘⇧⌫", key: kVKDelete, flags: [.maskCommand, .maskShift]),
        Case(label: "⌘⌫", key: kVKDelete, flags: [.maskCommand]),
        Case(label: "⌘⇧⌦", key: kVKForwardDelete, flags: [.maskCommand, .maskShift]),
        Case(label: "⌘⇧A", key: kVKANSI_A, flags: [.maskCommand, .maskShift]),
        Case(label: "裸⌫", key: kVKDelete, flags: []),
    ]

    func applicationDidFinishLaunching(_ note: Notification) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        func add(_ title: String, _ keyEq: String, _ mask: NSEvent.ModifierFlags) {
            let it = appMenu.addItem(withTitle: title, action: #selector(hit(_:)), keyEquivalent: keyEq)
            it.keyEquivalentModifierMask = mask
            it.target = self
        }
        add("M:⌘⇧⌫", "\u{08}", [.command, .shift])
        add("M:⌘⌫", "\u{08}", [.command])
        add("M:⌘⇧⌦", "\u{7F}", [.command, .shift])
        add("M:⌘⇧A", "a", [.command, .shift])
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu

        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 300),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        web = ProbeWebView(frame: .zero)
        web.navigationDelegate = self
        window.contentView = web
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        web.loadHTMLString("""
        <html><body style="font:14px -apple-system">
        <textarea id="t" style="width:90%;height:120px">hello world</textarea>
        <script>
          const t = document.getElementById('t');
          window.jsLog = [];
          t.addEventListener('keydown', e => { window.jsLog.push(e.key + (e.metaKey?'+meta':'') + (e.shiftKey?'+shift':'')); });
          t.focus(); t.setSelectionRange(11, 11);
        </script>
        </body></html>
        """, baseURL: nil)
    }

    @objc func hit(_ sender: NSMenuItem) {
        fired.append(sender.title)
        NSLog("[probe]   ✅ 菜单项 \(sender.title) 触发")
    }

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

    func reset(_ done: @escaping () -> Void) {
        web.evaluateJavaScript("const t=document.getElementById('t'); t.value='hello world'; t.focus(); t.setSelectionRange(11,11); window.jsLog=[]; 'ok'") { _, _ in done() }
    }

    func step(_ i: Int) {
        guard i < cases.count else {
            NSLog("[probe] 汇总：菜单触发过 \(fired)")
            NSApp.terminate(nil)
            return
        }
        let c = cases[i]
        reset {
            let before = self.fired.count
            NSLog("[probe] === \(c.label)（焦点在 textarea，内容 'hello world'）===")
            self.send(c)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.web.evaluateJavaScript("JSON.stringify([document.getElementById('t').value, window.jsLog])") { v, _ in
                    NSLog("[probe]   页面: \(v ?? "?")  菜单: \(self.fired.count > before ? "触发" : "❌ 没触发")")
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
