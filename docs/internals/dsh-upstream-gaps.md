# dsh 上游缺口清单

**这份文档只记录「dsh 缺、而我们决定不替它补」的东西。**

立场是定过的（2026-08-29）：**dsh 没实现的功能，我们就不实现——我们只是它的壳。**
所以下面每一条的正确处置都是「如实反映 + 记在这里」，而不是绕过公开 API 去补实现。
dsh 升级之后照着「复验」那一节跑一遍，缺口补上了就把对应条目删掉。

判据澄清一句，免得下次又走偏：**修我们自己与 dsh 的行为偏差不在此列**，
那是我们的 bug，改回去是向 dsh 看齐（见文末「已按此原则修掉的」）。
而**主动制造新的偏差也不做**，哪怕我们的版本更合理——判据不是「有没有碰私有 API」，
是「会不会让原生界面和 dsh 网页端显示得不一样」。

调查时的版本：`@deepseek-ai/dsh@0.1.1-rc.2`（全局安装，
真实包目录 `/opt/homebrew/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/`）。

> `~/.dsh/profiles/node_modules/@deepseek-ai/*` 全是符号链接，
> `grep -r` 默认不跟随，**在那儿搜一定搜不到东西**（会安静地返回空）。
> 要搜就搜上面那个真实目录。

---

## 缺口 1：没有「取消归档」

### 事实

- `ctx.workspaceRegistry` 只有 `archiveSession(sessionId)`，**只增不减**，
  已在集合里就直接 resolve、连写都不写（`dsh-workspace/lib/index.js`）。
- apiproxy 只暴露 `workspace.archiveSession`，没有对应的逆操作
  （`dsh-host-apiproxy/lib/index.js` 的 `workspace` 域）。
- 整个包树 grep 不到一个 `unarchive` 字样。
- dsh 自己的 Web 侧边栏也没有入口：`sessionVisible()` 直接把归档会话
  从所有列表里剔掉，看都看不见（`dsh-client-ui-workspace/lib/client.js`）。

### 为什么判定是「未完成」而不是「设计取舍」

数据模型**专门为取消归档留了不变量**，而且注释写了两遍：

> `archivedSessionIds` is the registry-global archive set layered over workspace
> accounting: an archived session keeps its `sessionIds` slot (**unarchiving must
> restore the position**), so the set never participates in the one-owner
> accounting invariant.

> Archiving never touches workspace accounting — an archived session keeps its
> `sessionIds` slot so **unarchiving restores its position**.

一个不打算实现的动作，不会有人专门为它维持不变量。所以这是留了设计、没写实现。

### 我们的处置

不做。曾经提过在 node 半边直接调 registry 的内部方法
（`enqueueOperation` / `requireState` / `setState`，编译后的 JS 里都是普通原型方法）
把 id 从 `archivedSessionIds` 里摘掉——**被否掉了**，理由就是本文开头那句立场。

侧边栏的「显示已归档」开关**保留**：它是目前触达归档会话的唯一途径
（能看见、能搜到、点进去也能打开），这一点比 dsh Web 强，但它本身不是新增能力，
只是没有跟着 dsh 把归档行藏死。

### 影响有多大（调查当时的实测）

`~/.dsh` 里 137 条会话中有 **106 条是归档状态**，未归档只剩 1 条。
也就是说这个缺口一旦踩上，用户的整个历史就锁在里面出不来。
**这条是本清单里最痛的一个，dsh 一旦补上应当第一时间接。**

---

## 缺口 2：工作区登记表不认领已有会话，且只在首次初始化时对齐一次

### 事实

侧边栏分组的依据是 `workspace.sessionIds` —— 一张**显式登记表**，而不是会话自带的 `cwd`。
它只有两条增长路径：

1. **一次性历史 bootstrap**：`WorkspaceRegistry[Service.init]` 里，
   仅当 `state.initialized === false` 时跑一次 `bootstrap(headers)`，
   把历史会话按 canonical cwd 分堆、每堆建一个 workspace。**这条路一生只走一次。**
2. **创建会话时显式带 `workspaceId`**：`session.create` 只有在 payload 里带了
   `workspaceId` 才会 `workspace.attachSession(sessionId)`
   （`dsh-host-apiproxy/lib/index.js`）。只带 `cwd` 建的会话，永远不入组。

而 `workspace.create` **不认领该目录下已有的会话**——新建的记录写死是空的：

```js
const record = { path: canonical, title: workspaceName, sessionIds: [], ... };
```

于是「添加目录」的实际语义是：从今往后、且只从 GUI 那条路走的会话才进得来。
终端里直接跑 `dsh` 建的会话一律进 Ungrouped，加不加目录都一样。

### 为什么这一处可以直说是坏的

同一个 registry 内部对同一件事的判断自相矛盾：`bootstrap` 认为「同一个 cwd 下的会话
属于这个目录」是天经地义的（那 4 个工作区就是它这么建出来的），`create` 却假装这条
规则不存在。而且登记表只增不修、没有任何对账机制，会一直静默漂移。

### 实测的漂移程度（2026-08-29）

| 目录 | 磁盘上的会话 | 登记表认的 |
|---|---|---|
| Desktop | 46 | 32 |
| dsh-mac | 63 | **4** |
| taste-bench | 19 | 14 |
| Obsidian Vault | 3 | **0（连 workspace 记录都没有）** |
| /tmp、~/Local 等 | 4 | 0 |

Ungrouped 共 85 条，其中**只有 3 条是真的没有归属**，其余全都有明确的 cwd。

时间分布证明这不是「记录建晚了」——两段是交错的：

```
【dsh-mac】记录 8/23 06:49 就建好了
   已入组   4 条：8/25 05:18 → 8/25 05:29
   无归属  59 条：8/23 06:49 → 8/24 12:54     ← 记录已存在，照样没入组
```

### 我们的处置

不做。曾提议原生侧边栏改按会话自带的 `cwd` 分组（数据全来自 `session.list` 的公开
字段、不新增能力），**被否掉了**：那不是在修偏差，而是在主动制造偏差——原生侧边栏会
和 dsh 网页端显示得不一样。

顺带记一个反证，将来跟上游讨论时用得上：**dsh 自己在搜索结果里就是按 cwd 标目录名的**
（`dsh-client-ui-workspace/lib/client.js` 的 `deriveSearchResults`）：

```js
const labelOf = (summary) =>
  workspaceBySession.get(summary.id) ?? workspaceLabel(summary.cwd);
```

`workspaceLabel(cwd)` 取的就是 basename。所以那 3 条 Obsidian Vault 会话在 dsh 的
**搜索结果**里标签是 "Obsidian Vault"，在**分组**里却是 "Ungrouped"。
数据一直在，只是分组那条路径没用它。

---

## 复验

dsh 升版后跑这两段，判断缺口还在不在。

**缺口 1**——搜到任何一处就说明可能补上了：

```sh
R=/opt/homebrew/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai
grep -rl 'unarchive' "$R"          # 现在：无输出
```

**缺口 2**——复算「磁盘上有多少会话、登记表认了多少」：

```sh
node -e '
const fs=require("fs"),path=require("path"),os=require("os");
const home=os.homedir();
const ws=JSON.parse(fs.readFileSync(home+"/.dsh/storages/workspace.json","utf8"));
const norm=id=>String(id).startsWith("session-")?String(id):"session-"+id;
const root=home+"/.dsh/sessions";
const byId=new Map();
for(const dir of fs.readdirSync(root))
  for(const f of fs.readdirSync(path.join(root,dir))) byId.set(norm(f), dir);
console.log("磁盘会话", byId.size, "| 归档", ws.global.archivedSessionIds.length);
const accounted=new Set();
for(const rec of Object.values(ws.tables.workspaces)){
  const ids=(rec.sessionIds||[]).map(norm);
  ids.forEach(i=>accounted.add(i));
  console.log(`  ${rec.title.padEnd(14)} 登记 ${String(ids.length).padStart(3)} 条  ${rec.path}`);
}
const others=[...byId.keys()].filter(i=>!accounted.has(i));
const tally={};
for(const i of others) tally[byId.get(i)]=(tally[byId.get(i)]||0)+1;
console.log("Ungrouped", others.length, "条，按真实 cwd 拆：");
for(const [d,n] of Object.entries(tally).sort((a,b)=>b[1]-a[1])) console.log("   ", d, n);
'
```

`~/.dsh/storages/workspace.json` 是 registry 的持久化本体
（`global.archivedSessionIds` + `tables.workspaces`），比问活服务省事得多。
会话按 cwd 分目录存在 `~/.dsh/sessions/<转义后的 cwd>/<sessionId>/session.jsonl.zstd`，
**目录布局本身就是「会话属于哪个 cwd」的事实**。

---

## 已按此原则修掉的（这些是我们的 bug，不是 dsh 的）

同一次排查里发现的两处「我们和 dsh 行为不一致」，都已改回去向 dsh 看齐：

1. **空的工作区组被我们滤掉** —— `SidebarFilter.filteredGroups` 原本要求组里至少有
   一条会话才渲染，于是刚添加的目录（`sessionIds` 必然是空的）在侧边栏上**毫无反应**，
   看起来像按钮坏了。dsh 的 `deriveGroups` 注释第一句就是 "Every group shows"。
   已改成真工作区组恒显示（兜底组除外；搜索/待处理这类查询模式下仍不摆空组头）。

2. **筛选菜单吞掉第一个工作区** —— `NSMenuToolbarItem` 走 pull-down 语义，把菜单第 0 项
   当自己的标题吃掉。症状是工作区列表永远少最上面那一个，而数据和日志里都在。
   已在 surf-layout 收口（`NSMenuToolbarItem.padPullDownTitleSlot`，block 与数据两条
   菜单路线都垫），贡献方不需要知道这件事。

---

## 执行日志

- **2026-08-29** 首次成文。起因是侧边栏三个报障：无法取消归档、会话大量落进 Ungrouped、
  筛选菜单目录不全。查下来两个是上游缺口（本文正文），一个是我们自己的 bug
  （筛选菜单吞首项），外加排查途中发现的空组不显示。立场与处置见正文。
