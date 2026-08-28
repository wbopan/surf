# dash-settings 计划：一扇真正的原生设置窗口

> 本文是 dash-settings 的权威计划，独立于 `phase2-dash-plugin-migration-plan.md`。
> 上游事实对照 harness `0.1.1-rc.2` 实地验证（首轮 2026-08-25 含真实 RPC 调用，
> 2026-08-26 二轮复核 `.d.ts` 与注册处源码，修正了一条错误结论，见 §2）。
> 执行时如与源码冲突，以源码为准并更新本文。

## 0. 一句话

把 dsh 的设置做成一扇真正的 macOS 设置窗口：**窗框、导航、控件全是 AppKit/SwiftUI**，
数据面由跑在 dsh 进程里的 node 半边**直接消费 host 服务**，桥上只走 JSON 快照与动作。
不加载任何网页，不依赖上游任何编译产物。

## 1. 三条走不通 / 不该走的路（已花代价验证，别重走）

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

分支 `feat/dash-settings`（`cb1654c` + `7ddc245`）实现过并跑通：⌘, 开出原生窗口，
左边 `List(.sidebar)`，右边一块 WebView 加载 `?dash-settings=1`，网页半边把官方面板
改造成"整页只有设置"并把目录报上来。

否决理由不是它不工作，是**为了 5% 的内容搬进 100% 的运行时**：一整份 React app、
第二条连接、把非设置的部分全部用 CSS 藏掉；还压着两条脆弱假设（hash 化类名的语义后缀、
"面板导航顺序 = ledger 的 order 顺序"）。

**那个分支已经丢掉**（2026-08-26 决定）。窗框、导航列、世代生命周期、`settingsOwner`
让位这四样设计是对的，按本文重写一遍即可——都是我们自己写的几十行，从死分支上
rebase 过来的代价高于重写。

### 1.3 已否决：刮 web 产物当字段清单与文案的来源

设想过写一个 `scrape-web-copy.mjs`，从 `dsh-client-ui-settings-plugins/lib/client.js`
里刮出「web 露了哪些字段」和「en/zh 文案表」，生成一份表入库。

否决：**把上游的编译产物变成我们的输入**，等于给自己安一根随时会断的线——升级 dsh 后
要重跑、要 diff、要判断 diff 是不是有意义；而它换来的只是"措辞和 web 一致"，
而用户就一个人，措辞一致不值这个价。另外顺带发现 web 的挑选极其保守
（`shell` 有 6 个字段只露 2 个，`agent-loop` 露 1 个），跟随它本来就不是高标准。

**替代方案见 §2.2**：纯 schema 驱动，外加一层我们自己手写的薄注解表。

## 2. 已确立的事实

| 要什么 | 从哪来（host 侧，进程内直接调） | 证据 |
|---|---|---|
| 全部设置 + schema + 三层取值 + revision | `ctx.settings.describe({redactSecrets:true})` | 实调，13 个 ns / 21 KB |
| 写一个字段 | `ctx.settings.mutate(ns, [{op:'set'\|'unset', path, value}], expectedRevision)` | `.d.ts` |
| 配置文件路径 | `ctx.settings.prepareDocument()` | `.d.ts`（非文件型 provider 返回 undefined） |
| 外部改动 | 进程内事件 `settings/document-updated`（ns, revision）、`settings/updated` | `types.d.ts` |
| provider 目录（含 settingsNs/settingsPath/declared） | `ctx.llm.listConfigurableProviders()` | `.d.ts` |
| 哪些路由活着 | `ctx.llm.listProviders()` | `.d.ts` |
| 问端点要模型 | `ctx.llm.discoverModels(ns, req)` | `.d.ts` |
| 适配器拓扑变化 | 事件 `llm/adapters-updated`（上游要求据此重读而非轮询） | `types.d.ts` |
| 凭据配没配 / 设 / 删 | `ctx.get("credentials")` 的 `describe/set/unset` | apiproxy 实现 |

**修正（2026-08-26）**：上一版这张表有一行 `ctx.llm.listModelDiscoveryNamespaces()`
——**这个方法不存在**。`LlmRuntime` 的完整签名在 `dsh-tool-cordis` 里有整份声明，
模型发现只有 `registerModelDiscovery` 与 `discoverModels` 两个，没有任何枚举 API。
所以"哪个 ns 能问端点要模型"只能靠**试**：`discoverModels` 对没注册的 ns 抛
`LlmError(code: "NO_DISCOVERY")`。这只影响 M4，但别到那时候才撞上。

`describe()` 返回的 `SettingsDescriptor` 一次给足四层信息，这是整个方案成立的基础：
`schema`（序列化的 schemastery）、`value`（解析后的值）、`base`（编排层）、
`user`（原始用户段，**某个键在不在这里就是"用户是否覆盖"的判据**）、`revision`
（乐观锁）、`applies`（`live` / `restart`）、`secrets`（redact 掉的位置清单）。

补充结论：

- **用户设置的唯一注册渠道是 `ctx.settings.register`**。源码里注册 ns 的包共 14 个，
  与运行时 describe 的 13 个对得上。`ctx.storage`（workspace 列表、投影缓存）与浏览器
  本地状态都不承载用户设置。**唯一的例外是凭据**，走 credentials 服务，不进设置文档。
- **schema 是个小语言**：全量只有 8 种节点（`const/number/string/object/union/boolean/array/dict`），
  meta 只有 `default/required/min/max/step/role`，role 全集 6 种
  （`slider/datetime/credential-ref/secret/table/ms`）。未知 role 退化成基础控件即可。

### 2.1 schema 里一个字的文案都没有（已实证）

复核了实际注册处，不是推断：`dsh-bash-local` 的 `LocalBashExecutor.Config` 就是

```js
z.object({ cwd: z.string(), timeoutMs: z.number().default(12e4), … })
```

全是裸节点，没有 `.description()`。meta 键全集复核也只有那六个
（`required / default / role / step / min / max`）。所以「这个字段是什么意思」
和「这个字段该不该给人看」这两样信息，**在结构化渠道里根本不存在**。

### 2.2 因此：纯 schema 驱动 + 一层薄注解表

- **默认零注解**。标签 = 字段 key 的机械美化（`maxOutputBytes` → `Max Output Bytes`），
  旁边小字标真 key（用户要对着 `settings.yaml` 手写时需要真名），副标题显示类型、
  默认值与约束。**所有 ns 的所有字段一视同仁地出现**，不做任何隐藏。
- **注解表是可选的薄薄一层**，我们自己手写，住在 `dash-settings/swift/FieldNotes.swift`：
  `ns.path → {中文标题, 一句说明, 是否精选}`。**第一版基本留空**，用起来觉得哪个字段
  值得抬到「通用」页就补一条，写的时候可以参考上游各包的 `README.zh.md`
  （那是文档不是产物，读它不建立任何构建期依赖）。
- 这一条同时把 §8 原来那条风险翻了面：**上游新增字段会自动出现**，只是没有注解——
  以前那条"我们不知道上游加了字段"的风险不存在了。

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
准备的窄面，host 服务面更宽。我们本来就在进程里，没理由从窄的那头进；附带好处是
进程内事件直接可订，不必再开一条 SSE，Swift 侧连 DSHKit 都不需要。

**没有 client 半边。** 顺带白捡一条：不必踩「`__ModuleLoader__.load({id})` 的 id
必须逐字等于包名」那个坑（CLAUDE.md 踩坑记录里那条）。

### 3.1 依赖分层：哪个服务缺席该塌到什么程度

这个 cordis fork 的 `Inject` **只有数组和 intercept-config 两种形态，没有
`{required, optional}`**（见 `cordis/lib/types/registry.d.ts`）。可选依赖的正确写法
是运行时嵌套：`ctx.inject(['llm'], (llmCtx) => …)`。据此分三层：

| 服务 | 声明方式 | 缺席时 |
|---|---|---|
| `dashBridge` | 静态 `inject`（硬） | 插件不挂载 = 没有壳，本来也谈不上设置窗口 |
| `settings` | 静态 `inject`（硬，**有意为之**） | 整个插件缺席 → `settingsOwner` 没被占 → ⌘, 回落 dash-layout 的页内 modal。这是设计好的降级路径 |
| `llm` / `credentials` | 运行时 `ctx.inject([...], cb)` 嵌套 | 只是「模型」那一页不出现，通用页与插件页照常可用 |

上一版计划把 `llm` 也算进硬依赖，那会让"LLM 服务没起来"连带整扇窗口消失——不对。

### 3.2 桥协议（本插件私有，channel/action 名与 Swift 侧一一对应）

下行 push：

| channel | 载荷 | 何时 |
|---|---|---|
| `settings` | `{writable, hasDocument, namespaces:[describe 的每一项]}` | 首次 + `settings/document-updated` |
| `providers` | `{available, providers:[…], credentials:{ref:{configured,writable}}}` | 首次 + `llm/adapters-updated` + `credentials/reference-updated` |
| `ack` | `{id, ok, error?, value?}` | 每个 invoke 的回执 |

上行 invoke（每条都带 `id`，靠 `ack` 配对——桥本身是单向的，请求/响应语义在本插件这一层实现）：
`refresh` / `set` / `unset` / `setCredential` / `unsetCredential` / `documentPath`
（→ 路径回给壳，由 `NSWorkspace` 打开，因为那才认用户的默认编辑器）。

## 4. 必须实现的编辑器语义

这些与具体字段无关，是**任何设置编辑器都得有**的基础设施，写一次全页面复用。
漏掉任何一条都会得到一个会误写用户数据的表单：

1. **三层模型可视化**：schema 默认 ← composition base ← user 层。"已覆盖"的判据是
   **`descriptor.user` 里存在这个键**，不是值不等于默认（等于默认的覆盖仍是覆盖）；
   配一个 Reset = `unset` 退回继承。
2. **写入后从 host 回读**，不预测结果——host 的 `validate` 回调拥有 schema 表达不了的
   跨字段约束（`SettingsRegisterOptions.validate`，`.d.ts` 里明写）。
3. **失败保留用户输入**并显示原因，不清空重来。
4. **secret 的反直觉语义**：值永不回传，控件永远从空开始，**空输入 = 保留现有 key**
   （不是清除），只显示"已配置/未配置"。
5. **门控**：ns 未被服务、文档只读（`provider.writable === false`）时整页禁用并说明原因。
6. **`expectedRevision` 乐观锁**：拿到 `SETTINGS_CONFLICT`（`SettingsConflictError.code`，
   带 `expected`/`actual`）就重读并告诉用户，不覆盖。
7. **`applies: 'restart'` 的 ns 要标出来**，改完提示"重启 dsh 生效"——否则用户会以为没写进去。

## 5. 三条红线

1. **只用 `mutate` 的单字段 op**。上游 `SettingsPathOp` 的文档注释把理由写死了：
   *"a wholesale replace rebuilt from a redacted document silently deletes every secret
   the wire never returned"*。读-改-写整段还会连同未来 schema 的字段、用户手写在
   `settings.yaml` 里的字段一起抹掉。
2. **secret 不过桥**。`describe` 一律带 `redactSecrets: true`：桥的另一头是另一个进程，
   凭据明文没有任何理由去那边。Swift 只知道"配没配"。
3. **不认识的字段必须原样存活**。我们只写自己认领的路径，绝不重建对象。

## 6. 已定的决策

| # | 决策 | 定论 |
|---|---|---|
| D1 | 提交模型 | **即时生效**（macOS 惯例）：开关/下拉一动就写，文本框失焦或 ⏎ 提交。代价是每个控件自己处理失败回滚 + 乐观锁冲突，但 §4 那七条写一次全页复用，摊薄了 |
| D2 | 导航结构 | **精选「通用」页在前 + 按 ns 平铺兜底**。精选保证好用，平铺保证零遗漏——新插件装上自动出现一页 |
| D3 | 模型页第一版 | **列出 + 看状态 + 设/清 API key**。"添加自定义 provider"与模型发现单独一轮 （原写的"启停已声明的 provider"是误解：`LlmRuntime` 里没有启停概念，`live` 是"配置完整到 llm 愿意注册它"的结果，不是可写字段——M4 核签名时改掉） |
| D4 | key ref 命名 | **跟随 web 的 `deriveKeyRef`**（`minimax-cn` → `MINIMAX_CN_API_KEY`）。它是 web v1 的产品决定不是 host 契约，但不一致会导致原生设了 key、web 显示未配置。写在一处、注明来源 |
| D5 | 字段清单与文案 | **纯 schema 驱动 + 薄注解表**，见 §2.2。不刮任何上游产物 |

## 7. 里程碑

每个里程碑都要能跑起来看，且失败时降级而不是崩。

- **M0 接线**。建 `dash-settings/`，包名 `@wenbo/dash-settings`，**不声明 `dsh.bundle`**
  （编排权在伞包）；往 `dash/cordis.patch.yml` 加一行 row，往 `dash/package.json` 的
  dependencies 加一条——`dash/bin/dash.js` 的 link 列表是从 dependencies 推出来的，
  **零代码改动**。同时补 `DashObjects.Key.settingsOwner` 与 dash-layout 的让位分支。
  Swift 半边先只是一扇空窗口。
  *判据*：`./dev` 起得来，⌘, 开出空的原生窗口，**主窗口里不再弹网页 modal**；
  把插件从编排表摘掉后 ⌘, 恢复弹 modal。

- **M1 桥打通**。node 半边接上 `ctx.settings` 并推快照；Swift 侧 `SettingsBridge` 收下、
  `SettingsModel` 存住；内容区先只显示"这个 ns 有哪些字段、当前什么值"的只读列表。
  *判据*：手改一次 `settings.yaml`，窗口内容跟着变（`settings/document-updated` 链路通）。

- **M2 schema 模型 + 渲染器 + ns 平铺页（可写）**。schemastery envelope（uid+refs 图）
  解码成 Swift 树；8 种节点 → 控件；§4 的七条语义全部实现；按 ns 平铺，每个 ns 一张表单，
  **零注解也完整可用**（标签走机械美化）。
  *判据*：在原生窗口改 `shell` 的 `timeoutMs`，web 那边和 `settings.yaml` 同时跟着变；
  改坏一个值有明确报错且不写入；两个窗口同时改同一个 ns 会拿到 `SETTINGS_CONFLICT`
  而不是互相覆盖。

  > 注意里程碑顺序与上一版反了：平铺页零依赖，先做；「通用」页依赖注解表，后做。

- **M3 精选「通用」页 + 注解表开张**。`FieldNotes.swift` 写下第一批条目
  （agent preset / 权限 / 语言 / 外观 / Enter 行为，五个 ns 各一个字段），
  导航按 D2 排：通用在前，ns 平铺在后，精选过的字段在平铺页里也带上中文标题。
  *判据*：通用页五项都能改；注解表里删掉一条，那个字段自动退回机械标签而不是消失。

- **M4 模型页**（范围见 D3）。provider 列表 join 路由状态与凭据状态；设/清 API key。
  *判据*：原生设的 key，web 的 Models 页显示"已配置"；`llm` 服务缺席时只有这一页不见，
  其余照常。

- **M5 收尾**。README、CLAUDE.md 目录表与"五个插件"的措辞（变六个）、`docs/` 归档。

## 8. 风险

- **schema 表达不了的交互语义**：某个字段"只在另一个字段为真时生效"、"要点一下发现才有
  候选值"。这类字段会显示成一个能改但可能改了没效果的输入框。影响边缘字段，
  无解但可接受；「打开配置文件」是最终逃生舱。上游的 `validate` 回调会在写入时挡下
  真正非法的组合（§4.2），所以最坏情况是"改了没反应"，不是"写坏了"。
- **`deriveKeyRef` 漂移**：上游改了命名约定我们不会收到通知。写在一处、注明来源。
- **注解表变陈**：上游改了字段语义，我们手写的中文说明不会自己更新，也没有信号。
  控制手段是把注解表**保持得很小**——只注解真正常用的那几个，其余靠 schema 自解释。
- **上游把某个设置搬出 `ctx.settings`**：目前唯一先例是凭据。真发生了，`describe` 里
  会少一个 ns，「打开配置文件」仍在。
- **非文件型 settings provider**：`prepareDocument()` 可能返回 undefined，
  那时「打开配置文件」这个逃生舱不存在，必须隐藏而不是给一个点了没反应的按钮。

## 9. 当前状态（执行前先读）

**2026-08-26 重整**：

- `feat/dash-settings` 分支（`cb1654c` + `7ddc245`，WebView 版）**已决定丢弃**，
  不 rebase、不 cherry-pick。删远端分支要单独确认（外向操作）。
- 工作树里**没有 `dash-settings/` 目录**，一切从 M0 从零建。
- main 上与本计划相关的现成件：`DashEventBus.Topic.menuCommand` 已在发
  `{"command": "openSettings"}`（`MainWindowController.swift:630`），dash-layout 已经
  在接（`LayoutPlugin.swift:27`）——M0 要做的只是给它加一个"有主就让位"的判断。
- `DashObjects.Key.settingsOwner` **尚不存在**，M0 新增。
- `DashSDK/DashWebKit.swift` 在死分支上，**不带过来**：新方案没有 WebView，
  上一版计划里那个"M5 决定 DashWebKit 去留"的悬案就此自动消解——从不引入。

## 10. 执行日志

### M0 接线 —— 2026-08-26 完成

`dash-settings/` 建起来了（`@wenbo/dash-settings`，无 `dsh.bundle`），伞包表加一行、
伞包 dependencies 加一条，`dash/bin/dash.js` 一行未改；`DashObjects.Key.settingsOwner`
落地，dash-layout 加了让位分支。判据两半都实测过：装上时 ⌘, 开原生窗口且主窗口无 modal，
摘掉后重启 dsh，⌘, 弹出 dsh 自己的设置 modal。

途中修掉两个**沉默失败**，都不在原计划里：

1. **让位的 disposable 不能 `[weak host]`**。壳的 `LoadedPlugin` 同时强持 handle 与
   host，退休是同一次释放，字段析构顺序是实现细节。赌输的后果是 `settingsOwner`
   永远占着——⌘, 从此既不开原生窗口也不弹 modal，不留任何痕迹。改成强持
   （不成环，且 handle 本就与本世代同生共死），并让它写一行日志，
   "让出"这件事从此可观测。

2. **页内 modal 这条逃生舱本来就是死的**（与本计划无关的既有 bug，在 dash-layout）。
   dsh 把设置 modal 渲染在**侧边栏列内部**（`_sidebarCol > … > _settingsArea >
   _overlay > _panel`），不是 portal 到 body；而 dash-layout 的原生侧边栏模式给
   `_sidebarCol` 上了 `visibility: hidden`，于是 modal 点得中、挂载成功、就是看不见，
   且不报任何错。§3.1 那张"缺席时塌到什么程度"的表原本是纸上谈兵——现在给 overlay
   补了一条 `visibility: visible` 例外（它是 `position: fixed`，不受 frame 平移影响），
   逃生舱才真的存在。

   **教训**：写在计划里的降级路径，不实测一次就只是愿望。

### M1 桥与数据面 —— 2026-08-26 完成

node 半边 `describe({redactSecrets:true})` → 有序 JSON 往下推，单字段 op 往上收，
`expectedRevision` 全程带着。Swift 半边解出 schema 树与快照，一行日志自证：
`收到快照：12 个命名空间 / 43 个字段，可写=true 有文档=true`。

三件当初没预料到、但事后看必然的事：

1. **顺序得在 JS 那半保住**。schemastery 的 `object.dict` 是个对象，JS 里键序 =
   声明序 = 界面该有的字段序；到了 Swift 变成 `[String: Any]` 当场丢光，再想恢复
   就只剩字母序。所以摊平成 `fields: [{key, ref}]` 数组必须在 node 半边做。
   **顺序是语义，别指望在无序容器里找回来。**

2. **桥是单向的**：`invoke` 的返回值被 dash-bridge 丢弃（只在抛错时记一行日志）。
   请求/响应只能在本插件这层自己搭——每个 invoke 带 `id`，回执走 `ack` 频道按 id
   配对。Swift 侧还得自带超时：`DashBridge.send` 在桥断开时是**静默丢弃**，
   不给回调也不报错，没有超时的话按钮会一直转。

3. **`SchemaNode` 少一个 `indirect` 就编不过**，而且报错报在**持有它的那个 struct**
   上（"value type 'NamespaceSnapshot' has infinite size"），不在枚举这里。
   已就地写进注释，免得下次照着行号找错地方。

### M2/M3 命名空间页与「通用」页 —— 2026-08-26 完成

纯 schema 驱动 + `FieldNotes` 薄注解表（D5）。七种编辑器语义都落了地，
其中三条是"不这么写就会悄悄坏事"的：

- **滑块只在松手时写**（不是拖动中）：拖一次 = 几十次 mutate + 几十次 revision 递增，
  每一次都在跟自己抢乐观锁。
- **secret 框从空开始，空 = 不变**：快照里 secret 是 redact 过的，把 redact 值当
  初值填进去再原样写回，等于把用户的 key 覆盖成一串星号。
- **写完不预测结果**：宿主 `validate` 有 schema 表达不了的跨字段约束，写成功 ≠
  值就是你给的那个。一律 mutate 完重推快照，界面显示的永远是 host 说的话。

`applies: "restart"` 的 ns 挂了提示条——**不假装即时生效**。

### M4 模型页 —— 2026-08-26 完成

`llm` / `credentials` 走 `ctx.inject([...], cb)` 运行时嵌套：缺了只是这一页不出现，
不连累整扇窗口。两处从实测数据里长出来的决定：

- **`live` 不是开关**，是"配置完整到 llm 愿意注册它"的结果（见上面 D3 的更正）。
- **38 个可配置 provider，在用的 3 个**。平铺 38 张带密码框的卡片是一堵墙，
  于是分三组：在用 / 已有 key 但路由没起来 / 其余（折叠）。
- `credentialConfigured` 是三态（`nil` = 凭据服务不在场），界面显示"凭据状态未知"
  而不是"未配置"——后者会骗用户去重设一个其实已经配好的 key。

### M5 收尾与验证 —— 2026-08-26

写了 `dash-settings/tools/probe.mjs`：当一个"壳"连上 `/dash/bridge`，不开窗口、
不碰屏幕，把数据面从头验一遍。**它是这一轮性价比最高的一件东西**——数据面全跑在
dsh 进程里，跟 SwiftUI 没有半点关系，用截图验它等于让 21KB 的 JSON 通过一张 PNG
汇报自己；而且屏幕锁着时截图与 AX 都用不了，数据面的活儿却一点没耽误。

实测结论：12 个 ns / 43 个字段两侧解码一致；`set` 回读正确；过期 `expectedRevision`
被 `SETTINGS_CONFLICT` 挡下；`unset` 后 user 层干净；38 个 provider 状态正确
（deepseek-official / kimi-coding / zai-coding-cn 三个 live 且已配置）。

探针当场揪出一个真 bug：**`refresh` 只重推了 `settings`**。push 是广播、不补发，
壳换一代 / 窗口重开 / 新客户端连上来都只能靠这一下把状态要回去——于是模型页会一直
停在"llm 不在场"，直到某个 `llm/adapters-updated` 碰巧发生。这个 bug 用眼睛几乎不
可能稳定复现（要在换代之后、下一次 adapters 事件之前去看那一页）。

还欠一次**人眼过目**：截图（SCK）与 AX 树在写这段时都用不了——用户的屏幕锁着，
`tools/shot.sh` 回 `-3811`、`peekaboo` 回 "AX tree incomplete"。
顺带把这条坑记进了 `tools/shot.swift` 的注释（睡眠/锁屏的显示器会让 SCK 列出幽灵
窗口并且截图失败，`caffeinate -u -t 1` 可解）。

### M6 编排对齐 dsh Web —— 2026-08-26 完成

M2～M4 交出来的界面被否了，两条意见：**拥挤而缺乏品味**，以及**没用原生的设置窗框**。
参考设计是 Mimestream。改完之后又追加一条：**内容编排要跟 Web 设置界面尽量一致**。

于是这一轮同时换了两样东西，而且是两件独立的事：

**外壳换成 macOS 偏好设置的形状。** `NSWindow.toolbarStyle = .preference` +
`NSTabViewController(tabStyle: .toolbar)` + 每页一个 `NSHostingController`。
三条实测：

1. **`NSHostingController.sizingOptions` 在这里要保留默认的 `.preferredContentSize`**
   ——CLAUDE.md 那条"槽内插件必须设 `[]`"在这儿正好反过来：槽里是"别让内容顶飞用户
   调好的分栏宽度"，偏好设置窗口本就该跟着内容走。同一个开关，两种场景，结论相反。
2. **`setFrameAutosaveName` 会跟自适应打架**：它把上一次的尺寸恢复回来，于是 600 宽的
   内容被塞进 500 宽的窗，左边整整齐齐裁掉 50pt。摘掉之后窗口才开始每页各自合身。
3. **`SecureField(_ title:text:)` 的第一个参数是标签不是占位符**，在 `Form` 里会渲染成
   控件旁边一坨多余的文字（"Api Key： 未配置 ［框］"）。占位符必须走 `prompt:`。

**编排改成照抄 Web。** 我先自造了一套主题分页（通用/模型/智能体/工具/高级），
被否得对——用户对着 Web 已经形成了肌肉记忆，原生窗口另立一套只会让同一个设置在两个
地方长得不一样。于是打开 dsh Web UI 把四栏逐页读了一遍，手写成 `SettingsTabs` 的映射表。
**这不违反 §1.3 那条"不刮 web 产物"**：读的是跑起来的界面，写下来的是一张手写表，
不建立任何构建期依赖。

对齐后最打脸的一处：`agent-presets` / `permission` / `busyEnter` 在 Web 的 General 页，
而我把它们放进了自造的「智能体」页。**分类是产品决定，不是能从数据推出来的东西**。

两处有意的分歧，都写进了代码注释：Web 是 Discard/Save，这里即时生效（D1 已定）；
Web 每个 ns 只露手挑的几个字段（`shell` 六个只露两个），这里精选照露、其余进
「更多设置」折叠——**零遗漏（§2.2）优先于一致性**，看不见的字段等于不存在。

**顺手挖出一个壳层的真 bug**（不在本计划范围，已记进 CLAUDE.md）：
退休世代的 `DashPluginHandle` 常常不 deinit，四十多次换代只析构过三次。
注册撤销之所以一直没出事，是 registry 的 token 校验兜住了；**没有 token 兜底的窗口
就会积累**——每改一次 Swift 多叠一扇设置窗口。改成把窗口存进 `host.objects`、
新一代 activate 时主动收拾，不再依赖析构。

**验收（M2/M3 的判据，这轮才真正跑通）**：在原生窗口点「深色」→
`~/.dsh/settings.yaml` 的 `ui-theme.preference` 当场变成 `dark` →
浏览器里开着的 dsh Web UI 实时换肤。改完已恢复原值。

### M7 补齐两栏：智能体预设 + 插件列表 —— 2026-08-26 完成

M6 说"编排照抄 Web"，但只抄了看得见的那一半。用户连着指出两处漏抄，两处都是
**我没查就下结论**造成的：

**一、智能体预设整栏漏掉。** 我当时判定"没有数据面"就跳过了——错的。
`agent-presets` 这个 ns 里确实只有 `default` 一个字段，但预设画廊的数据根本不在
settings 里，而在 `ctx.agentPresets`（`@deepseek-ai/dsh-agent-presets` 注册的服务）。
教训：**"settings 里没有" ≠ "宿主没有"**，dsh 的服务面比设置面大得多，
下"做不了"的结论前先 `ls ~/.dsh/profiles/node_modules/@deepseek-ai/`。

顺带在这轮发现 `installPresets(api)` **只 import 了没有调用**——预设频道从来没推过，
那一页即使写好了也永远是空的。node 半边没有 HMR，这种"少一行"不会有任何报错。

**二、插件页只抄了 Plugin configuration，Plugin list 整栏漏掉。**
补上之后与 Web 逐条比对过：171 条、Loader 顺序一致、29 条停用的名单与顺序一致。

关于"能不能启停"——**Web 那边也不能**。`@deepseek-ai/dsh-host-plugin-inventory`
的包描述就是 "Read-only Remote projection"，整个服务只有一个 `list()`；
客户端包的 README 在 Known Limitations 里写死了 "Read-only Loader view … does not
add plugin mutation controls"。那个「已启用/已停用」标签是编排表的**投影**，
不是开关。所以这里也只显示不写——给一个点了不动的开关比没有开关糟得多。

三个实测坑：

1. **`SelfSizingScroll` 必须显式 `.defaultScrollAnchor(.top)`**。它先以无穷高布局
   （那时 `measured` 还是 0），再被 `min(measured, maxHeight)` 收窄——收窄时 SwiftUI
   默认保住的是**底部**锚点。症状是一进插件列表就停在第 171 条上，搜索框和标题都在
   视口外，看着像"页面自己滚下去了"。
2. **短名只砍第一个斜杠（scope 那个），不砍最后一个**。Web 把
   `@deepseek-ai/dsh-tool-subagent-control/list-agents` 显示成
   `tool-subagent-control/list-agents`；按最后一个斜杠切只剩 `list-agents`，
   而列表里同时还有一个真正的 `tool-subagent-control`。
3. **拿标题当 key 去比对两边的列表会得出假的差异**。Loader 里有四条都叫
   `tool-subagent` 的条目，`{title: enabled}` 这种 map 后写覆盖前写，
   于是我一度以为原生与 Web 对 `tool-bash` 的启用状态不一致——其实一模一样。
   条目的身份是 `entryId`，不是显示名。

**顺手对齐的一处**：`agent-presets.default` 的 schema 就是个自由字符串，照直渲染
是个让人手敲 id 的文本框；Web 是下拉框且显示「标准模式」而不是 `standard`。
预设清单这轮已经在手上，直接借过来做成 Picker，清单读不到时回落成文本框。

### 改版：把四页收进两种原生版式 —— 2026-08-26 完成

上一版内容到位、版式失控：一页表单、一页灰色圆角列表、一页手风琴卡片、一页两列
卡片网格——四页四种排版，没有一种是 macOS 偏好设置那套语法。用户的原话是"缺乏品位"。

先出草图（`docs/design/settings-layout/`，六块画板，artifact 链接在 README 里），
定下**只许两种布局**：能一屏排完的用 `Form(.columns)`，一组同类东西的用
`List(.bordered)` 主从；插件列表那 171 条用 `Table` + 斑马纹。然后按草图重写了
八个 Swift 文件，新增 `SettingsChrome.swift` 收公用件（FormRule / 源列表外框与
`+ −` / NSSearchField / StatusDot / DetailHeader）。

实打实的收益有两处，都不是"好看"：

1. 插件页那层「更多设置（N 项）」的折叠**删掉了**。详情栏一次摊得下 `shell` 全部
   六个字段，§2.2 的零遗漏不再需要拿一次点击去换。
2. 预设页那个"勾上了又置灰"的默认复选框换成了两个不撒谎的形状——已是默认就是一句
   带 ✓ 的陈述，不是默认就是一个真能按的「设为默认」。

四页都截图核过（`tools/shot.sh` + AX 量真实坐标，截图本身别拿来量尺寸）。
踩到的五个 SwiftUI 坑记在 `dash-settings/README.md` 的「版式」一节。
