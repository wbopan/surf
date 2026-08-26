# dash-sidebar

原生会话侧边栏。占 dash-layout 的 `sidebar` 槽；dash-layout 不在则整个插件不挂载
（cordis 的 `inject` 会让它安静地等着）。

## 两半各管什么

| | 谁 | 干什么 |
|---|---|---|
| node 半边 | `lib/index.js` + `lib/dsh-source.js` | **数据面**：调 `ctx.apiProxy`、订 cordis 事件，组投影，经桥推 JSON；七个写动作 |
| Swift 半边 | `swift/` | 画列表、发动作、收敛选中状态。**零数据逻辑** |

数据面在 node 而不在 Swift（M10 从 DSHKit 迁过来的理由）：壳与共享 module 随 app
bundle 冻结、用户改不了，而会话/工作区的 wire 模型是随 dsh 版本演进最快的那一层
——层放错了。node 半边住在 dsh 进程里、随 npm 可更新，且 Swift 插件怎么热替换它
都不动。附带好处：Swift 那边不再需要一份 HTTP/WS 客户端，`DSHKit` 整个退役。

桥协议（三条下行频道、七个上行动作）的完整表在 `lib/index.js` 顶部注释里。

**跟 dsh 打交道的代码全部关在 `lib/dsh-source.js` 一个文件里，dsh 升级后先核对它。**
它走的是 `ctx.apiProxy`——`/api` 那套方法的同进程实现本体（HTTP carrier 只是包了
它一层），所以行为与 web UI 逐字节同源，零网络、零重复实现。计划 §1.6 猜的
`ctx.sessions` / `ctx.workspaceRegistry` 那条路要自己重写一大段上游逻辑
（`ctx.sessions.list()` 只有活会话、title/running/blank/updatedAt 全是派生的、
registry 上根本没有 rename……），四条实测理由写在那个文件顶部。

## 跨代不闪列表

Swift 半边每代把收到的最后一份 snapshot 原样存进保管箱：

```swift
host.objects.setObject("dash.sidebar.snapshot", payload as NSDictionary)
```

下一代 activate 时先拿它渲染，同时发 `snapshot` 动作要一份 fresh 全量，到了再替换。
**箱里放的是 `NSDictionary`（系统类型），不是本 module 定义的任何 struct**——新旧两代
的同名类型互不认识，取出来 `as?` 只会安静地得到 nil（M2 断言 4）。投影的 struct
（`SidebarSnapshot`）每代自己 decode，实例永不过界。

（M6~M9 时箱里放的是 `DSHKit.SessionStore` 实例。那时敢放一个非 SDK 类型，是因为
DSHKit 也是随 bundle 分发的共享 dylib；M10 之后连这个例外都不需要了。）

## 显示层与数据层的分界

投影原样带上 `blank` / `isSubagent`，**过滤在 Swift**（`AppSidebarModel.visible`）：
"列表里显示什么"是 UI 政策。归档相反——那是数据事实，node 半边直接滤掉。
兜底组的标题也一样：数据层给空串 + `workspaceId: null`，「未分组」四个字归显示层。

## 从壳迁进插件时踩到的坑

- **`#if DEBUG` 在插件里永远不成立**：插件由壳在运行时用命令行 swiftc 编译，没有 `-DDEBUG`。
  插件里要判 Dev 只能看壳的 bundle id 后缀（`io.wenbo.dash.dev`）。
- 选中高亮活过热替换靠 `host.store` 存 `selectedSessionId`。它只是"页面把 `currentSession`
  报回来之前先亮哪一行"的装饰状态，丢了不心疼——真相在 dsh 侧。
- **分叉标题的序号递增必须自己复刻**（`lib/fork-title.js`，用例在 `test/`）：上游把它
  放在 client runtime 的 `fork(increaseTitle: true)` 里，服务/wire 层只有
  fork + rename 两步。两个界面分叉出来的会话必须同名。

## 已知缺口

**待回答问题的紫点（`pendingQuestion`）现在推不出来。** `ask_user_question` 在 node 侧
既不发 cordis 事件也不落 session log，唯一的观察位 `userQuestions.registerProvider`
是**独占**的，apiproxy 已经占着——抢过来等于把 web UI 的问答面板掐了。待审批的橙点
不受影响（它有 `approval/asked` / `approval/decided` 两条 log 事件可推导）。
真要补，正路是订 `ctx.apiProxy.events.mux()`（同进程 async iterable，等价于多开一个
浏览器标签页），代价是要在 node 半边养一条帧流。

## 测试

```sh
node --test dash-sidebar/test/*.test.js
```

零依赖、约 2s。给 `--test` 一个目录在 node 26 上会 `MODULE_NOT_FOUND`，写通配符。
