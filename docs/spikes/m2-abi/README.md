# M2 ABI spike

计划 §6.5 断言清单的可执行证据。结论见 `docs/extend/native-abi.md`。

```bash
./build.sh            # SDK + 两代 alpha + beta + 宿主（顺带打印编译耗时基线）
./out/spike-host out  # 跑全部断言；截图落在 out/*.png，退出码 0 = 全通过
```

宿主会开一个可见窗口（SwiftUI 渲染需要真正上屏），几秒后自动退出。
升级 Xcode / macOS 后建议重跑，确认 ABI 假设仍成立。

- `sdk/ClamSDK.swift` — 壳↔插件的 ABI 词汇最小子集（计划 §4.1）
- `plugins/alpha/` — 主角插件：SwiftUI View + @Observable + WKWebView 借用；
  同一份源码经 `-DGEN2` 编出第二代
- `plugins/beta/` — 下游插件，`import Alpha`（经 `-module-alias` 绑定世代），
  用来撞"上游换代、下游未重编"的失败形态
- `host/main.swift` — 模拟壳：registry + 装载器 + 截图取证 + 断言 runner
