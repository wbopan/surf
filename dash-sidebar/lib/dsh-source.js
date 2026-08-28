/**
 * 会话数据源 —— 本插件与 dsh 内部 API 唯一接触的地方。
 *
 * **dsh 升级后先核对这一个文件。** 上游服务名、方法签名、事件名的所有假设都写在
 * 这里，别的文件一处不碰 dsh。
 *
 * ## 为什么走 `ctx.apiProxy` 而不是 `ctx.sessions` / `ctx.workspaceRegistry`
 *
 * 计划 §1.6 猜的是后者，实测（2026-08-26 读 0.1.1-rc.2 源码）那条路要自己重写
 * 一大段上游逻辑，且每条都有坑：
 *
 * - **`ctx.sessions.list()` 只返回进程内活着的会话**，不是历史列表。侧边栏看到的
 *   绝大多数行是冷会话，得自己合并 `sessionPersistence.list()` 并丢掉没记 cwd 的。
 * - **`Session`/`SessionHeader` 上没有 title / running / blank / updatedAt**，四个
 *   全是派生的：title 走 `sessionProjections`（冷会话还要走 projection cache），
 *   running 看 `ctx.agents.get(id)?.status`，blank 看有没有 `turn/start` 事件
 *   （冷会话要读 log，还有 1KB 的探测上限），updatedAt 要扫最后一条用户消息。
 * - **`workspaceRegistry` 上没有 `rename`**（在 Workspace 实体上叫 `setTitle`），
 *   而重名冲突检查根本不在 registry 里，是 wire 层自己做的。
 * - **`session.fork` ≠ `ctx.sessions.fork()`**：wire 那个要对齐 `turn/end` 边界、
 *   走 `ctx.agents.create({seed})`、还要继承 workspace（subagent 还得沿祖先链找）。
 *
 * `ctx.apiProxy`（`dsh-host-apiproxy` 的 `ApiProxyService`）就是 `/api` 那套方法的
 * **同进程实现本体**——HTTP carrier 只是包了它一层。调它 = 与 web UI 逐字节同源，
 * 零网络、零重复实现。上游把它明写成"transport-agnostic by design"，就是给这种
 * 用法留的口子。DSHKit 当年解的那些 JSON，正是它的返回值。
 *
 * 调用形状：`ctx.apiProxy.<域>.<方法>({ rpcId, payload })` →
 * `{ rpcId, result: { ok: true, value } | { ok: false, error: { code, message } } }`。
 * `rpcId` 只是个被原样回显的字符串，随便给个 uuid。
 *
 * ## 事件（node 侧 cordis 事件名 ≠ wire 帧名）
 *
 * | 我们订的 | 载荷 | 干什么 |
 * |---|---|---|
 * | `session/created` / `session/disposed` | `(session)` | 结构变了 → 重取 |
 * | `session/event` | `(session, event)` | `approval/asked｜decided` 就地翻牌；其余归入"结构可能变了" |
 * | `agent/status` | `({agent, status})` | running 就地翻牌（**不在 dsh-session，在 dsh-agent**） |
 * | `domain/changed` | `(change)` | `change.domain === "workspace"` → 工作区/归档集合变了 → 重取 |
 *
 * **workspaceRegistry 一个 cordis 事件都不发**，`domain/changed` 是唯一来源
 * （apiproxy 自己也是这么转 `host/workspace-*` 帧的）。
 *
 * ## 预览行（副行摘要）从哪来
 *
 * **`session.list` 的行里没有任何消息文本**（实测 schema：sessionId / updatedAt /
 * running / blank / parentSessionId / origin / cwd / agentPreset / projections，
 * 而注册在案的投影只有 title / todos / goal / plan / permissions 之流）。所以副行
 * 只能另取：`session.history({ sessionId, maxMessages: 1 })` 读尾部一页
 * （上游按消息边界倒着数、切在 `turn/start` 上，拿到的是尾巴），
 * 从里面挑**最后一条 `assistant/message`**——副行要的是"它上次回了什么"。
 * 冷会话那次是一次文件尾读，一轮最多并发 4 条、最多取 PREVIEW_BUDGET 条，
 * 取完再推一次投影。
 *
 * 缓存**两把钥匙都要**：按 `updatedAt` 比对（冷会话永不重取），外加收到
 * `assistant/message` / `user/message` 时**显式作废那一行**。只靠 `updatedAt`
 * 会把摘要钉死在第一次取到的那句上——它未必每条消息都动。
 *
 * 文本提取是**深走 data 捡 `{type:"text"}` 块**而不是按 message 形状取：
 * user/message 与 assistant/message 的包法不同（前者 data.content，后者
 * data.message.content），而且历史上还有 legacy 变体。捡 text 块对三种都成立。
 *
 * ## 为什么这里还留着增量
 *
 * 桥上只有全量 snapshot（在进程内组一份投影是纯遍历，便宜）。但**向 dsh 要数据
 * 不便宜**：`session.list` 会遍历持久化目录、按批探测冷会话的 blank、读 projection
 * cache。一轮 agent turn 能刷出上百条 `session/event`，每条都重取就是拿 I/O 换
 * 一个不会变的列表。所以：结构类变化去抖 400ms 重取一次（沿用 DSHKit 的窗口），
 * 状态类变化（running / 待审批）直接改缓存里那一行、立刻推。
 *
 * @module dash-sidebar/dsh-source
 */
import { randomUUID } from "node:crypto";

/**
 * 需要的宿主服务。`apiProxy` 一个就够——它自己 inject 了 sessions / agents /
 * workspaceRegistry / sessionQuery 等十来个，cordis 会替我们等齐。
 */
export const SOURCE_SERVICES = ["apiProxy"];

/** 结构类变化的合并窗口（毫秒）。DSHKit 当年也是 400。 */
const REFETCH_DEBOUNCE_MS = 400;

/** 一轮最多补多少条预览（防止几百条会话的库把启动拖住）。 */
const PREVIEW_BUDGET = 80;
/** 预览的并发上限。 */
const PREVIEW_CONCURRENCY = 4;
/** 预览裁到多长（Swift 那边两行也就放得下这么多）。 */
const PREVIEW_MAX_CHARS = 140;

/**
 * @param {object} ctx 已注入 `apiProxy` 的 cordis 上下文。
 * @param {{info:Function, warn:Function, error:Function}} log
 */
export function createSessionSource(ctx, log) {
	/** sessionId → session.list 的行（原样留着，投影时才裁）。 */
	let rows = new Map();
	/** workspace.list 的行，按上游顺序。 */
	let workspaces = [];
	/** 归档集合（已规范化 id）。 */
	let archived = new Set();
	/** 正等用户审批的会话。 */
	const pendingApproval = new Set();
	/** sessionId → { at: updatedAt, text }。`at` 对不上就重取，对得上永不重取。 */
	const previews = new Map();
	/** 预览补取正在进行中（同一时刻只跑一轮）。 */
	let previewRun;

	let listeners = [];
	let timer;
	let disposed = false;
	let inFlight;

	const disposers = [
		ctx.on("session/created", () => scheduleRefetch()),
		ctx.on("session/disposed", () => scheduleRefetch()),
		ctx.on("session/event", (session, event) => onSessionEvent(session, event)),
		ctx.on("agent/status", ({ agent, status }) => onAgentStatus(agent, status)),
		ctx.on("domain/changed", (change) => {
			if (change?.domain !== "workspace") return;
			scheduleRefetch();
		}),
	];

	// 开局先取一轮。
	scheduleRefetch(true);

	return {
		onChange(listener) {
			listeners.push(listener);
		},

		groups,

		/** 分叉前读源会话标题（用于序号递增）。没有标题就返回 undefined。 */
		titleOf(sessionId) {
			const title = rows.get(normalizeSessionId(sessionId))?.projections?.values?.title;
			return typeof title === "string" && title !== "" ? title : undefined;
		},

		// ---- 写动作。一律等 dsh 落地后立刻重取，不做乐观更新 ----
		//
		// 乐观更新要在本地复刻一遍上游的写语义（归档集合怎么变、改名怎么归一化、
		// 删工作区后它的会话落到哪个组），复刻错了就是界面和真相对不上。
		// 重取一轮的代价是几十毫秒，换"屏幕上的东西一定是 dsh 说的"。

		async archiveSession(sessionId) {
			const value = await call("workspace", "archiveSession",
				{ sessionId: normalizeSessionId(sessionId) }, "归档会话");
			// 回包就是完整的归档集合，直接采信；行立刻消失，不等重取。
			if (Array.isArray(value?.archivedSessionIds)) {
				archived = new Set(value.archivedSessionIds.map(normalizeSessionId));
				emit(true);
			}
			scheduleRefetch();
		},

		async renameSession(sessionId, title) {
			await call("sessions", "rename",
				{ sessionId: normalizeSessionId(sessionId), title }, "重命名会话");
			scheduleRefetch(true);
		},

		/**
		 * 分叉，返回子会话 id。**标题的序号递增不在这里**——那是 `fork-title.js`
		 * 的事，由 `lib/index.js` 在拿到 childId 之后补一次 rename（与上游 client
		 * runtime 的 `fork(increaseTitle: true)` 同序）。
		 */
		async forkSession(sessionId) {
			const value = await call("sessions", "fork",
				{ sessionId: normalizeSessionId(sessionId) }, "分叉会话");
			const childId = value?.sessionId;
			if (typeof childId !== "string" || childId === "") {
				throw new Error("分叉会话：上游没有回子会话 id");
			}
			scheduleRefetch(true);
			return childId;
		},

		async createWorkspace(path) {
			await call("workspace", "create", { path }, "添加工作区");
			scheduleRefetch(true);
		},

		async renameWorkspace(workspaceId, title) {
			await call("workspace", "rename", { workspaceId, title }, "重命名工作区");
			scheduleRefetch(true);
		},

		async deleteWorkspace(workspaceId) {
			await call("workspace", "delete", { workspaceId }, "删除工作区");
			scheduleRefetch(true);
		},

		dispose() {
			disposed = true;
			clearTimeout(timer);
			listeners = [];
			for (const dispose of disposers) {
				try { dispose(); } catch { /* 已随 fiber 拆掉 */ }
			}
		},
	};

	// ---------------------------------------------------------------- 投影

	/**
	 * 组投影：工作区按上游顺序，其余会话进兜底组（按 updatedAt 倒序）。
	 *
	 * **归档不再滤掉**，原样带上 `archived: true`——侧边栏有了「显示已归档」开关，
	 * 于是"显示不显示"变成了 UI 政策，和 blank / subagent 同类。数据层只说事实。
	 * （M10 时归档是在这儿滤的：那时没有开关，滤掉与不显示等价。）
	 */
	function groups() {
		const grouped = new Set();
		const result = [];
		for (const workspace of workspaces) {
			const ids = (workspace.sessionIds ?? []).map(normalizeSessionId);
			for (const id of ids) grouped.add(id);
			result.push({
				id: workspace.workspaceId,
				workspaceId: workspace.workspaceId,
				title: workspaceTitle(workspace),
				sessions: ids.filter((id) => rows.has(id)).map(sessionView),
			});
		}
		const others = [...rows.keys()]
			.filter((id) => !grouped.has(id))
			.map(sessionView)
			.sort((a, b) => b.updatedAt - a.updatedAt);
		if (others.length > 0) {
			// **标题留空**：兜底组不是真工作区，「未分组」四个字归显示层。
			result.push({ id: "clam.sidebar.other", workspaceId: null, title: "", sessions: others });
		}
		return result;
	}

	function sessionView(id) {
		const row = rows.get(id);
		const title = row.projections?.values?.title;
		return {
			id,
			title: typeof title === "string" && title !== "" ? title : null,
			// 副行摘要。还没取到就是 null——显示层留空两行的位置，不显示占位文案。
			preview: previews.get(id)?.text ?? null,
			status: statusOf(id, row),
			updatedAt: Number(row.updatedAt ?? 0),
			blank: row.blank === true,
			archived: archived.has(id),
			// wire 上 subagent 行带 `origin:"subagent"`；`parentSessionId` 在场也算
			// （与 DSHKit 的判据一致，宁可多认不可漏认）。
			isSubagent: row.origin === "subagent" || typeof row.parentSessionId === "string",
		};
	}

	/**
	 * 状态点。优先级：待审批 > running > idle。
	 *
	 * **`pendingQuestion`（紫点）本次没有实现**，不是遗漏：`ask_user_question`
	 * 在 node 侧既不发 cordis 事件、也不落 session log，唯一的观察位
	 * `userQuestions.registerProvider` 是**独占**的，apiproxy 已经占着——抢过来
	 * 等于把 web UI 的问答面板掐了。想补的话正路是订
	 * `ctx.apiProxy.events.mux()`（同进程 async iterable，等价于多开一个浏览器
	 * 标签页），代价是要在这儿养一条帧流。等真有人抱怨再说。
	 */
	function statusOf(id, row) {
		if (pendingApproval.has(id)) return "pendingApproval";
		if (row.running === true) return "running";
		return "idle";
	}

	/** 工作区标题：上游给空串时退回路径末段（与 DSHKit 同款）。 */
	function workspaceTitle(workspace) {
		if (typeof workspace.title === "string" && workspace.title !== "") return workspace.title;
		const path = String(workspace.path ?? "").replace(/[/\\]+$/, "");
		return path.split(/[/\\]/).pop() ?? "";
	}

	/**
	 * 上游的 session id 规范形是 `session-<uuid>`，但 subagent 行在 `session.list`
	 * 里是**光的 uuid**（DSHKit 当年对着活服务点过：65 行里 5 行如此）。分组要拿
	 * `workspace.sessionIds` 和它对齐，所以两边都归一化。
	 * 对本来就规范的 id 是个恒等函数，无副作用。
	 */
	function normalizeSessionId(raw) {
		const id = String(raw);
		return id.startsWith("session-") ? id : `session-${id}`;
	}

	// ---------------------------------------------------------------- 事件

	function onSessionEvent(session, event) {
		const id = normalizeSessionId(session?.id ?? "");
		// 审批的两条是 log-only 的审计事件（apiproxy 自己认领审批时也是倒扫它们
		// 拿 approvalId 的）。**不要去订 `approval/request`**——那是个 waterfall
		// 抢答钩子，插一脚进去会和 apiproxy 抢着回答用户的审批。
		if (event?.type === "approval/asked") {
			pendingApproval.add(id);
			emit(true);
			return;
		}
		if (event?.type === "approval/decided") {
			if (pendingApproval.delete(id)) emit(true);
			return;
		}
		// 有新消息落盘 = 尾部变了 = 副行摘要过期。**必须显式作废**：
		// 缓存键是 `updatedAt`，而它未必每条消息都动（实测会话在跑的时候连着
		// 好几条消息 updatedAt 都是同一个值），只靠它比对的话摘要就钉死在
		// 第一次取到的那句上——那正是"preview 是固定的"这个 bug。
		if (event?.type === "assistant/message" || event?.type === "user/message") {
			previews.delete(id);
		}
		// 其余事件只意味着"这一行可能该动了"（标题、updatedAt、blank 翻牌）。
		scheduleRefetch();
	}

	function onAgentStatus(agent, status) {
		const id = normalizeSessionId(agent?.id ?? "");
		const row = rows.get(id);
		const running = status === "running";
		if (row === undefined) {
			// 还没进过列表的会话（刚建出来）：去要一轮全量。
			scheduleRefetch();
			return;
		}
		if (row.running === running) return;
		row.running = running;
		// 停下来了就顺手把审批点清掉（这一轮结束了，没人再等回答）。
		if (!running) pendingApproval.delete(id);
		emit(true);
	}

	// ---------------------------------------------------------------- 取数

	function scheduleRefetch(immediate = false) {
		if (disposed) return;
		clearTimeout(timer);
		if (immediate) {
			void refetch();
			return;
		}
		timer = setTimeout(() => void refetch(), REFETCH_DEBOUNCE_MS);
		timer.unref?.();
	}

	/** 一轮全量。并发调用合并成一次（后来者等着前一次的结果）。 */
	function refetch() {
		if (inFlight !== undefined) return inFlight;
		inFlight = (async () => {
			try {
				const [sessions, workspaceList] = await Promise.all([
					call("sessions", "list", {}, "拉取会话列表"),
					call("workspace", "list", {}, "拉取工作区列表"),
				]);
				if (disposed) return;
				rows = new Map((sessions?.items ?? [])
					.filter((row) => typeof row?.sessionId === "string" && row.sessionId !== "")
					.map((row) => [normalizeSessionId(row.sessionId), { ...row }]));
				workspaces = (workspaceList?.items ?? [])
					.filter((row) => typeof row?.workspaceId === "string" && row.workspaceId !== "");
				archived = new Set((workspaceList?.archivedSessionIds ?? []).map(normalizeSessionId));
				// 会话没了，它的审批点也就没了。
				for (const id of [...pendingApproval]) {
					if (!rows.has(id)) pendingApproval.delete(id);
				}
				for (const id of [...previews.keys()]) {
					if (!rows.has(id)) previews.delete(id);
				}
				emit(false);
				// 预览是慢的那一半：先把列表推出去，摘要随后补一轮再推一次。
				void refreshPreviews();
			} catch (error) {
				// **读失败不抬到用户面前**：列表保持上一份，下一个事件自然会再试。
				// 写操作失败才值得弹窗（那是用户刚点过的东西）。
				log.warn(`刷新会话列表失败（保留上一份）：${errorText(error)}`);
			} finally {
				inFlight = undefined;
			}
		})();
		return inFlight;
	}

	// ------------------------------------------------------------ 副行摘要

	/**
	 * 给"该取而没取"的行补预览。`updatedAt` 是缓存键：同一行没动过就不会再取。
	 * 全程失败静默——副行是锦上添花，取不到就空着，绝不能因此让列表出不来。
	 */
	async function refreshPreviews() {
		if (previewRun !== undefined) return previewRun;
		previewRun = (async () => {
			const stale = [];
			for (const [id, row] of rows) {
				if (row.blank === true) continue; // 空会话没有内容可摘
				const at = Number(row.updatedAt ?? 0);
				if (previews.get(id)?.at === at) continue;
				stale.push([id, at]);
				if (stale.length >= PREVIEW_BUDGET) break;
			}
			if (stale.length === 0) return;

			let cursor = 0;
			let changed = false;
			const worker = async () => {
				while (!disposed) {
					const next = stale[cursor++];
					if (next === undefined) return;
					const [id, at] = next;
					const text = await previewOf(id);
					// 取回来的这一刻行可能已经又变了：`at` 记的是取的是哪一版，
					// 下一轮据此再补。宁可晚半拍，不要缓存和事实对不上。
					previews.set(id, { at, text });
					if (text !== null) changed = true;
				}
			};
			await Promise.all(Array.from({ length: PREVIEW_CONCURRENCY }, worker));
			if (!disposed && changed) emit(false);
		})().finally(() => { previewRun = undefined; });
		return previewRun;
	}

	/** 取一条会话的尾部文本。任何失败都返回 null（连日志都不打——会刷屏）。 */
	async function previewOf(sessionId) {
		try {
			const value = await call("sessions", "history",
				{ sessionId, maxMessages: 1 }, "读取会话摘要");
			const entries = Array.isArray(value?.events) ? value.events : [];
			// **先找最后一条 assistant/message**：副行要的是"它上次回了什么"。
			// 倒扫时不分角色的话，用户刚发出一句、模型还没答的那一刻，副行会翻成
			// 用户自己刚打的字（还常常拖着一大段 <system-reminder> 脚手架）——
			// 那是把用户已经知道的东西又念了一遍。
			const lastOf = (type) => {
				for (let i = entries.length - 1; i >= 0; i--) {
					const event = entries[i]?.event;
					if (event?.type !== type) continue;
					const text = collectText(event.data);
					if (text !== "") return text;
				}
				return null;
			};
			// 退回用户那条只为一种情况：新会话发了第一句、还没有任何回复。
			return lastOf("assistant/message") ?? lastOf("user/message");
		} catch {
			return null;
		}
	}

	function emit(immediate) {
		if (disposed) return;
		for (const listener of listeners) {
			try {
				listener(immediate);
			} catch (error) {
				log.warn(`snapshot 订阅者抛错：${errorText(error)}`);
			}
		}
	}

	/** 一次 apiProxy 调用：拼信封、拆 `{ok, value|error}`、失败翻成中文 Error。 */
	async function call(domain, method, payload, what) {
		const api = ctx.apiProxy?.[domain];
		if (api?.[method] === undefined) {
			throw new Error(`${what}：apiProxy.${domain}.${method} 不存在（dsh 版本变了？）`);
		}
		const response = await api[method]({ rpcId: randomUUID(), payload });
		const result = response?.result;
		if (result?.ok === true) return result.value;
		const error = result?.error;
		throw new Error(`${what}：${error?.message ?? error?.code ?? "上游没有说明原因"}`);
	}
}

/**
 * 深走一个事件的 data，把 `{ type: "text", text }` 块拼起来。
 *
 * **不按 message 形状取**：user/message 的正文在 `data.content`，
 * assistant/message 在 `data.message.content`，持久化层还会把 legacy 变体
 * 改写成第三种形状。捡 text 块对三者都成立，多一层包装也不会漏。
 */
function collectText(data) {
	const parts = [];
	const seen = new Set();
	const walk = (node, depth) => {
		if (node === null || typeof node !== "object" || depth > 6) return;
		if (seen.has(node)) return;
		seen.add(node);
		if (Array.isArray(node)) {
			for (const item of node) walk(item, depth + 1);
			return;
		}
		if (node.type === "text" && typeof node.text === "string") {
			parts.push(node.text);
			return;
		}
		for (const value of Object.values(node)) walk(value, depth + 1);
	};
	walk(data, 0);
	const text = flattenMarkdown(parts.join(" ")).replace(/\s+/g, " ").trim();
	return text.length > PREVIEW_MAX_CHARS ? `${text.slice(0, PREVIEW_MAX_CHARS)}…` : text;
}

/**
 * 把 Markdown 记号抹平成人话。副行是**一行摘要**，不是文档——
 * `## ✅ Limitations` / `- **状态**: ok` 这种原样端上去只是噪音。
 *
 * 刻意做得很浅（只认行首记号与成对的强调符），**不做嵌套解析**：
 * 摘要错一点无所谓，为它引一个 Markdown 解析器才是错的成本。
 */
function flattenMarkdown(raw) {
	return raw
		// 注入的脚手架整段丢掉：它是给模型看的，不是任何人"说"的话。
		.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, " ")
		// 没闭合的那半段（被 maxMessages 截断时会遇到）也一起吃掉。
		.replace(/<\/?system-reminder>/g, " ")
		// 围栏代码块的栅栏行整行去掉（连同语言标注）。
		.replace(/^[ \t]*```.*$/gm, " ")
		// 行首记号：标题井号、引用尖括号、无序/有序列表符。
		.replace(/^[ \t]*(?:#{1,6}[ \t]+|>[ \t]?|[-*+][ \t]+|\d+\.[ \t]+)/gm, "")
		// [文字](链接) → 文字；![图](…) 里的叹号一并吃掉。
		.replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
		// 成对的强调/行内代码，取里面的字。
		.replace(/(\*\*|__)(.+?)\1/g, "$2")
		.replace(/(?<![*_\w])([*_])(?!\s)(.+?)(?<!\s)\1(?![*_\w])/g, "$2")
		.replace(/`([^`]+)`/g, "$1");
}

function errorText(error) {
	return error instanceof Error ? error.message : String(error);
}
