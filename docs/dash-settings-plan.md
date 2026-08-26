# dash-settings 计划：一扇真正的原生设置窗口

> 本文是 dash-settings 的权威计划，独立于 `phase2-dash-plugin-migration-plan.md`。
> 所有上游事实均已对照 harness `0.1.1-rc.2` 实地验证（2026-08-25，含真实 RPC 调用）；
> 执行时如与源码冲突，以源码为准并更新本文。

## 0. 一句话

把 dsh 的设置做成一扇真正的 macOS 设置窗口：**窗框、导航、控件全是 AppKit/SwiftUI**，
数据面由跑在 dsh 进程里的 node 半边**直接消费 host 服务**，桥上只走 JSON 快照与动作。
不加载任何网页。

## 1. 两条走不通/不该走的路（已花代价验证，别重走）

### 1.1 已证伪：接管 `root` 槽，自己声明 `settings.*`

设想：设置页 shadow 掉官方 AppFrame（`root` 是 single 槽，压低 priority 就能赢），
再由我们重新声明 `settings.section` 等槽，让官方各 section 在我们的容器里重新注册——
这样能拿到一个没有 modal、不渲染主界面的干净设置页。

实测两步撞墙，第二步致命：

1. `single slot "root" already has a registration at priority 0 (registered by z5)`
   ——同优先级的第二条注册是**报错**不是替换。加 `priority: -100` 可解。
2. `slot "settings.header" is already declared (by an entry in "sidebar.settings")`
   ——**槽声明是 load-time 的，绑在 entry 的注册上，与这个 entry 是否胜出、是否渲染无关**。
   官方 SettingsRoot 注册在 `sidebar.settings` 上，哪怕整条祖先链都不渲染，
   它 declare 的六个 `settings.*` 依然占着名字。

反过来"抢先声明"也不行：撞车的一方是报错退出，先声明只会让 ui-settings-general
整个插件加载失败，把 General 段一起赔进去。`StoredEntry` 是 render-erased 的
（拿不到组件），`ctx.slots.renderSlot` 运行时只认 `'root'`——"不声明也能渲染别人的槽"
同样不存在。

### 1.2 已否决：原生窗框 + 内嵌 WebView 渲染官方面板

`7ddc245` 实现过并跑通：⌘, 开出原生窗口，左边 `List(.sidebar)`，右边一块 WebView
加载 `?dash-settings=1`，网页半边把官方面板改造成"整页只有设置"并把目录报上来。

否决理由不是它不工作，是**为了 5% 的内容搬进 100% 的运行时**：一整份 React app、
第二条连接、把非设置的部分全部用 CSS 藏掉；还压着两条脆弱假设（hash 化类名的语义后缀、
"面板导航顺序 = ledger 的 order 顺序"）。

**保留的部分**：那一版的窗口、导航列表、世代生命周期、`settingsOwner` 让位机制都是对的，
继续用；换掉的只是内容区。

## 2. 已确立的事实

| 要什么 | 从哪来（host 侧，进程内直接调） | 证据 |
|---|---|---|
| 全部设置 + schema + 三层取值 + revision | `ctx.settings.describe({redactSecrets:true})` | 实调，13 个 ns / 21 KB |
| 写一个字段 | `ctx.settings.mutate(ns, [{op:'set'\|'unset', path, value}], expectedRevision)` | 类型定义 |
| 配置文件路径 | `ctx.settings.prepareDocument()` | README |
| 外部改动 | 进程内事件 `settings/document-updated`、`settings/updated` | README |
| provider 目录（含 settingsNs/settingsPath/declared） | `ctx.llm.listConfigurableProviders()` | README 明说配置界面是它的消费者 |
| 哪些路由活着 | `ctx.llm.listProviders()` | 同上 |
| 哪些 ns 能问端点要模型 | `ctx.llm.listModelDiscoveryNamespaces()` | **wire RPC 没有，只有 host 面有** |
| 问端点要模型 | `ctx.llm.discoverModels(ns, req)` | README |
| 适配器拓扑变化 | 事件 `llm/adapters-updated`（上游要求据此重读而非轮询） | README |
| 凭据配没配 / 设 / 删 | `ctx.get("credentials")` 的 `describe/set/unset` | apiproxy 实现 |

补充结论：

- **用户设置的唯一注册渠道是 `ctx.settings.register`**。源码里注册 ns 的包共 14 个，
  与运行时 describe 的 13 个对得上。`ctx.storage`（workspace 列表、投影缓存）与浏览器
  本地状态都不承载用户设置。**唯一的例外是凭据**，走 credentials 服务，不进设置文档。
- **schema 是个小语言**：全量只有 8 种节点（`const/number/string/object/union/boolean/array/dict`），
  meta 只有 `default/required/min/max/step/role`，role 全集 6 种
  （`slider/datetime/credential-ref/secret/table/ms`）。未知 role 退化成基础控件即可。
- **schema 里没有描述文本**，也没有"这个字段该不该给人看"。复核过 meta 键全集：
  `required / default / role / step / min / max`，仅此六个。这两样信息在结构化渠道里
  根本不存在。

### 2.1 字段挑选与文案：只能从 web 产物里刮

web 那边靠**手写**解决：字段清单是 `new CardForm(scope, [numberField("timeoutMs"),
numberField("maxOutputBytes")])`，文案是平铺对象 `const en = { bashTimeoutMs:
"Command timeout (ms)", bashTimeoutMsHint: "How long one command may run…" }`。
两样都在 `dsh-client-ui-settings-plugins/lib/client.js` 里是明文，能刮
（包的 `exports` 声明了 `./src/*` 但源码没随 npm 发布，只有编译产物）。

**当生成器用，不当运行时依赖**：`tools/scrape-web-copy.mjs` 刮出「字段清单 + en/zh 文案」
生成一份表入库，Swift 读这份表；运行时零依赖上游 client 包。**升级 dsh 后重跑比对 diff**
——这恰好把 §8 那条"上游新增字段我们不知道"的风险变成一个有信号的动作。

顺带一个支持分层方案的发现：**web 的挑选极其保守**。`shell` 有 5 个字段
（`timeoutMs/maxTimeoutMs/maxOutputBytes/maxSpillBytes/graceMs`）只露 2 个，
`agent-loop` 露 1 个，其余字段用户只能手写 YAML。所以"跟随 web 的挑选"不是高标准，
我们的「精选 + 高级折叠」本来就比它全。

## 3. 架构

```
dsh 进程                                     dash 壳进程
┌────────────────────────────┐              ┌──────────────────────────┐
│ dash-settings/lib/index.js │              │ dash-settings/swift/     │
│  ctx.settings ─┐           │   push       │  SettingsBridge          │
│  ctx.llm ──────┼─→ 快照 ───┼─────────────→│   ↓ 快照                 │
│  credentials ──┘           │              │  SettingsModel（领域态） │
│                            │   invoke     │   ↓                      │
│  expose{set,unset,...} ←───┼──────────────┼── SwiftUI 页面           │
└────────────────────────────┘              └──────────────────────────┘
```

**为什么消费点在 node 半边而不是 Swift 直连 HTTP**：`/api/*` 那套 wire 是给远程浏览器
准备的窄面，host 服务面更宽（`listModelDiscoveryNamespaces` 就只在 host 面）。我们本来
就在进程里，没理由从窄的那头进；附带好处是进程内事件直接可订，不必再开一条 SSE，
Swift 侧连 DSHKit 都不需要。

### 桥协议（本插件私有，channel/action 名与 Swift 侧一一对应）

下行 push：

| channel | 载荷 | 何时 |
|---|---|---|
| `settings` | `{writable, hasDocument, namespaces:[describe 的每一项]}` | 首次 + `settings/document-updated` |
| `providers` | `{available, providers:[…], credentials:{ref:{configured,writable}}, discoveryNamespaces:[…]}` | 首次 + `llm/adapters-updated` + `credentials/reference-updated` |
| `ack` | `{id, ok, error?, value?}` | 每个 invoke 的回执 |

上行 invoke（每条都带 `id`，靠 `ack` 配对——桥本身是单向的，请求/响应语义在本插件这一层实现）：
`refresh` / `set` / `unset` / `setCredential` / `unsetCredential` / `documentPath`
（→ 路径回给壳，由 `NSWorkspace` 打开，因为那才认用户的默认编辑器）。

## 4. 必须实现的编辑器语义

这些是从 web 那边读出来的 checklist——它们与具体字段无关，是**任何设置编辑器都得有**的
基础设施，写一次全页面复用。漏掉任何一条都会得到一个会误写用户数据的表单：

1. **三层模型可视化**：schema 默认 ← composition base ← user 层。"已覆盖"的判据是
   **user 层存在这个键**，不是值不等于默认（等于默认的覆盖仍是覆盖）；配一个
   Reset = `unset` 退回继承。
2. **写入后从 host 回读**，不预测结果——"host 的校验器拥有 schema 表达不了的约束"。
3. **失败保留用户输入**并显示原因，不清空重来。
4. **secret 的反直觉语义**：值永不回传，控件永远从空开始，**空输入 = 保留现有 key**
   （不是清除），只显示"已配置/未配置"。
5. **门控**：ns 未被服务（`available`）、文档只读（`writable`）时整页禁用并说明原因。
6. **`expectedRevision` 乐观锁**：拿到 `SETTINGS_CONFLICT` 就重读并告诉用户，不覆盖。

## 5. 三条红线

1. **只用 `mutate` 的单字段 op**。读-改-写整段再 `replace` 会把没见过的字段
   （未来 schema 的、用户手写在 `settings.yaml` 里的）连同**所有被 redact 掉的 secret
   一起抹掉**——上游 README 专门警告过。
2. **secret 不过桥**。`describe` 一律带 `redactSecrets: true`：桥的另一头是另一个进程，
   凭据明文没有任何理由去那边。Swift 只知道"配没配"。
3. **不认识的字段必须原样存活**。我们只写自己认领的路径，绝不重建对象。

## 6. 待拍板的决策

| # | 决策 | 选项 | 倾向 |
|---|---|---|---|
| D1 | 提交模型 | (a) macOS 惯例：开关/下拉即时生效，文本框失焦或 ⏎ 提交　(b) 照搬 web：全页暂存 + Save/Discard | **(a)**。这是做原生的理由之一；代价是每个控件都要自己处理失败回滚 |
| D2 | 导航结构 | (a) 精选页在前 + 按 ns 平铺兜底　(b) 纯 ns 平铺　(c) 纯精选 | **(a)**。精选保证好用，平铺保证零遗漏——新插件装上自动出现，且比 web 更全 |
| D3 | Models 页第一版 | (a) 只读 + 设/清 API key + 启停已声明的 provider　(b) 连"添加自定义 provider"和模型发现一起做 | **(a)**。深水区单独一轮做对，别挡住前两页 |
| D4 | key ref 命名 | 跟随 web 的 `deriveKeyRef`（`minimax-cn` → `MINIMAX_CN_API_KEY`） | **跟随**。它是 web v1 的产品决定不是 host 契约，但不一致会导致原生设了 key、web 显示未配置 |
| D5 | 字段文案来源 | (a) 刮 web 产物生成表（见 §2.1）　(b) 全部自己写　(c) 只显示字段名 | **(a) + 自己补**。刮来的文案保证两边说法一致；精选之外的字段没有文案，显示字段名 + schema 约束即可 |

## 7. 里程碑

每个里程碑都要能跑起来看，且失败时降级而不是崩。

- **M1 桥打通**。node 半边接上 `ctx.settings`/`ctx.llm`/credentials 并推快照；Swift 侧
  `SettingsBridge` 收下、`SettingsModel` 存住；窗口开出来，导航按 D2 排好，内容区先只
  显示"这个 ns 有哪些字段"的只读列表。
  *判据*：改一次 `settings.yaml`，窗口内容跟着变（进程内事件链路通）。
- **M2 schema 模型 + 渲染器 + 通用页**。schemastery envelope（uid+refs 图）解码成 Swift 树；
  8 种节点 → 控件；第 4 节的编辑器语义全部实现；「通用」页（agent preset / 权限 / 语言 /
  外观 / Enter 行为，五个 ns 各一个字段）可写。
  *判据*：在原生窗口改外观，web 那边和 `settings.yaml` 同时跟着变；改坏一个值有明确报错且不写入。
- **M3 插件页**。按 ns 平铺，每个 ns 一张表单：精选字段在上，其余进「高级」折叠。
  *判据*：`shell` / `agent-loop` / `web-search-*` 都能改；新装一个带 ns 的插件后自动出现一页。
- **M4 模型页**（范围见 D3）。provider 列表 join 凭据状态；设/清 API key；启停。
  *判据*：原生设的 key，web 的 Models 页显示"已配置"。
- **M5 收尾**。`tools/scrape-web-copy.mjs` 与它生成的表入库并写清重跑时机；
  README、CLAUDE.md 目录表、`docs/` 归档；决定 `DashSDK/DashWebKit.swift`
  的去留（M1.2 那版留下的，现在没人用——留着是给未来要 WebView 的插件，删掉是不留死代码，
  倾向删，需要时从 git 里捞）。

## 8. 风险

- **schema 表达不了的交互语义**：某个字段"只在另一个字段为真时生效"、"要点一下发现才有候选值"。
  这类字段落进「高级」后会显示成一个能改但可能改了没效果的输入框。影响边缘字段，
  无解但可接受；「打开配置文件」是最终逃生舱。
- **`deriveKeyRef` 漂移**：上游改了命名约定我们不会收到通知。写在一处、注明来源。
- **host 服务改名/改签名**：`inject: ["settings"]` 是硬依赖，服务不在插件就不挂载
  ——设置窗口整个缺席，⌘, 回落到 dash-layout 的页内 modal（`settingsOwner` 没被占住）。
  这个降级路径是设计好的，不是意外。
- **上游把某个设置搬出 `ctx.settings`**：目前唯一先例是凭据。真发生了，`describe` 里
  会少一个 ns，「打开配置文件」仍在。

## 9. 当前状态（执行前先读）

分支 `feat/dash-settings`，工作树处于**半拆状态**：

- 已提交：`cb1654c`（网页半边，M1.2 的一部分）、`7ddc245`（原生窗口 + WebView 版）。
- 未提交的改动：删掉了 `lib/client.js`；`package.json` 去掉 client 半边、加了
  `@deepseek-ai/dsh-settings` peerDep；`lib/index.js` 已按第 3 节改写成 host 服务版
  （**没跑过**）；`swift/` 三个文件已删空。
- 插件仍注册在 profile 的 bundles 里，dsh 重启会去登记一个空的 `swift/` 目录——
  M1 第一件事就是补上 Swift 半边，或者临时把插件从 profile 摘掉。
- `dash-nativeify` 的两处改动（按压亮光）是另一条线的工作，**别卷进本计划的提交**。
