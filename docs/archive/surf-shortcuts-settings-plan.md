# 快捷键进设置：`clam-shortcuts` 命名空间

2026-08-28。让壳的快捷键成为用户可改的设置项——登记进 dsh 的设置系统，
原生设置窗口（clam-settings）与 dsh 页内设置对话框**同时**点亮，两边都不用改。

## 立场推导（为什么长这样）

- **dsh 是权威，壳做投影**：键位表存在 dsh 的 settings 里，不是壳的
  UserDefaults / 本地文件。多 worktree、重装 App 都不丢；两套设置界面免费获得。
- **复用三条现成机制，零协议新增**：
  1. ns 注册 = `ctx.inject(["settings"])` + `settings.register`（样板：clam-nativeify）；
  2. client 半边订值 = `ctx.inject(["settingsScope"])` + `bind({namespace})`
     （样板：clam-nativeify client 的字号）；
  3. 页 → 壳投影 = `postToShell({type:"keymap",…})`——页内桥不设白名单，
     壳自动广播成 `clam.page.keymap`，桥协议一个字不加。
- **桥的 app 通道不合适**：`announce` 明确"不为后来者留底"（构建事件语义）。
  键位表是**状态**，而页面的生命周期天然解决补发——壳重启 = WebView 重载 =
  client.js 重跑 = 重新投影，不需要任何 sticky 机制。

## 所有权

| 件 | 住哪 | 为什么 |
|---|---|---|
| ns `clam-shortcuts` 注册（schema + 默认值展示） | clam-app node 半边 | 键位是壳菜单的词汇，clam-app 是壳的 node 半身 |
| 键位表投影 + Esc 键匹配 | clam-layout client 半边 | 页 → 壳的上报通道（ready / currentSession）本来就归它 |
| 键位解析 + 菜单重建 | 壳 `MainWindowController` | 菜单是壳的 |
| 默认值真相 | **壳里那张表**（command → 默认 spec） | ns schema 里的 default 只为让设置界面显示默认值，两处必须一致，改一处同步另一处 |

## 可配置范围

进设置的：`newSession` `prevSession` `nextSession` `nextPendingSession`
`archiveSession` `renameSession` `focusSearch` `openSettings`（字符串键位 spec）、
`sessionDigits`（enum：`cmd` / `cmd+alt` / `off`，⌘1-9 那九个一把抓）、
`stopGenerating`（页面侧 Esc，空 = 关）。

**不进设置的**（macOS 系统惯例，改了只会更难用）：⌘W/⌘Q/⌘H/⌘M、编辑菜单、
⌘R 重载、⌥⌘S 侧边栏、⌘±0 缩放、⌥⌘D 诊断、⌘⇧R 重连、⌘/ 面板。

## 键位 spec 格式

小写、`+` 连接：`cmd+shift+]`、`cmd+alt+a`、`cmd+shift+backspace`、`esc`。
修饰符 `cmd`/`shift`/`alt`(`option`)/`ctrl`；键名支持单字符与
`backspace`/`esc`/`space`/`left`…。**空串 = 禁用**（菜单项还在，没有键）。
解析失败 = 退回默认并在壳日志记一行——配置错误降级，不失能。

## 数据流

```
settings（dsh 权威） → clam-layout client 订 settingsScope("clam-shortcuts")
  → postToShell({type:"keymap", values}) → 壳 EventBus "clam.page.keymap"
  → MainWindowController 解析 + 重建整条主菜单（幂等）
  → ⌘/ 面板免费跟进（它每次现场遍历 NSApp.mainMenu）
Esc 停止不过壳：client 半边自己读 stopGenerating，就地匹配 keydown。
```

首帧顺序：壳先用默认表建菜单 → 页面加载完推第一份 keymap → 重建。
设置改动 applies:"live"，订阅回调再推、再重建。

## 执行日志

- 2026-08-28 计划成文。
- 2026-08-28 JS 半边落地：clam-app 注册 ns（schemastery `z.union([z.const…])`
  枚举 + 中文 `.description()`，均核对过真实源码用法）；clam-layout client
  投影帧 `{type:"keymap", values}`（ready 才推、浅比较去重、settingsScope
  缺席 = 永不推 = 壳用默认表）+ Esc 改为按 `stopGenerating` 匹配
  （空串 = 显式禁用不退默认；解析失败退 "esc"；修饰符逐项相等）。
- 2026-08-28 壳半边落地：`KeymapSpec.swift` 解析器 + `Keymap` 表
  （默认值真相、resolve 失败不传染）+ `clam.page.keymap` 订阅重建菜单
  （只在真变了才重建；解析失败无条件落日志；撞键警告不纠正）。
  补：`Keymap.stopSpec` 穿给 ⌘/ 面板，「页面内」那行跟设置走，不再手写死值。
