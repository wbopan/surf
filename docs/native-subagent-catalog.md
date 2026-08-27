# 子代理 catalog 原生化：目标追踪

> 起因：`dash-header` 在数据面就绪时以 `scope: "full"` 折叠整条 web header，
> 连带折掉了 `conversation.session.header.lineage` 槽。而
> **子代理会话不进侧边栏**（`dsh-client-ui-subagent/README.md` 原话：
> "Subagent-origin Session rows are omitted from the ordinary sidebar, so the
> parent header catalog is their navigation entry point"），
> 于是当前形态下**没有任何入口能进入子代理会话**。这是功能倒退，必须补齐。
>
> 决策（用户）：**原生重画整棵 catalog 树**，不退回 web 面包屑。
> 验收标准：端到端可用，**交互丝滑**（hover 打开、键盘导航、懒加载、
> running 时长每秒走）。

## 状态板

| # | 目标 | 状态 |
|---|---|---|
| S0 | 摸清 dsh 侧契约：数据从哪拿、动作怎么发 | ✅ |
| S1 | 数据面：node 半边投影 subagent 树 | ✅ |
| S2 | 视图：原生 catalog popover + 树 | ✅ |
| S3 | 交互：hover 150ms / 键盘导航 / ~~懒加载~~ | ✅ 代码就位，hover 与键盘未实测（见 §验证） |
| S4 | 面包屑形态：计数下拉 + 兄弟切换器 | ✅ |
| S5 | 端到端验证 | ✅ 全链路跑通 |

> **懒加载划掉是有意的**：node 半边一次 `session.list` 就有全树，不存在
> "展开一层拉一次"这回事。见 S0 结论。

## 必须对齐的上游行为（`dsh-client-ui-subagent/README.md` 摘要）

**面包屑两态**
- 普通会话：保留标题；**有后代时**追加 `/` + 后代计数下拉。
- 子代理会话：每段标题 + **固定双 chevron** 组合控件；当前段 primary/weight 500，
  祖先 tertiary/weight 400；**只有当前 subagent** 追加自己的后代计数下拉。
- 计数覆盖"完整的 subagent-only 后代链"，**遇普通 fork 即止**；
  任一被计数的后代在 running 时，触发器显示活动指示。
- 长标题截断，chevron 保持可见。

**打开方式**
- hover 组合控件 150ms → 打开其**直接父**的 catalog。
- ArrowDown 是键盘入口。
- 点祖先 = 取消待开菜单并向上导航，**不开菜单**。

**catalog 树**
- 直接 catalog 权威；每行：mode + `running`/`inactive` + 可选 log-backed 标题。
- 尾列上下两行：durable provider usage 总量（四个不相交 `tokenUsage` 桶求和）/ 活动时长。
- 时长：< 1 天精确到秒；再往上最多两个相邻单位（天/时、约月/日、约年/月）；
  hover 与可访问名保留精确值。
- 时长 = 已完成 `subagentTiming` 轮次之和；**仅当 running 子项有未闭合轮次时**每秒推进；
  子项转 inactive 后冻结；被打断的未闭合轮次以同切 `active.through` 为界。
- 每个 catalog 支持兄弟切换并加粗选中行；catalog label 覆盖 session-summary 标题；
  未加载的切换器自动请求。
- 未命名 one-shot 行回落到 session id；损坏/不支持/不可用的行**保持可读但禁用**。
- `hasChildren` 决定交互前是否显示展开箭头；某一层**全是叶子**时不保留展开列。
- 展开分支立刻按已知直接后代数铺同样多的 disabled loading 行，再懒替换。
- 每个可见分支上报给 runtime，使成员变更帧只在被消费处触发去抖刷新。
- 选中任意深度 → `openSubagent({parentSessionId, childSessionId, mode})`。
- 键盘：→/← 展开收起，↑/↓/Home/End/Esc 导航或关闭；关闭时焦点回触发器。

## S0 调研结论

### 数据面：全树在 node 半边一次拿到

`session.list` 的契约原话是 **"v1 returns everything"**
（`dsh-host-apiproxy/lib/types/api/sessions.d.ts`）——它返回**全部**会话，
子代理行也在里面（`origin: "subagent"` + `parentSessionId`），每行带
`projections.values`：

| projection 键 | 来自 | 用途 |
|---|---|---|
| `title` | `dsh-session-title` | 行标题 |
| `subagent` | `dsh-subagent` | `{mode: "one-shot"\|"continuable", label?}` |
| `subagentTiming` | `dsh-subagent` | `{settledMs, active?: {since, through}}` |
| `tokenUsage` | `dsh-token-meter` | 四个不相交桶 |

**因此不需要上游那套懒加载。** 上游 client 只拿得到*直接* catalog
（`subagents.list` 一次一层），所以必须逐层拉、必须铺 loading 行。
node 半边没有这个限制：一次 `session.list` 就够整棵树，
**展开是纯本地操作、零往返** —— 这正是"丝滑"的来源。

`subagents.list({parentSessionId})` 仍有不可替代的一小块：`kind: "diagnostic"`
行（`corrupt` / `unsupported` / `unavailable`）与 `parentAvailable`。
坏掉的会话未必出现在 `session.list` 里。**处置**：先用 session.list 建树
（即时可见），打开 catalog 时后台补一次 `subagents.list` 校正——
不让它挡在首帧前面。

### 动作面：导航必须走 client 半边

`ctx.sessions.openSubagent({parentSessionId, childSessionId, mode})`
是 **client runtime 的服务**，node 侧没有对应物（路由状态住在浏览器进程里）。
ui-subagent 的注册处原文：

```js
const sessions = ctx.sessions;
const catalogActions = (_parentSessionId) => ({
  openChild(address) { sessions.openSubagent(address); },
  refresh(parentSessionId) { sessions.refreshSubagents(parentSessionId); },
  setCatalogOpen(parentSessionId, open) { sessions.setSubagentCatalogOpen(parentSessionId, open); },
});
```

所以 dash-header 的 client 半边加一条 `window.__dashHeader.openSubagent(...)`，
内部 `ctx.inject(["sessions"], ...)`。**与既有的两通道判据一致**：
树数据的真相在 dsh（node 半边），导航的真相在浏览器（页内桥）。

### 四个纯算法（照抄上游，不自创）

```js
// 四个不相交桶求和
tokenTotal = u => u.uncachedInputTokens + u.outputTokens + u.cacheReadTokens + u.cacheWriteTokens

// 活动时长：running 才推进到 now，否则冻结在 active.through
activityDuration = (timing, activity, now) =>
  timing.active === undefined ? timing.settledMs
    : timing.settledMs + Math.max(0, (activity === "running" ? now : timing.active.through) - timing.active.since)

// 后代计数：沿 parentId 上溯，遇非 subagent 即止；每个后代给沿途每个祖先各记一笔
indexSubagentDescendants(summaries) -> Map<id, {count, runningCount}>

// 时长格式：<1天精确到秒；再往上最多两个相邻单位
formatDuration: days>=365 → 年[+月] | days>=30 → 月[+日] | days>0 → 日[+时]
              | 时>0 → h:mm:ss | 分>0 → m:ss | 否则 s
```

`formatTokens`：`<1000` 原样；`<1e6` → `K`；否则 `M`；≥100 取整，否则一位小数。

### 分工定稿

| 层 | 干什么 |
|---|---|
| `lib/dsh-source.js` | `session.list` → 建树 + 算 descendants，投影 `subagents` 块 |
| `lib/client.js` | 加 `openSubagent(parent, child, mode)`，走 `ctx.sessions` |
| `swift/` | popover 树、hover 150ms、键盘导航、running 时长本地每秒推进 |

**时长不靠重投影推进**：投影给 Swift 的是 `settledMs` / `active.since` /
`active.through` / `running` 四个原始值，Swift 侧本地 timer 自己算。
每秒重投一次整棵树是不可接受的。


---

## 实施记录

### 踩到的三个坑，按代价从大到小

#### 1. id 形态是**混合**的（最贵的一个）

导航一直被拒：

```
sessions.selectSubagent: <id> is not a healthy catalog child
```

两种 id 形态都试过、都被拒，于是一度怀疑是这两个子代理本身坏了
（它们确实因为 DeepSeek API key 401 跑挂了）。**不是。** 拿活服务问了一次
`subagents.list` 才看清：

```
parentSessionId="session-08bc0cb8-…" → parentAvailable=true／2 条
    9aa7efb5-…(continuable)  dd23d54e-…(continuable)
parentSessionId="08bc0cb8-…"         → parentAvailable=false／0 条
```

**同一个 RPC 两端形态不同**：parent 要带 `session-` 前缀，它回的 child 是光
uuid。而当时的候选生成是"两个 id 同步翻转"，四种组合里恰好把唯一正确的那种
（parent 带前缀 + child 光的）跳了过去——**症状是"两种都试了，两种都失败"，
看起来像数据坏了，其实是候选集有洞。**

处置：node 半边投影里直接带上 `rawId`（`session.list` 行里的原始
`sessionId`），不再靠猜；`idCandidates` 同时改成笛卡尔积兜底。

#### 2. `openSubagent` 不是纯导航，它有前置状态

它校验目标是不是 "healthy catalog child"，认的是 client runtime 自己那份
`subagentsByParent`。**没让 runtime 拉过 `subagents.list` 就导航，一律被挡。**

所以上游 `setCatalogOpen` 的真正作用不止是"上报可见分支做去抖刷新"
（README 是这么写的），它还是**导航的前提**。原生 catalog 一打开就调
`primeCatalog`，用户从 hover 到点击那几百毫秒正好够那趟 RPC 回来；
`refreshSubagents` 返回 Promise，await 它才是可靠的"加载完了"信号——
盲等固定毫秒数不行。

#### 3. `ctx.inject` 会抛，裸调一次赔掉整个插件

client 半边加 `ctx.inject(["sessions"], …)` 时放在 `apply` 顶层且没包 try。
它抛了，于是**整个 apply 挂掉**，页面上连 `window.__dashHeader` 都没有。
症状是原生这边每一次页面调用都回执 `no-bridge`，而折叠、段控看着还"正常"
（那是上一次页面加载留下的）。

dash-layout 的 `installBridge` 早就是对的写法，三条都要照抄：
**走作用域 inject / 包 try / 装在 effect 内部（每代重装接线）**。

### 另一个自己制造的坑：切片替换吃掉了函数

用"从 A 找到 B、整段换掉"的方式改 `client.js` 时，把夹在中间的
`confirmNative` 定义一起吃了。语法检查照过（它仍被 `window.__dashHeader`
引用，只是没定义），**只有页面会报**：

```
Failed to load plugins @wenbo/dash-header
failed to apply loader entry …: Can't find variable: confirmNative
```

这与 CLAUDE.md 里 `__ModuleLoader__.load({id})` 那条坑是同一类：
**client 半边的错只在浏览器里报，node 终端一个字都没有。** 改完
`client.js` 一定要真开一次窗口看看。

### 验证

在一个真实的父会话（`session-08bc0cb8-…`，两个 continuable 子代理）上走通了
全链路：

| 步骤 | 结果 |
|---|---|
| 面包屑末段出现计数触发器 `/ ⋈ 2` | ✅ |
| 点开 → catalog 列出两行，mode / 活动 / 时长齐 | ✅ |
| 点一行 → 真的进入子代理会话 | ✅ 正文换成该子代理的 transcript |
| 进入后面包屑变两段，第二段是**兄弟切换器**（双 chevron） | ✅ |
| 点切换器 → 列出直接父的 catalog（两个兄弟都在） | ✅ |
| 点另一个兄弟 → 跳过去 | ✅ 正文从"伦敦今天"变成"伦敦明天" |
| 侧边栏全程无选中项 | ✅ 正是上游说的"子代理不进侧边栏" |

**没实测的两项**：hover 150ms 打开、键盘导航。两者都要抢占物理光标或键盘
焦点（`peekaboo move` / `press` 需要 `--foreground`），会打断正在用这台机器
的人。代码路径与已验证的点击共用同一套状态机
（`hoverCatalog` / `toggleCatalog` → `openCatalogParent`），但**没有跑过就是
没有跑过**，记在这里。

### 顺带修掉的三个视觉问题

- **popover 背景透光**：NSPopover 在 macOS 26 上默认 vibrant 材质，背后的
  Markdown 正文清晰可读。补 `Color(nsColor: .windowBackgroundColor)`。
- **token 显示 `0`**：`tokenUsage` 投影在场但四个桶全零（子代理还没发过请求）
  时会算出 0。视觉与可访问名都改成 `> 0` 才显示。
- **副标题过长**：日志投影出来的标题是一整句话，截到 24 字。
