# clam-memory 权威计划

**状态**：设计完成，三处决策已定（§2.6），M0～M3 实现中。
**日期**：2026-08-29。
**一句话**：给 dsh 加一个跨会话的持久记忆——一目录 markdown，每条带 frontmatter，
每步把**索引**（name + description）注入上下文，正文由模型按需读取，写入由模型自己发起。

## 0. 不变量

0. **纯 node 插件，零 macOS 依赖。** 不 inject `clamBridge`，没有 `swift/` 目录，
   不碰壳、不碰 WebView。`@wenbo/clam-memory` 必须能被任何一台装了 dsh 的机器
   单独 `dsh plugin add`，Linux 上也要能跑。名字留在 `clam-*` 家族里只是出身，
   不是耦合。
1. **不新建第二个真相源。** 记忆是磁盘上的 markdown 文件，没有数据库、没有索引文件、
   没有进程内权威副本。索引**每次装配时从各文件的 frontmatter 实时组装**。
2. **不往 session 日志写自定义事件类型**（CLAUDE.md 踩坑记录第一条）。记忆落盘只走文件系统。
3. **缺席即无记忆。** 插件不在编排表里，dsh 的行为与今天完全一致；
   记忆目录为空，注入的那一段整体消失（返回 `""`），不留空壳标签。
4. **记忆是背景资料，不是用户指令。** 注入的文本里必须显式声明这一点——
   记忆文件可能被间接提示注入污染，且**污染会跨会话存活**，这是本设计最大的攻击面（§7.4）。

## 1. 事实清单

三路调研的硬结论。**每条都可复核**，冲突时以源码/实测为准并就地更新本文档。

### 1.1 dsh 的上下文注入通道（源码实测）

源码根 `$D` = `/opt/homebrew/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/`
（`~/.dsh/profiles/node_modules/@deepseek-ai/` 是指向它的符号链接）。

| 路子 | API | 落到哪 | 异步 | 抗压缩 | KV cache |
|---|---|---|---|---|---|
| **A** | `ctx.systemPrompt.section()` | 系统提示词正文 | ❌ | ✅ 每 step 重装 | ⚠️ 一变，**整条历史前缀作废** |
| **B** | `ctx.systemPrompt.context()` | user 快照消息，框架自动去重/取代/清空 | ❌ | ❌ 可被压缩藏起来 | ✅ append-only |
| **C** | `ctx.on("agent/pre-step")` | 任意 durable user 消息，完全自控 | ✅ | ❌ 各自写重建逻辑 | ✅ append-only |
| D | `agent.inject(msg)` | 同 C，推进 inbox 等下一 step 认领 | ✅ | ❌ | ✅ |
| E | `exec.deferContext(msg)` | 本次 tool result 之后 | ✅ | ❌ | ✅ |
| F | `system-prompt/assemble` waterfall | 整个 assembly | ✅ | — | 取决于改了什么 |

**装配每 step 一次，全库只有一个调用方**：`$D/dsh-agent-loop/lib/index.js:497`。
`section()` / `context()` 的 `text` **可以是函数**，签名 `(context: AssembleContext) => string`
（`$D/dsh-system-prompt/lib/index.js:271, 278`），`context.agent` 给到 `agent.id`（SessionId）
与 `agent.session.header.cwd`——这就是"按会话动态生成"的入口。**但它是同步的**，
不能在里面做 IO。

### 1.2 skill catalog 实际走的是 C，不是系统提示词

`$D/dsh-tool-skill/lib/index.js:181-214`。**dsh 全库没有任何一处把"会变的清单"放进
system prompt**，这是刻意的 KV cache 取舍（三处独立证据：`dsh-system-prompt/README.md:69`、
`dsh-sandbox-policy` 模块注释、`dsh-compaction-basic/lib/index.js:211-217`）。

它的四条设计，**我们全抄**：

1. **digest 算在结构化 entries 上，不是渲染后的散文**（`:274-280` 有注释解释：
   信封文案是写给模型的，不该决定要不要重发）。
2. **消息带结构化 `source`**（`:233-237`），真相存在 source 里，消费方不用回去解析 XML。
3. **基线从 `agent.session.events` 倒扫自己的 source 得到**（`catalogHistory`，`:309-326`），
   跨 resume 幂等，不依赖进程内缓存。
4. **整表替换而不是 diff**——一个名字变了就重发全表，让废弃条目的退休是显式的。

它之所以必须用 C 而不是 B，是因为 `ctx.skills.snapshot()` 是异步的。**我们没有这个约束**
（索引可以常驻内存），所以 B 对我们可用——见 §2.6 待裁决 D1。

### 1.3 Claude Code auto memory 的实际形状（本机实测 + 二进制提取）

- **路径**：`~/.claude/projects/<slug>/memory/*.md`，`<slug>` = **git repo root** 绝对路径
  把 `/` 换成 `-`。`~/.claude-dev/projects` 是指向 `~/.claude/projects` 的符号链接。
- **frontmatter**：`name`（kebab slug）/ `description`（一行，"used to decide relevance in
  future conversations, so be specific"）/ `metadata`{`node_type: memory`、
  `type: user|feedback|project|reference`、`originSessionId`、可选 `pinned`、`modified`}。
- **正文**用 `[[other-name]]` 交叉引用（91 条样本里 213 次，是实际在用的惯例）；
  官方措辞："a `[[name]]` that doesn't match an existing memory yet is fine;
  it marks something worth writing later, not an error."
- **索引实时从 frontmatter 组装**，不读 `MEMORY.md`——代码里有个遥测标志叫
  `disk_index_superseded`。磁盘上残留的 `MEMORY.md` 是**被废弃的旧路径**。
- **硬上限**（从二进制抠出）：索引 200 行 / 25,000 字节 / 最多扫 200 个文件；
  description 截断 200 字符、name 截断 60；**单条记忆 4,096 字节**（召回只显示前 4,096）；
  建索引时**每个文件只读前 30 行 / 64 KB**；pinned 上限 **8**（按 `modified` 倒序）。
  保留子目录名 `team` / `logs` / `sessions` / `proposals` 不进索引。
- **索引行格式**：`- [{name}]({path}): {description}`。

**实测体量**（本机最大的一个项目，chalk-project）：91 条记忆，正文合计 **314 KB
（≈90k tokens）**——全量注入不可行；**索引 18.5 KB（≈5~6k tokens）**——可行，
但已到 25 KB 上限的 74%。**治理是真需求，不是理论问题**：约半年、约 90 条就顶到上限。

### 1.4 业界结论

- **框架（mem0 / Letta / Zep / LangMem / cognee）对这个规模过度设计约一个数量级。**
  它们解决的三个问题我们都没有：捕获（我们的 agent 是作者，不是转述者）、
  规模化矛盾消解（**具名文件天然有身份，更新是编辑而不是新增一行**）、
  语料大到没法展示（我们的不大）。算过账：那些维护用的 LLM 调用**成本是"每步直接带上
  整个索引"的 2~5 倍**。反向最强证据：Letta 最新的记忆形态 MemFS 就是一个 git 管理的
  markdown 目录。
- **第二级检索用 `grep`，不用向量。** Windsurf / Cline / Devin / Amp 都是这么退回来的。
  索引超过约 10k tokens 再谈检索。
- **ETH 苏黎世 2026-02《Evaluating AGENTS.md》**：上下文文件"成功率没有提升，
  推理成本反而涨 20% 以上"，机制是"不必要的要求让任务更难"。博客转述的正文拆分是
  人写 +4% / **模型生成 −3%**（未拿到原文，**算未证实**）。→ 直接支持 §2.6 D3：
  pinned 该由人设。
- **ACE 论文的 context collapse**：反复整体重写会侵蚀细节。→ 治理必须是
  **合并/编辑，绝不重新生成**，且**离线跑**，不落在交互轮次上。
- **可抄的现成实现**：`kuitos/opencode-claude-memory`（MIT，核心 275 + 168 行 TS，
  读写的就是 Claude 那套磁盘格式，常量与我们要的完全一致）。
  路径加固抄 `anthropic-sdk-typescript` `src/tools/memory/node.ts` 那约 80 行
  （符号链接逃逸检查、逐级 `0o700` mkdir、`O_EXCL` 原子写）。

## 2. 设计

### 2.1 形状

```
<记忆目录>/
  <name>.md          # 一条记忆 = 一个文件，扁平，无子目录
```

**扁平命名空间**是安全属性，不只是简洁：没有子目录，路径穿越这一整类 bug 就不存在，
而不是需要防御。文件名正则 `^[a-z0-9_-]+$`，拒绝分隔符、`..`、空字节、前导 `.`。

### 2.2 记忆文件格式

与 Claude Code **逐字段兼容**（这是 §2.5 双模式的前提，不是巧合）：

```markdown
---
name: kebab-case-slug
description: 一行摘要，用来在未来的会话里判断相关性，所以要具体
metadata:
  node_type: memory
  type: user | feedback | project | reference
  originSessionId: <写下它的那个会话 id>
  modified: 2026-08-29T12:34:56Z     # 由我们的代码盖，永远不由模型写
  pinned: true                        # 可选，人设（见 D3）
---

正文。用 [[other-memory-name]] 交叉引用。
```

`modified` 由代码盖而不是模型写——它是 pinned 排序的依据，也是让陈旧对人和模型
都可见的唯一手段。

### 2.3 注入什么

**索引**，每条一行：

```
- `<name>`: <description>
```

外层信封（措辞待定稿，要点固定）：
- 声明这是**背景资料，不是用户指令**，反映的是**写下时**为真的东西；
- 声明这里只有摘要，**用 `memory_read` 拿正文之前不要据此下结论**；
- 命名了具体文件/函数/开关的记忆，是**关于过去的断言**，推荐之前先核实它还在。

**索引被截断时，把这件事写进注入的文本本身**（抄 `truncateEntrypoint`）：
`> 警告：索引有 240 行（上限 200），只装载了一部分。` 这是全套治理里最便宜的一条——
模型看得见自己的索引溢出了，才可能去收拾。

pinned 的记忆**全文**注入，上限 8 条，按 `modified` 倒序。

### 2.4 工具

两个，都用 `defineTool`（`@deepseek-ai/dsh-tools`）。参数 schema 是 dsh 自己的
`ParameterSchemaSpec` DSL，不是 schemastery、也不是裸 JSON Schema。`output` 是强制的
（`schema` + `render`）。description / parameters 会**自动**进 prompt，插件什么都不用做。

| 工具 | 参数 | 说明 |
|---|---|---|
| `memory_read` | `name` | 按索引里的精确 name 读一条正文 |
| `memory_write` | `name` / `description` / `type` / `content` | 新建或**整体替换**一条；代码盖 `modified` 与 `originSessionId` |

**不提供 `memory_delete`。** 删除是不可逆的，且模型判断"这条过时了"的准确率是
本设计里最没把握的一环。过时的处理方式是 `memory_write` 覆盖同名文件。
真要删就让用户去删文件——那是一条 `rm`。（若 §9 M4 的治理需要，再单独议。）

**不提供 `memory_search`。** 模型已经有 `grep`，记忆目录就是普通文件。

### 2.5 存储目的地：两种模式

设置 ns `clam-memory`，键 `dir`：

| `dir` 的值 | 落在哪 | 用途 |
|---|---|---|
| `""`（缺省） | `<dshHome>/memory/<slug>/` | dsh 自持。`@deepseek-ai/dsh-home-paths` 的 `dshHomePath()` |
| `"claude"`（字面量） | `~/.claude/projects/<slug>/memory/` | **直接复用 Claude Code 的记忆**，与之共享同一份 |
| 其它 | 当作绝对路径（`expandHomePath` 展开 `~`） | 自定义 |

`<slug>` = **git repo root 的绝对路径把 `/` 换成 `-`**；不在 git 仓库里时退回 cwd。
这条规则是从本机实测反推的，`"claude"` 模式下必须逐字一致，否则会在 Claude 旁边
另建一个空目录而**不报错**——这是本设计最容易安静走偏的一处，M1 必须有针对性验证。

`"claude"` 模式是**读写同一份**：dsh 里写的记忆，Claude Code 下次开同一个仓库就能看到，
反之亦然。这正是 §2.2 逐字段兼容换来的。**Claude 的目录里可能有 `MEMORY.md`**
（那条被废弃的旧路径的残留）——按"无合法 frontmatter 即跳过"自然滤掉，不必特判。

### 2.6 三处决策（2026-08-29 定，含理由）

**D1 — 注入走 B（`systemPrompt.context()`）。**

复核后这一处比初看简单：**B 与 C 在抗压缩性上完全一样**——两者的产物都是会话历史里的
durable user 消息，都会被 compaction 藏起来。差别只在"框架白送 vs 自己写"。
skill catalog 之所以用 C，纯粹是因为 `ctx.skills.snapshot()` 是异步的、而 `context()`
的 `text` 是同步的；**我们没有这个约束**（索引常驻内存）。所以 B 严格占优。

框架白送的四件事：去重（文本没变返回 `undefined`）、取代（快照自带 "supersedes earlier
runtime-context snapshots"）、清空（`CLEARED` 墓碑）、**resume 后从 session events 恢复基线**。

真正的取舍是 B/C 对 **A**（`section()`）：A 每 step 重装、压缩免疫，但记忆索引一变
就作废整条历史的 KV 前缀。记忆索引恰恰是会变的（模型自己写记忆），所以 A 太贵。
**若日后实测发现长会话里索引被压缩吃掉且确实有害，退路是切到 A**——只改一个调用点。

**D2 — 缺省目的地是 dsh 自持（`dir: ""`）。**

插件要能装到别人机器上，那台机器不一定有 Claude Code；缺省指向另一个产品的私有目录
是意外耦合。用户原话也是"**可选的**直接使用 claude 的目的地"——可选，不是缺省。
切过去是一行设置。

**D3 — `pinned` 只有人能设，模型写不了。**

`memory_write` 不接受这个字段；要 pin 就人去编辑文件（M1 不做 UI）。理由是 §1.4 的
ETH 证据：模型生成的常驻上下文可能是负收益。索引行错了只值一行，pinned 全文错了不止。
这条也是对 §7.5 那个风险的直接回应。

### 2.7 存储层接口（M1 交付，M2/M3 消费）

```js
createMemoryStore({ dir })  // dir = 设置里的原始值（"" | "claude" | 绝对路径）
  .resolveDir(cwd)          -> string            解出本次该用哪个目录（含 slug）
  .index(cwd)               -> { entries, truncated }
        // entries: [{ name, description, pinned, modified }]，按 modified 倒序
        // truncated: null | { reason: "lines"|"bytes", shown, total }
  .pinned(cwd)              -> [{ name, content }]        最多 8 条，modified 倒序
  .read(name, cwd)          -> { name, description, type, content } | undefined
  .write(rec, cwd)          -> void   // rec: {name, description, type, content, sessionId}
                                      // 代码盖 modified；拒绝 pinned；校验 slug 与 4KB
  .invalidate()             -> void   // 写入后与 settings/updated 时清缓存
```

全部同步或"读缓存 + 后台刷新"，因为 `context()` 的 `text` 是同步的（§1.1）。

## 3. 治理与上限（照抄 §1.3 的常量）

| 项 | 值 |
|---|---|
| 索引行数 | 200 |
| 索引字节 | 25,000（在最后一个换行处截断，并把截断事实写进注入文本） |
| 扫描文件数 | 200 |
| 单条记忆 | 4,096 字节——**是「召回时显示多少」的上限，不是「能写多大」的上限**（见执行日志 2026-08-29 第 3 条） |
| description 截断 | 200 字符 |
| name 截断 | 60 字符 |
| 建索引每文件只读 | 前 30 行 / 64 KB |
| pinned | 8 条，按 `modified` 倒序 |

**不做**：衰减评分、热度、重要性加权淘汰（mem0 已经放弃了这条路，改用显式过期）。
**合并/整理放到 M4**，且必须离线跑、必须是合并而非重新生成（ACE 的 context collapse）。

## 4. 提示词文案（最高杠杆的部分）

写进工具 description 与注入信封。要点，措辞 M2 定稿：

**不该存什么**（抄 Claude Code 那五条，是全套里性价比最高的十行）：
代码模式/约定/架构/文件路径——读代码就知道；git 历史——`git log` 是权威；
调试解法——修复在代码里、上下文在 commit message 里；已经写在 AGENTS.md/CLAUDE.md 里的；
临时状态——进行中的工作、当前对话的上下文。
**这些排除项在用户明确要求保存时同样成立**；用户要存 PR 列表或活动摘要时，
反问"其中哪一点是意外的、不显然的"，那部分才值得留。

**对称性规则**（这条别处没见过，值得抄）：
"从失败**和**成功两边记录：只存纠正，你会避开过去的错误，却会漂离用户已经认可过的
做法，并变得过度谨慎。纠正很显眼，认可很安静——要留意后者。"

**正文结构**（rule 类记忆）：先写规则/事实，再写 `Why:` 与 `How to apply:` ——
"知道为什么，才能判断边界情况，而不是盲从规则。"

**相对日期一律转成绝对日期**（写入时）。一句话，回报很大。

## 5. 里程碑

| | 内容 | 完成判据 |
|---|---|---|
| **M0** | 骨架：包、`package.json`（peerDeps 只有 `@deepseek-ai/*`）、编排表加一行 | `./dev` 起得来，诊断树里有它，记忆目录为空时**零注入** |
| **M1** | 存储层：路径决议（三模式 + slug）、frontmatter 解析、索引组装、上限与截断、路径加固 | 单测覆盖：slug 与本机 Claude 目录**逐字节一致**；符号链接逃逸被拒；超限截断带警告 |
| **M2** | 注入：按 D1 的裁决接上；信封文案定稿 | 真会话里 dump 一次装配结果，确认索引在场、空目录时整段消失 |
| **M3** | 工具：`memory_read` / `memory_write`，含写入校验（4 KB、slug、不许写 `pinned`） | 模型能自己完成"写一条 → 新会话里读到"的闭环 |
| **M4** | 治理（可选）：离线合并整理 | 待 M3 有真实数据后再定，**不要提前设计** |

M1/M3 需要单测。参照 `clam-sidebar/test/*.test.js`（`node --test`，零依赖），
**给 `--test` 一个目录在 node 26 上会 `MODULE_NOT_FOUND`，别省通配符**。

## 6. 不做什么

向量库、嵌入模型、图数据库；抽取 pipeline；衰减/热度评分；模型维护的 `MEMORY.md`
索引文件（那是被废弃的旧路径）；子目录与主题分类法（研究表明层级把检索成本减半但
不改善答案质量，且随规模增长而腐烂——扁平同时是安全属性）；每轮的整理
（context collapse）。

## 7. 风险

1. **slug 算错**（§2.5）——`"claude"` 模式下会安静地建一个空目录。M1 必须实测比对。
2. **`context()` 被压缩藏起来**（D1 的代价）——长会话里记忆索引可能消失。
   若真发生，退路是切到 A（`section()`），代价是 KV cache。
3. **索引腐烂**——研究结论是"笔记本身没事，腐烂的是索引"。我们实时组装索引，
   这条被结构性地免疫掉了（记忆不可能与索引项脱节）。
4. **记忆投毒**——间接提示注入若进了写入路径，**污染跨会话存活**，
   受控实验里报告过 >90% 的成功率，且现有的提示注入防御覆盖不全。
   我们的防线是 §2.3 的信封声明（一句话），以及"推荐之前先核实"那条规则。
   **这是本设计接受的残余风险，不是已解决的问题。**
5. **ETH 那条负面证据**（§1.4）——如果 LLM 生成的常驻上下文确实是负收益，
   本设计的价值就主要在"索引一行 + 按需读取"这个形状上，而不在"记得多"。
   D3 把 pinned 交给人是对这条的直接回应。

## 8. 执行日志

（每完成一个里程碑追加一行：日期 / 里程碑 / 实际与计划的偏差 / 新发现的事实。）

- 2026-08-29 — 计划成文。三路调研（dsh 注入机制源码、业界实现、本机 Claude 目录实测）
  已合并进 §1。§2.6 三处决策当场定下（B / dsh 自持 / pinned 人设），开始 M0～M3。

- 2026-08-29 — **M0～M3 完成**，32/32 单测绿（`node --test clam-memory/test/*.test.js`），
  端到端验证通过（`dir: "claude"` 模式读到本仓库真实的 6 条 Claude 记忆：pinned 那条
  全文注入、其余 5 条进索引、`MEMORY.md` 被自然跳过，共 5,345 字节）。
  交付：`clam-memory/`（`lib/{index,prompt,store,paths}.js` + `test/` + README）、
  伞包编排表与 `package.json` 各加一行。**实测推翻/修正了计划的四条**：

  1. **`order: 120` 已被占用**——`dsh-subagent/lib/index.js:572` 在 childCtx 上注册
     `subagent:delegation`，order 正是 120。§1.1 那张 order 分布表漏了它（它只在
     子代理的 ctx 上，全局装配时看不见）。撞上不报错，只是先后变成注册顺序的副产物。
     **实际用 125。**
  2. **`modified` 与 `pinned` 在真实 Claude 记忆里都很罕见**：全机 190 条里
     `modified` 41 条（22%）、`pinned` **2 条（1%）**。所以按 `modified` 倒序排序时，
     **mtime 兜底是主路径而不是边界情况**。§2.2 把这两个字段写得像常规字段，不准确。
  3. **4,096 是「召回显示上限」，不是「写入上限」**——全机 190 条里 **29 条（15%）
     超过它**，最大 13 KB。原计划让 `write()` 硬拒绝超限，那会导致**Claude Code 自己
     写的大记忆我们读得到、写不回**。已改为：照写不误，返回一条 warning 说明
     "超出部分未来的会话看不见"。工具 description 的措辞相应从"规则"改成"理由"
     （模型知道为什么，才能判断边界情况）。
  4. **slug 用的是 worktree root，不是主仓库 root**——`~/.claude/projects/` 里
     `-Users-wenbopan-Repos-surfclam--claude-worktrees-clam-i18n-plan` 与
     `-Users-wenbopan-Repos-surfclam` 并存。所以"逐级向上找到第一个 `.git` 就停
     （它可能是文件而不是目录），**不要跟着 `gitdir:` 再跳一次**"是对的。

  另外三处实现层面的判断（计划没写死，记录在案）：`truncated.reason` 有第三种值
  `"files"`（200 个文件的扫描上限会先于行数上限触发），三种各有独立文案，因为
  "文件太多"与"description 太长"对应完全不同的处置；`write()` **保留已有的
  `pinned: true`** 而不是抹掉（否则模型一次覆写就把人的钉子拔了，D3 形同虚设）；
  注入路径 try/catch 吞异常返回 `""`——坏 frontmatter 不该赔掉整个 agent step。

  **收尾修正**（合并两个子代理的产物时发现）：伞包 `package.json` 的 `dependencies`
  也必须加一行——`./dev` 是从那里读"要 link 哪些插件"的，只改 `cordis.patch.yml`
  会在启动时炸 `Cannot find package '@wenbo/clam-memory'`；存储层的错误消息原本是
  中文，而它们经 tool-error 路径直接进模型上下文，已统一为英文（面向模型的文案
  一律英文，面向人的文档与注释一律中文）。
