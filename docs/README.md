# surf 文档

按**你是谁**分四层。每层只服务一种读者，越往下越接近实现。

| 你是谁 | 读哪一层 |
|---|---|
| 想用 surf | [`use/`](use/) |
| 想给它写插件 | [`extend/`](extend/) |
| 想改这个仓库本身 | [`internals/`](internals/) |
| 想知道某个决定是怎么来的 | [`archive/`](archive/) |

**权威始终在代码里。** 这些文档是索引与解释；凡文档与源码冲突，以源码为准。

## use/ —— 面向使用者

| 文档 | 讲什么 |
|---|---|
| [`install.md`](use/install.md) | 装 dsh、装 App、第一次打开、后端从哪来、连接偏好、诊断与日志、卸载与升级 |
| [`../release-notes/`](release-notes/) | 每个版本一份发布说明：要求、安装、有什么、已知边界、dmg 的 SHA-256 |

## extend/ —— 面向二次开发者

写插件不必读本仓库源码，从这两篇开始：

| 文档 | 讲什么 |
|---|---|
| [`plugin-author-guide.md`](extend/plugin-author-guide.md) | 三种插件骨架、`package.json` 字段、命名规则、import 规则、接进编排、外部热循环、Swift 五条硬规矩、失败长什么样 |
| [`contracts.md`](extend/contracts.md) | 跨插件字符串契约总表：命令声明、`ToolbarSpec` 与工具栏活通道、替换槽与贡献槽、事件主题、页内桥、保管箱键、hook 名、桥协议、endpoint 发现文件与连接偏好 |

深一层的三份：

| 文档 | 讲什么 |
|---|---|
| [`native-abi.md`](extend/native-abi.md) | 原生插件 ABI 的实测结论：入口符号、编译命令、10 条断言结果、编译耗时基线，以及诚实的未覆盖清单。全部来自实跑，不是推理 |
| [`dsh-wire-protocol.md`](extend/dsh-wire-protocol.md) | dsh Web API 的 wire 协议实测（unary POST 的帧形状、两条只下行 WS、rpcId 回显）。**进程内的插件应该走 `ctx.apiProxy`**；这份只有写远程/外部客户端时才用得上 |
| [`webview-native-feel.md`](extend/webview-native-feel.md) | 让 WebView 套壳 App 摸起来像原生的实战手册——私有材质、架构层交给 AppKit、可复制的 CSS 数值。**外部输入，脱离本仓库也成立** |

## internals/ —— 面向本仓库维护者

| 文档 | 讲什么 |
|---|---|
| [`architecture.md`](internals/architecture.md) | 壳与插件的运行时架构：启动方向、壳的五件事、两种槽、钩子表、事件总线、共享 module、热替换与世代 |
| [`orchestration.md`](internals/orchestration.md) | 这些包怎么被装进 dsh：profile / bundle / plugin 三层、编排表、包解析与布线、三个半边的更新边界 |
| [`distribution.md`](internals/distribution.md) | App 怎么变成可分发实体：bundle 载荷布局、profile 自举、预编译 dylib、签名与公证、dmg 打包 |
| [`connection.md`](internals/connection.md) | 「我此刻连着哪个后端」怎么决定：状态机、定位顺序、连接偏好四档、endpoint 发现、托管后端 |
| [`dsh-upstream-gaps.md`](internals/dsh-upstream-gaps.md) | dsh 缺、而我们**决定不替它补**的能力清单 + 复验脚本。上游补上了就删条目 |

## archive/ —— 历史档案

**只读，别据此判断现状。** 这些是当时的计划文档，正文保持历史原貌，
里面的进度、路径、命名都可能已经过时。留着是因为它们记着「为什么是这样」。

读它们之前先知道三件事：

- **档案的文件名是新的，正文是旧的。** 项目改过两次名，每次都只改文件名、
  不动正文。读到旧名按这张表换算：

  | 正文里写的 | 现在叫 |
  |---|---|
  | `surfclam` / `clam-*` / `Clam*`（2026-08-30 之前） | `surf` / `surf-*` / `Surf*` |
  | `dash` / `dash-*` / `Dash*`（更早，最早叫 `DSHarness`） | 同上 |

  `phase2-surf-plugin-migration-plan.md` 整篇用的是最早那套 `dash` 名字，
  其余档案多数是 `clam` 那套。
- 档案里出现的 `surf-header` 插件**已经删除**（原生 header 方向出局，
  留在 web 里用 CSS 贴近原生的那条路赢了）。
- 档案里凡是提到常驻 LaunchAgent / `SURF_RELEASE` 环境变量的，那两层都已退役
  （2026-08-30），代码里一行都不剩。

| 档案 | 记的是什么 |
|---|---|
| `phase2-surf-plugin-migration-plan.md` | 壳最小化、一切皆插件、启动方向反转的整体迁移 |
| `distribution-plan.md` | App 成为唯一分发单元、profile 退化成一次幂等自举、签名公证与 dmg |
| `surf-connection-plan.md` | 连接状态机、连接页、连接偏好四档、壳托管后端 |
| `architecture-coupling-audit.md` | 一次架构耦合审计（文件:行都钉在旧提交上，读到行号先按符号名搜） |
| `p0-decoupling-plan.md` | 上面那份审计的 P0 档施工单 |
| `surf-settings-plan.md` | 原生设置窗口；§1「三条走不通的路」仍有价值 |
| `surf-notify-plan.md` | 可交互桌面通知；不占槽插件的样板 |
| `surf-memory-plan.md` | 跨会话持久记忆；§1.1 那张 dsh 六条上下文注入通道对照表仍有价值 |
| `surf-shortcuts-settings-plan.md` | 把壳的快捷键做成 dsh 设置项 |
| `surf-i18n-plan.md` / `surf-i18n-copy-review.md` | 原生侧文案双语化与逐条文案审校 |
| `native-feel-upgrade-plan.md` | 对照 `extend/webview-native-feel.md` 做的原生感升级 |
| `web-header-native-match-plan.md` | 只用 CSS 把 web header 调到 macOS 27 工具栏形态 |
| `native-subagent-catalog.md` | 子代理 catalog 原生化；实现已随 header 插件删除，保留是因为它是仓库里唯一记着 dsh 子代理契约的地方 |
| `surf-rename-plan.md` / `surf-rename-anchors.md` | 2026-08-30 那次 surfclam → surf 改名：锚点清单与迁移计划 |
| `sidebar-redesign-plan.md` | 侧边栏重设计（单行 32pt + 顶部新建行）；「按状态」分组随后又调过一次（提交 `a2ccc76`），以源码为准 |
| `release-plan-0.1.0.md` | 2026-09-04 首次公开发布：盘点、决策（MIT / Pages / 下载链接）、六个里程碑与执行日志 |

## spikes/ —— 可复跑的验证台

把一条结论钉死在实测上。每个目录一个问题、一份最小复现、一句结论，
都能重新跑一遍。索引见 [`spikes/README.md`](spikes/README.md)。

## design/ —— 设计稿源

`.dc.html` 画板与生成器。留源是为了可 diff、离线可开、artifact 没了能重建。
见 [`design/README.md`](design/README.md)。
