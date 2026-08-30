# CLAUDE.md

给在这个仓库里工作的 agent 的导航。**这里只放"怎么找路"和"什么不能做"**——
架构、契约、分发的正文都在 `docs/`，第三方 API 的实测坑不在仓库里（见文末）。

## 这个仓库是什么

一组 cordis 插件 + 一个极薄的 macOS 壳（**surf**），把 `dsh` 的 Web UI 装进
原生 App。壳的源码、构建、拉起全都收进一个普通插件（`surf-app`），没有特权目录。

```
surf/          伞 bundle：唯一的编排表 cordis.patch.yml + 启动器 bin/surf.js
surf-app/          壳源码为载荷的插件；host/ = Xcode 工程，host-build/ = 构建能力（不随包分发）
surf-bridge/       唯一特权插件：Swift 载荷登记表 + /surf/bridge WS + 盯 swift/ 目录
surf-layout/       占 root 槽：分栏、WebView 排版、sidebar 槽、toolbar 贡献槽
surf-sidebar/      占 sidebar 槽：原生会话侧边栏（数据面在 node 半边，Swift 只管画）
surf-notify/       桌面通知；同时是「有什么在等着你」的唯一真相
surf-settings/     原生设置窗口（自己一扇窗，不占槽）
surf-nativeify/    让 dsh Web UI 摸起来像原生：主力是 client 半边的 CSS
surf-memory/       跨会话持久记忆；纯 node、零 macOS 依赖
tools/             跨包工具（shot.sh 截图、apple-kit/ 官方 UI Kit 数值检索）
docs/              文档，按受众分四层
```

被编排的插件包名都是 `@wenbo/surf-*`（目录名 = 去掉 scope）。
**它们自己都不声明 `dsh.bundle`**——编排权集中在伞包那张表上。

## 怎么跑

```sh
./dev                  # 装好 profile 并前台起 dsh（幂等，随便重复跑）；--port 固定端口
./release              # 装成本机正式形态：只装 App 进 /Applications，不装常驻服务
./release --status     # 后端与 App 各在什么状态

node --test surf-sidebar/test/*.test.js   # 全仓唯一的测试，约 2s
surf-app/host/scripts/dev.sh              # 手动构建壳的捷径（不想等轮询时）
```

无测试套件，改完靠跑起来看。**构建一律 `-derivedDataPath build`**——换个位置的症状是
"BUILD SUCCEEDED 但改动永远不生效"。

## 三个开发循环

| 改什么 | 怎么生效 | 耗时 |
|---|---|---|
| 插件的 `swift/` | 存盘即可，桥轮询发现 → 壳重编 → 热替换 | **1~3s，不重启任何东西** |
| `lib/client.js` | 浏览器侧有 HMR，自动重载；壳里 ⌘R 也行 | 秒级 |
| `lib/*.js`、`package.json`、`cordis.patch.yml` | **必须重启 dsh**（官方在 web bundle 下关了 node 侧 HMR）。菜单项与快捷键的 `commands` 声明也在这一行 | 秒级 |
| 壳源码 `surf-app/host/` | surf-app 盯着它，改了后台重建，窗口右上角提示「重启生效」 | 重建 2s + 重启 |

改 Swift 插件**不需要碰 dsh，也不需要重启 App**。编译失败带文件行号打进 dsh 终端，
旧世代继续在役，界面不变也不崩。

## 铁律

1. **我们只是 dsh 的壳。** 上游没实现的功能不替它补——如实报告缺口，不绕过公开 API
   替它补实现，哪怕技术上做得到。也不另建第二个真相源（主题、语言、会话分组一律
   跟随 dsh 投影）。**不主动制造原生界面与 dsh 网页端的显示偏差**，哪怕我们的版本
   更合理。已知缺口记在 `docs/internals/dsh-upstream-gaps.md`。
2. **权威始终在代码里。** 文档是索引；文档与源码冲突，以源码为准并就地更新文档。
3. **编排只改一处**：`surf/cordis.patch.yml`。别给子包加回 `dsh.bundle`。
4. **不背历史包袱。** 遇到旧路径直接删：不写迁移代码、不写兼容分支、不留"停用但保留"
   的代码、不加没有真实触发场景的兜底。（前提是尚未对外分发；一旦别人机器上跑着旧
   版本，这条要重新确认。当前形态需要的 fails loud 与诊断信息不算包袱，是功能。）
5. **fails loud 优于 warn**：`surf-bridge` 的 `register()` 对 module 名非法 / swiftDir
   不存在 / 重复登记三种情况一律当场抛。新写的校验照这个来。
6. **状态型消息走 `emitSticky`，瞬间型走 `emit`。** 插件必然晚于壳启动，不粘的状态
   订阅者可能永远等不到下一次变化。别再为此配 request 回喊通道。
7. **界面面向最终用户。** 文案短、事实性、贴苹果系统 App 的风格，不写安抚性废话。
   不出现 `./dev`、worktree、profile、hash 这类开发流程词汇（"dsh" 是产品名，可以出现）。
   开发者细节只进 ⌥⌘D 诊断面板与日志。
8. **可逆操作不加确认弹窗**，对齐 dsh web 的既有行为。确认留给真正不可逆的动作。
9. **能用系统原生渲染达到的效果就别手工模拟**（本仓库不上 App Store，私有 API 没有
   合规障碍，探测 + 保留降级路径即可）。但**"搬进原生"不自动等于更好**——整块界面
   是留在 web 里用 CSS 贴近原生、还是拆掉重写成 AppKit 控件树，是另一个问题，
   后者贵得多且不一定赢。借系统的渲染能力 ≠ 搬进系统的控件体系。
10. **视觉拿不准就截图给用户裁决**，别自己硬选。其余可逆的实现决策自主推进。

工作方式：较大的改动先把计划整体写完（`docs/` 下的计划文档，带执行日志节），
再派子代理分头实现。做"贴原生"的视觉工作前先查 `tools/apple-kit/`（Apple 官方
macOS 27 UI Kit 的数值检索），别凭记忆估。

## 看界面 / 驱动界面

```bash
tools/shot.sh                 # 截 surf 窗口，不需要它在前台；--list 看有哪些窗口
peekaboo see --pid <pid> --tree --no-screenshot   # AX 元素树 → elem_N
peekaboo click --pid <pid> --on elem_140
```

AX 树同时穿透原生和 Web 两半（`AXWebArea` 底下是完整的 web 元素树），
所以侧边栏与 dsh Web UI 用同一套 AX 就能驱动。关键元素挂了稳定
`accessibilityIdentifier`，别靠中文文案模糊匹配。

## 去哪读

```
docs/README.md          文档地图，每篇一句话
docs/use/               面向最终使用者：安装、连接、诊断、卸载
docs/extend/            面向二次开发者：插件作者指南、跨插件契约、原生 ABI、
                        dsh wire 协议、WebView 原生感手册
docs/internals/         面向本仓库维护者：架构、编排、分发、连接、上游缺口
docs/archive/           历史计划档案（只读，别据此判断现状——文件名是新的、正文是
                        当时的写法：旧名 clam-*/Clam*（更早 dash/Dash*）都读作
                        surf-*/Surf*，换算表在 docs/README.md 的 archive 那节）
docs/spikes/            可复跑的隔离验证台，把一条结论钉死在实测上
docs/design/            设计稿源（.dc.html 画板）
```

## 这个文件不放什么

**不放踩坑记录，不放第三方 API 的实测细节。** AppKit / SwiftUI / WKWebView /
peekaboo / dsh 内部那类"可以重新试出来"的结论，以及本机环境细节（worktree 怎么错开、
profile 叫什么、日志路径怎么分片、xcodegen 从哪补），都在 Claude 的项目记忆里，
不占用仓库的表达空间。

往这里加内容前先问一句：**这条是给外人的，还是给我自己的？** 给外人的写进 `docs/`
对应那一层；给自己的写进记忆，这里最多留一句指路。
