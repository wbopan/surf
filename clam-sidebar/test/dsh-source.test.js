/**
 * `createSessionSource` 的行为用例：一个假 cordis ctx + 一个假 `apiProxy`，
 * 不需要跑 dsh、不需要网络、零依赖。
 *
 * ```sh
 * node --test clam-sidebar/test/*.test.js
 * ```
 *
 * 它钉住的是**我们自己的那部分逻辑**——分组、归一化、去抖、就地翻牌、错误翻译。
 * 上游 `apiProxy` 的返回形状是照 0.1.1-rc.2 的 zod schema 捏的（见 `dsh-source.js`
 * 顶部注释）：dsh 升级后如果形状变了，这里不会红，红的是真跑起来的侧边栏——
 * 所以升级后仍然要人眼核对一次 `dsh-source.js`，别把这个文件当成契约测试。
 *
 * 用例之间**共享状态、顺序相关**（node:test 单文件内顺序执行）：整个文件是
 * "一个数据源从开张到关张"的一条时间线。
 */
import assert from "node:assert/strict";
import { after, test } from "node:test";
import { createSessionSource } from "../lib/dsh-source.js";

/** 记录所有落到 apiProxy 上的调用，用来断言"没有多余的重取"。 */
const calls = [];
let archivedIds = ["session-arch"];

const sessionRows = [
	{ sessionId: "session-a", updatedAt: 300, running: false, blank: false,
		projections: { asOfSeq: 3, values: { title: "重构侧边栏" } } },
	{ sessionId: "session-b", updatedAt: 200, running: true, blank: false,
		projections: { asOfSeq: 1, values: { title: "改 bug" } } },
	{ sessionId: "session-c", updatedAt: 100, running: false, blank: true,
		projections: { values: {} } },
	// subagent 行在 session.list 里是**光的 uuid**（没有 session- 前缀）。
	{ sessionId: "bare-uuid-sub", updatedAt: 50, running: false, blank: false,
		origin: "subagent", parentSessionId: "session-a",
		projections: { values: { title: "子" } } },
	{ sessionId: "session-arch", updatedAt: 400, running: false, blank: false,
		projections: { values: { title: "已归档" } } },
];

const ok = (request, value) => ({ rpcId: request.rpcId, result: { ok: true, value } });

const apiProxy = {
	sessions: {
		list: async (r) => (calls.push("sessions.list"), ok(r, { items: sessionRows })),
		rename: async (r) => (calls.push(`sessions.rename:${r.payload.sessionId}`), ok(r, { title: r.payload.title, seq: 1 })),
		fork: async (r) => (calls.push(`sessions.fork:${r.payload.sessionId}`), ok(r, { sessionId: "session-child" })),
		// 副行摘要：尾部一页。形状照 0.1.1-rc.2 的 sessionHistoryValueSchema 捏。
		// 故意把 user 那条排在 assistant 之后（用户刚发了下一句、模型还没答），
		// 用来钉住"优先取 assistant"这条规则。
		history: async (r) => {
			calls.push(`sessions.history:${r.payload.sessionId}`);
			return ok(r, { hasMore: true, events: [
				{ event: {
					type: "assistant/message", seq: 9, time: 0,
					data: { message: { content: [{ type: "text",
						text: "## 标题 \n - **状态**：好的，我先把\n`侧边栏`拆开  " }] } },
				} },
				{ event: {
					type: "user/message", seq: 10, time: 0,
					data: { content: [{ type: "text",
						text: "接着弄 <system-reminder>别念这段</system-reminder>" }] },
				} },
			] });
		},
	},
	workspace: {
		list: async (r) => (calls.push("workspace.list"), ok(r, {
			// title 留空 → 应该退回路径末段。
			items: [{ workspaceId: "ws1", path: "/tmp/proj", title: "", sessionIds: ["session-a", "session-arch"] }],
			archivedSessionIds: archivedIds,
		})),
		archiveSession: async (r) => {
			calls.push(`workspace.archiveSession:${r.payload.sessionId}`);
			archivedIds = [...archivedIds, r.payload.sessionId];
			return ok(r, { archivedSessionIds: archivedIds });
		},
		create: async (r) => (calls.push(`workspace.create:${r.payload.path}`), ok(r, { workspace: {}, created: true })),
		// 故意失败，验证错误翻译。
		rename: async (r) => ({ rpcId: r.rpcId, result: { ok: false, error: { code: "workspace-name-conflict", message: "名字重了" } } }),
		delete: async (r) => (calls.push("workspace.delete"), ok(r, {})),
	},
};

const handlers = new Map();
const ctx = {
	apiProxy,
	on(event, fn) {
		handlers.set(event, [...handlers.get(event) ?? [], fn]);
		return () => handlers.set(event, (handlers.get(event) ?? []).filter((f) => f !== fn));
	},
};
const fire = (event, ...args) => {
	for (const fn of handlers.get(event) ?? []) fn(...args);
};
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const listCalls = () => calls.filter((c) => c === "sessions.list").length;

const source = createSessionSource(ctx, { info() {}, warn() {}, error() {} });
/** 每次下推记一笔，用来断言 immediate 与推送次数。 */
const pushes = [];
source.onChange((immediate) => pushes.push({ immediate, groups: source.groups() }));

after(() => source.dispose());

test("首轮投影：分组、归一化、归档标记、排序", async () => {
	await sleep(50);
	const groups = source.groups();
	assert.equal(groups.length, 2, "一个工作区组 + 一个兜底组");

	assert.equal(groups[0].workspaceId, "ws1");
	assert.equal(groups[0].title, "proj", "空 title 退回路径末段");
	assert.deepEqual(groups[0].sessions.map((s) => s.id), ["session-a", "session-arch"],
		"归档**不再滤掉**：侧边栏有了「显示已归档」开关，显不显示成了 UI 政策");
	assert.equal(groups[0].sessions[0].archived, false);
	assert.equal(groups[0].sessions[1].archived, true, "归档只是打个标记");
	assert.equal(groups[0].sessions[0].title, "重构侧边栏", "title 取自 projections.values");

	assert.equal(groups[1].workspaceId, null);
	assert.equal(groups[1].title, "", "兜底组标题留空——「未分组」四个字归显示层");
	assert.deepEqual(groups[1].sessions.map((s) => s.id),
		["session-b", "session-c", "session-bare-uuid-sub"],
		"按 updatedAt 倒序；subagent 的光 uuid 已补上 session- 前缀");
	assert.equal(groups[1].sessions[0].status, "running");
	assert.equal(groups[1].sessions[1].blank, true, "blank 原样带上，不在 node 侧过滤");
	assert.equal(groups[1].sessions[1].title, null, "空会话没有标题");
	assert.equal(groups[1].sessions[2].isSubagent, true);
});

test("agent/status 就地翻牌，立刻推，且不重取", () => {
	const before = pushes.length;
	const lists = listCalls();
	fire("agent/status", { agent: { id: "session-a" }, status: "running" });
	assert.equal(pushes.length, before + 1);
	assert.equal(pushes.at(-1).immediate, true, "状态翻牌是 immediate");
	assert.equal(pushes.at(-1).groups[0].sessions[0].status, "running");
	assert.equal(listCalls(), lists, "就地改一行，不去要全量");
});

test("审批点从 session log 事件推导，优先于 running", () => {
	fire("session/event", { id: "session-a" }, { type: "approval/asked" });
	assert.equal(source.groups()[0].sessions[0].status, "pendingApproval");
	fire("session/event", { id: "session-a" }, { type: "approval/decided" });
	assert.equal(source.groups()[0].sessions[0].status, "running");
});

test("普通 session/event 走去抖，不逐条重取", async () => {
	const lists = listCalls();
	fire("session/event", { id: "session-b" }, { type: "assistant/message" });
	fire("session/event", { id: "session-b" }, { type: "assistant/message" });
	assert.equal(listCalls(), lists, "去抖窗口内一次都不取");
	await sleep(500);
	assert.equal(listCalls(), lists + 1, "一整串洪流只换来一次重取");
});

test("domain/changed 只认 workspace", async () => {
	const lists = calls.filter((c) => c === "workspace.list").length;
	fire("domain/changed", { domain: "settings", table: "", key: "" });
	await sleep(500);
	assert.equal(calls.filter((c) => c === "workspace.list").length, lists,
		"别的 domain 不该惊动侧边栏");
});

test("归档：采信回包里的归档集合，行立刻翻成 archived", async () => {
	await source.archiveSession("session-b");
	assert.ok(calls.includes("workspace.archiveSession:session-b"));
	const row = source.groups().flatMap((g) => g.sessions).find((s) => s.id === "session-b");
	assert.ok(row !== undefined, "行还在——归档不再让它从投影里消失");
	assert.equal(row.archived, true, "不等重取，回包即生效");
	await sleep(500);
});

test("副行摘要：取最后一条 assistant，空会话不取，文本抹干净", async () => {
	await sleep(50);
	const rows = source.groups().flatMap((g) => g.sessions);
	const a = rows.find((s) => s.id === "session-a");
	assert.equal(a.preview, "标题 状态：好的，我先把 侧边栏拆开",
		"取的是 assistant 那条（user 更靠后也不要），换行/空白折干净，"
		+ "Markdown 记号抹平（井号 / 列表符 / 强调 / 行内代码）");
	const blank = rows.find((s) => s.id === "session-c");
	assert.equal(blank.preview, null, "空会话没有内容可摘，一次都不去取");
	assert.ok(!calls.includes("sessions.history:session-c"));
});

test("副行摘要的两把钥匙：冷会话不重取，有新消息的行立刻作废", async () => {
	const cold = calls.filter((c) => c === "sessions.history:session-a").length;
	// 与摘要无关的事件：只该触发重取列表，不该重读历史。
	fire("session/event", { id: "session-a" }, { type: "tool/call" });
	await sleep(600);
	assert.equal(calls.filter((c) => c === "sessions.history:session-a").length, cold,
		"updatedAt 没动、又没有新消息，就不该再读一次历史");

	// 落了一条新消息：**必须**重读，哪怕 updatedAt 没动。
	fire("session/event", { id: "session-a" }, { type: "assistant/message" });
	await sleep(600);
	assert.equal(calls.filter((c) => c === "sessions.history:session-a").length, cold + 1,
		"只靠 updatedAt 比对会把摘要钉死在第一次取到的那句上");
});

test("titleOf / forkSession", async () => {
	assert.equal(source.titleOf("session-a"), "重构侧边栏");
	assert.equal(source.titleOf("session-c"), undefined, "空会话没有标题，不参与序号递增");
	assert.equal(await source.forkSession("session-a"), "session-child");
	await sleep(500);
});

test("上游的错误原样抛出，不拼任何显示文案", async () => {
	// **不再拼「重命名工作区：」那个中文前缀**（计划 §8-4）：它会经 error 频道
	// 泄漏到原生 alert 上，界面切成英文也改不掉。这里只抛上游那句原话，
	// 「X 失败：原因」由 Swift 按界面语言组（swift/Strings.swift）。
	await assert.rejects(() => source.renameWorkspace("ws1", "x"),
		(error) => error.message === "名字重了" && error.clamCode === undefined);
});

test("dispose 之后不再推送", () => {
	source.dispose();
	const before = pushes.length;
	fire("agent/status", { agent: { id: "session-a" }, status: "idle" });
	assert.equal(pushes.length, before);
});
