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

		describe() {
			return `apiProxy·${rows.size} 会话 / ${workspaces.length} 工作区`;
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
	 * 归档在这里滤掉（数据事实）；blank / subagent **不滤**，原样带给显示层
	 * ——"列表里显示什么"是 UI 政策，归 Swift 的 `AppSidebarModel.visible`。
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
				sessions: ids.filter((id) => !archived.has(id) && rows.has(id)).map(sessionView),
			});
		}
		const others = [...rows.keys()]
			.filter((id) => !archived.has(id) && !grouped.has(id))
			.map(sessionView)
			.sort((a, b) => b.updatedAt - a.updatedAt);
		if (others.length > 0) {
			// **标题留空**：兜底组不是真工作区，「未分组」四个字归显示层。
			result.push({ id: "dash.sidebar.other", workspaceId: null, title: "", sessions: others });
		}
		return result;
	}

	function sessionView(id) {
		const row = rows.get(id);
		const title = row.projections?.values?.title;
		return {
			id,
			title: typeof title === "string" && title !== "" ? title : null,
			status: statusOf(id, row),
			updatedAt: Number(row.updatedAt ?? 0),
			blank: row.blank === true,
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
				emit(false);
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

function errorText(error) {
	return error instanceof Error ? error.message : String(error);
}
