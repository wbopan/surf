# spikes —— 可复跑的隔离验证台

每个子目录是一台**可复跑的隔离验证台**，用来把一条结论钉死在实测上：把待验的那点
东西从整套系统里拆出来单跑，跑一次就能看见答案，换 Xcode / 换 macOS 之后再跑一次
就知道结论还成不成立。有几台直接把壳里的**原文件**编进来（不抄一份，抄了就会和真
实现漂移）。

产物一律落在各自的 `build/` 或 `/tmp`，已 gitignore。

| 目录 | 钉死的结论 | 怎么跑 |
|---|---|---|
| `apple-visual-effect/` | `-apple-visual-effect` 这类系统材质在**不透明窗口**里还成不成立、采样到什么（Raycast 那套是透明窗口 + 桌面采样，surf 是文档型 App，窗口不透明，所以必须自己测） | `./run.sh`；对照组 `SURF_SPIKE_NO_SYSTEM_APPEARANCE=1 ./run.sh` |
| `backend-spawn/` | 托管后端的进程组与信号：**信号送得到吗**。把壳里那份 `ManagedProcess.swift` 原文件编进来，跑六条断言（自成进程组 / 组内成员 / 体面收尸 / 内层收到 TERM / 无残留 / 壳自己没被波及） | `docs/spikes/backend-spawn/run.sh`（也可 `run.sh 'exec sleep 30'` 换命令） |
| `glass-blur/` | 系统玻璃那层背景模糊到底多大核：**σ ≈ 13pt 的高斯 + 饱和度 ×1.97，且不随控件尺寸缩放**（拿竖直硬边的 10%→90% 宽度反解 σ） | `docs/spikes/glass-blur/run.sh`（`--dark` / `--hold`；量完 `pkill -f GlassBlurProbe.app/Contents/MacOS`） |
| `hover/` | macOS 27 的按钮 **hover / 按下**到底改了什么（结论写在 `surf-nativeify/README.md` 的「hover / 按下：整片着色」一节）。布局是「每行两枚一模一样的」，左列同图未被碰过 = 基准 | `swiftc -O HoverProbe.swift -o HoverProbe`（连同 `warp/mean/meanabs/diffmap/winrect` 几个小工具），再 `./run.sh` 与 `./press.sh` |
| `liquid-glass/` | 偏好设置里的按钮与分段控件为什么"没有 Liquid Glass"：① 它是"浮在内容之上那层"的材质，`Form` 里的表单控件按设计拿不到；② 那块刺眼的蓝不是玻璃没生效，是 `NSSegmentedControl.Role` 的 `.valueSelection`——换 `.tabs`（SwiftUI `.pickerStyle(.tabs)`）蓝色就去得掉 | `docs/spikes/liquid-glass/run.sh` |
| `m2-abi/` | 世代热替换的 ABI 断言清单（dlopen / `-module-alias` 换代 / 上游换代下游未重编的失败形态 / 编译耗时基线）。结论见 `docs/extend/native-abi.md` | `./build.sh` 然后 `./out/spike-host out`（退出码 0 = 全通过） |
| `tinted-glass/` | 系统的**蓝键 / 红键带色玻璃**长什么样（结论写在 `surf-nativeify/README.md` 的「带色玻璃」一节）。必须截激活态——失活窗口里 tint 整个丢掉、退成平灰 | `swiftc -O TintProbe.swift -o TintProbe` 等三件套，`./TintProbe --hold &` + `tools/shot.sh`，再 `./bbox` / `./rgbcol` 取值 |
| `webpolicy/` | WKWebView 的外链、新窗口与下载策略：把壳里那份 `WebPolicy.swift` 原样装到一个空 WKWebView 上，用一页手写 HTML 把四条分支（`target="_blank"` 外链 / 当前 frame 外链 / 非法 scheme / 同源新窗口）全走一遍。**会真的把外链交给系统浏览器**（example.com，无害）——那正是被验证的行为 | `docs/spikes/webpolicy/run.sh`（判定看 stdout 的 `[harness]` 行与壳日志的 `[web]` 行） |
| `webview-key-equivalent/` | WKWebView 会吃掉插件命令的键位：AppKit 先走视图层级的 `performKeyEquivalent`、主菜单排在后面，而 WebKit 在可编辑区域把一批带 ⌘ 的删除类组合当自己的编辑命令吃掉并返回 `true`。`main.swift` = 根因组，`fix.swift` = 影子菜单修法的对照组 | `swiftc -o /tmp/keyeq main.swift -framework AppKit -framework WebKit && /tmp/keyeq`；修复组同法编 `fix.swift` |

各台的完整量法、踩过的坑与逐条数值在各自的 `README.md` 里（`webpolicy/` 没有
README，说明写在 `main.swift` 的顶注）。
