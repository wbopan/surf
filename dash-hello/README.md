# dash-hello

原生插件流水线的**冒烟样例**：最小的 Swift 载荷插件。

它占 `root` 槽，因此与 dash-layout 互斥——**默认不注册进 profile**，
留在仓库里是为了在流水线出问题时有一个已知良品可对照。

```bash
dsh plugin --profile web add link:~/.dsh/profiles/plugins/dash-hello
# 重启 dsh，然后改 swift/HelloPlugin.swift 里任何一行，界面 2~3 秒内自己变
dsh plugin --profile web remove dash-hello    # 用完摘掉
```

它一次性验证了四条通路：SwiftUI 视图跨 dylib 上屏、`@Observable` 驱动重绘、
TS 半身 `push` 下行（每 3s 一个时间戳）、Swift 半身 `invoke` 上行（按钮与装载时各一次）。
