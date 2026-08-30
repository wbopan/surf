# 历史档案

**只读，别据此判断现状。**

这些是当时的计划文档，正文保持历史原貌——里面的进度、路径、命名都可能已经过时。
留着它们不是为了查现状，是为了回答「这个设计当初为什么这么定」。
现状请读 [`../internals/`](../internals/)，契约请读 [`../extend/contracts.md`](../extend/contracts.md)。

读之前先知道两件事：

- **`phase2-clam-plugin-migration-plan.md` 整篇用的是更名前的旧名**：项目叫 `dash`
  （更早 `DSHarness`），插件 `dash-*`，Swift 类型 `Dash*`。映射就是分别换成
  surfclam / `clam-*` / `Clam*`。
- 档案里出现的 **`clam-header` 插件已经删除**。原生 header 那条路出局了，赢的是
  「把 dsh 的 web header 留在浏览器里、用 CSS 调成 macOS 27 工具栏形态」。

每篇一句话的说明在 [`../README.md`](../README.md) 的 archive 一节。

## 一份档案里什么还活着

不是所有内容都随进度作废。这几处的常青价值最高，做相关改动前值得翻一下：

| 档案 | 仍然值得读的部分 |
|---|---|
| `clam-settings-plan.md` | §1 三条走不通的路（槽声明是 load-time 的、抢 `root` 槽会报错而不是替换、刮 web 产物不可行）——一张「别重走」的清单 |
| `clam-memory-plan.md` | §1.1 dsh 六条上下文注入通道的对照表（含 KV cache 与抗压缩两栏） |
| `clam-notify-plan.md` | §4 通知身份与生命周期：去重是身份问题不是时间问题 |
| `architecture-coupling-audit.md` | §3.4 对 dsh 内部细节的耦合清单——上游升级时最先断的就是这些 |
| `web-header-native-match-plan.md` | §0 那三条「连占槽自画都不可行」的 dsh 源码证据 |
| `clam-i18n-copy-review.md` | 文案风格的判据样本；AppKit 自己注入的菜单项跟系统语言而不跟 dsh locale，那是系统行为不是漏译 |

档案里的 `文件:行` 引用普遍已经漂了——**读到行号先按符号名搜一次**。
档案正文里还留着少量指向 `docs/release-install-plan.md`、`docs/phase1-native-sidebar-plan.md`、
`docs/native-header-plan.md` 的链接：那三份文档已经删除（正文与现状相反），
链接**有意保留原样**，因为它们是当时那句话的一部分。要找那些内容去 git 历史里翻。
