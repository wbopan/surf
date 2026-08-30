# DSH Web API wire notes（M0 spike 实测）

> 本文记的是 **dsh 的 Web API 协议事实**，M8 复核仍然成立（unary POST `/api/<method>`、
> 两条只下行的事件流 WebSocket、rpcId 回显、loopback 无鉴权）。只有环境描述过时了：
> 阶段二把 bundle id 换成了 `io.wenbo.surf`，壳也不再自己装 harness——dsh 现在是
> 全局安装、由用户在终端启动。下面的路径按当时原样保留，不影响协议结论。

验证环境：harness `0.1.1-rc.2`（`~/Library/Application Support/io.wenbo.dsharness/harness/versions/0.1.1-rc.2`），
本机 web server `http://127.0.0.1:50241`，2026-08-24 curl 实测。
源码依据：`@deepseek-ai/dsh-client-connection/lib/client.js`（AbstractApiClient，~L6180–6240）。

## Unary（HTTP POST）

朴素 JSON，不是 JSON-RPC 也不是 Typert 编码。每个方法一个 URL：

```
POST /api/<method>
Content-Type: application/json

{"type":"client-request","rpcId":"<uuid>","method":"<method>","payload":{...}}
```

响应（HTTP 200，业务错误也是 200）：

```json
{"type":"server-response","rpcId":"<echo>","result":{"ok":true,"value":{...}}}
{"type":"server-response","rpcId":"<echo>","result":{"ok":false,"error":{"code":"session-not-found","message":"...","details":{...}}}}
```

- rpcId 必须回显校验；未知方法 → HTTP 404。
- loopback 无鉴权，仅需 `Content-Type: application/json`。

### host.describe

```bash
curl -s -X POST http://127.0.0.1:50241/api/host.describe -H 'Content-Type: application/json' \
  -d '{"type":"client-request","rpcId":"11111111-1111-1111-1111-111111111111","method":"host.describe","payload":{}}'
# → {"type":"server-response",...,"result":{"ok":true,"value":{"version":"0.0.1","cwd":"/Users/wenbopan","provider":"zai-coding-cn","model":"glm-5.3","attachedSessions":10,"home":"/Users/wenbopan","canOpenPath":true}}}
```

### session.list

payload `{}`（`cursor` 可选；实测传未知 cursor 仍返回全量）。**无分页行为观察**：一次返回全部会话。

行结构（实测字段）：

```json
{"sessionId":"session-8b46...","updatedAt":1787486780702,"running":false,"blank":false,
 "cwd":"/Users/wenbopan/Repos/dsh-mac","agentPreset":"standard",
 "projections":{"asOfSeq":31,"values":{
   "title":"Simple greeting message",           ← 侧边栏标题来源（blank 会话为 null）
   "sessionListMetadata":{"blank":false,"lastPromptAt":1787486780702},
   "todos":[...],"plan":{...},"permissions":{...}, ... 其余投影与列表无关，忽略 }}}}
```

- 标题在 `projections.values.title`（string 或 null）；无 title 顶层字段。
- 状态：顶层 `running`（bool）；待批准/待回答要从事件流（approval/question）另行叠加，list 里没有。
- `parentSessionId`/`origin:"subagent"` 标记子代理会话；blank=true 的行也要显示（新建未输入）。

### workspace.list

```json
{"items":[{"workspaceId":"53f18...","path":"/Users/wenbopan/Repos/taste-bench","title":"taste-bench",
  "sessionIds":["session-f418...","session-67f6..."],
  "createdAt":"2026-08-23T08:04:29.206Z","updatedAt":"2026-08-23T08:25:31.317Z"}],
 "archivedSessionIds":["session-b5f2...", ...]}
```

- 分组 = workspace.items[].sessionIds 顺序即显示顺序；archivedSessionIds 里的从列表剔除。
- 未归档但不在任何 workspace.sessionIds 里的会话（子代理等）按需兜底分组。

### session.create

```json
// payload {"cwd":"/tmp/dsh-m0-spike"}（或 {"workspaceId":"..."}，二者互斥；可带 agentPreset）
{"type":"server-response",...,"result":{"ok":true,"value":{"sessionId":"session-9b80...","agentPreset":"standard"}}}
```

### session.rename / session.cancel

- rename payload `{"sessionId":"...","title":"..."}` → value `{"title":"<normalized>","seq":N}`；
  会话不存在 → `{"ok":false,"error":{"code":"session-not-found",...}}`。
- cancel payload `{"sessionId":"..."}`（源码 schema 同族；阶段一后置）。

## 事件流（WS，只下行）

`ws://127.0.0.1:<port>/api/events.mux` 与 `ws://.../api/events.host`。
每帧一个 JSON 文本消息 `{type:"server-request", rpcId, method, payload}`；客户端上行会被 1008 关闭。
帧型分布：mux 流 `session/event`、`approval/requested`、`question/requested`；
host 流 `host/session-status`、`host/agent-error`。完整解析实现见 `DSHarness/EventsBridge.swift`。

列表增量更新建议：`session/event`（任意会话有新事件 → updatedAt/title 变化，重拉或按帧更新）、
`host/session-status`（running 布尔）、`approval|question/requested` + 超时/取消 → 待批准/待回答状态点；
连接重连成功后全量 refetch `session.list` + `workspace.list` 兜底。

## 备注

- 工作量结论：DSHKit 传输层可用朴素 JSON 实现，无需特殊编码。
- `session.search`：payload `{"query":"..."}` → `{items:[{sessionId,snippet≤240}], hasMore}`（阶段一后置）。
