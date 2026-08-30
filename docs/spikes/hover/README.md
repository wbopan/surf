# 按钮 hover / 按下实测台（可复跑）

问「macOS 27 的按钮悬停和按下到底改了什么」时用的一套。结论写在
`surf-nativeify/README.md` 的「hover / 按下：整片着色」一节，这里只留复跑步骤。

```bash
swiftc -O HoverProbe.swift -o HoverProbe   # 4 行 × 2 列的按钮阵
swiftc -O warp.swift    -o warp            # 挪游标 + 补一记 mouseMoved
swiftc -O mean.swift    -o mean            # 按内容点取样（靠品红标记定位原点）
swiftc -O meanabs.swift -o meanabs         # 按绝对像素取样（给真 App 截图用）
swiftc -O diffmap.swift -o diffmap         # 两图逐块比，找差异在哪
swiftc -O winrect.swift -o winrect         # 取某 App 窗口的屏幕矩形

./run.sh      # 逐行悬停右列 → idle.png / hover_0..3.png
./press.sh    # 逐行按住右列 → press_0..3.png
```

## 四条踩过的坑

1. **一个游标只能悬停一枚按钮**，所以布局是「每行两枚一模一样的」：左列同图未被
   碰过 = 基准。同图差分不受窗口挪动、色彩管理、激活态漂移影响，比跨截图比稳得多。
2. **必须截激活态。** 失活窗口里玻璃退成平灰、带色按钮丢 tint，拿它当基准量出来的
   一切都是错的（第一版 `press_0` 就是这么废掉的）。`press.sh` 因此等探针 stdout
   打出 `PRESSED` 再截图 —— 那一行是在 `NSApp.isActive && isKeyWindow` 持续 1s 后
   才发的。
3. **窗口内换目标要先把游标甩出窗口再进来。** 窗口级的 enter/exit 由窗口服务器生成，
   可靠；窗口内部从一枚按钮直接跳到另一枚，AppKit 不一定收得到移动事件 ——
   第一版四张 hover 图有三张一模一样就是这个原因。
4. **负结论要有回执。** 每个格子左上角挂了一枚 `.onHover` 指示灯（悬停转绿）。
   「蓝键悬停零变化」这种结论没有它就分不清是按钮真没效果还是游标压根没到位。

## 别在用户面前跑

`--hold` 会反复抢前台焦点，`warp` / `press.sh` 会动真游标。**这两样都是在动用户的
输入设备**，只在没人用这台机器的时候跑。

`shot.sh --scale N` 给的是 N 像素/点，但画布可能比内容宽（右侧留白）——量之前先
`sips -g pixelWidth` 对一下，别把留白当内容。

真实 App 上验证 hover 时还有一层：**`CGEvent.post` 需要辅助功能权限**，没有就静默
失败（游标动了、网页收不到 `:hover`）。而且 dsh 的 client 半边 HMR 有时不触发，
改完 `lib/client.js` 要在壳里 ⌘R 才生效 —— 排查「改了没效果」先分清是这两条里的哪条：
把某个值临时改成刺眼的纯色，一张截图就能判定 CSS 是不是活的。
