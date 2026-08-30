# WKWebView 会吃掉插件命令的键位

**症状**：clam-sidebar 声明的 ⌘⇧⌫「归档会话」，焦点在 dsh 的输入框（composer）里时
**按下去什么都不发生**；点开菜单，那一项好好地画着 `⌘⇧⌫` 键符，鼠标点它照常归档。
焦点不在输入框时按键也照常生效。

**根因**（`main.swift` 实测）：AppKit 派发带修饰键的 keyDown 时，
**先走视图层级的 `performKeyEquivalent`，主菜单排在它后面**。而 WKWebView 在可编辑
区域有焦点时，把一批带 ⌘ 的删除类组合当成自己的编辑命令**吃掉并返回 `true`**
——菜单于是根本没被问到。

**修法**（`fix.swift` 实测）：`ClamWebView` 覆写 `performKeyEquivalent`，先拿一份
**只装插件贡献命令的影子菜单**匹配，命中就当场触发、不给 WebKit。
落在 `clam-app/host/Sources/Native/ClamWebView.swift` +
`MainWindowController.commandKeyEquivalentMenu`。

## 跑法

```sh
swiftc -o /tmp/keyeq    main.swift -framework AppKit -framework WebKit && /tmp/keyeq
swiftc -o /tmp/keyeqfix fix.swift  -framework AppKit -framework WebKit && /tmp/keyeqfix
```

两个都是自驱的：起一扇窗、装一个 `<textarea>` 并聚焦、用
`CGEvent(keyboardEventSource:virtualKey:keyDown:)` 造**真实键码**事件走
`NSApp.sendEvent`，然后回读 textarea 的内容与页面收到的 keydown 列表。
跑完自己退出，全部结论打进 `NSLog`。

**必须用真实键码事件**：手拼 `NSEvent.keyEvent(...)` 会绕过 AppKit 菜单匹配那层
归一化（⌫ 的 `0x08 ↔ 0x7F`），据它得出的结论是反的——CLAUDE.md 里记着这一笔。

## `main.swift`：根因（未修）

焦点在 textarea 里，逐个发键：

| 组合 | `webView.performKeyEquivalent` | 菜单 | 页面 |
|---|---|---|---|
| ⌘⇧⌫ | **`true`（被吃）** | ❌ 没触发 | 删到行首 |
| ⌘⌫ | **`true`（被吃）** | ❌ 没触发 | 删到行首 |
| ⌘⇧⌦ | `false` | ✅ 触发 | 不变 |
| ⌘⇧A | `false` | ✅ 触发 | 不变 |
| 裸 ⌫ | （不走 keyEq） | ❌ 没触发 | 删一个字 |

**别把结论推广成"WebView 里 ⌘ 组合都到不了菜单"**：同一次运行里 ⌘⇧⌦ 与 ⌘⇧A
都照常触发。被吃掉的**只有 WebKit 自己认领的那几个编辑组合**。
所以修法也只抢插件声明过的那些键，认不出的一律原样交给 WebKit——
失效方向是"网页照常"，不是"网页哑了"。

顺带一条：`textarea` 已 blur 之后再发 ⌘⇧⌫，`performKeyEquivalent` 第一次仍返回
`true`、第二次才 `false` 并触发菜单。**"能不能触发"取决于可编辑区域有没有焦点**，
这正是用户看到的"有时好使"。

## `fix.swift`：修法 + 两件顺带实测的事

装上影子菜单之后：

| 组合 | 菜单 | 页面 |
|---|---|---|
| ⌘⇧⌫（影子菜单里有） | ✅ 触发 | 内容不变、**连 keydown 都没收到** |
| ⌘⌫（影子菜单里没有） | ❌ 没触发 | 照常删到行首 |
| 裸 ⌫ | ❌ 没触发 | 照常删一个字 |
| ⌘⇧A（影子菜单里有） | ✅ 触发 | 内容不变 |

1. **`NSMenuItem.copy()` 把 `target` / `action` / `representedObject` /
   `keyEquivalentModifierMask` 一并带过来**（文档只说 "copy of the receiver"，
   没有逐字段清单，所以这里逐字段打印确认）。壳因此可以**从主菜单克隆**出影子表
   而不是另建一份——另建就是第二处真相，键位一改就漂移。
2. **匹配那件事一定要交给 `NSMenu` 自己做**：⌫ 的 `0x08 ↔ 0x7F` 归一化、大写字母
   隐含 ⇧ 这些规矩只有 AppKit 知道，手写一遍必然对不齐。影子表存在的意义就是
   "借 `NSMenu.performKeyEquivalent` 的匹配器"，不是自己写一个。
3. 判据是 `representedObject is MenuCommandBox`（spike 里是 `Box`）：
   没挂它的那些（Quit、壳本地的 ⌘R/⌘±/⌥⌘D/⌘/）一条都不克隆，实测被正确滤掉。
