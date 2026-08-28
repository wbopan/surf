/**
 * header 数据源 —— 本插件与 dsh 内部 API 唯一接触的地方。
 *
 * **dsh 升级后先核对这一个文件。** 上游服务名、方法签名、事件名的所有假设都写在
 * 这里，别的文件一处不碰 dsh。（与 clam-sidebar 的 `dsh-source.js` 同一条纪律，
 * 那份文件里关于「为什么走 ctx.apiProxy 而不是 ctx.sessions」的长篇论证同样适用，
 * 不在这里重复。）
 *
 * ## 五样东西，三个来源
 *
 * | 要什么 | 从哪来 | 备注 |
 * |---|---|---|
 * | 面包屑（祖先链 + 标题） | `sessions.list` 的行 | `parentSessionId` / `origin` / `projections.values.title` |
 * | **子代理 catalog 树** | 同一份 `sessions.list` | 见下面「为什么不用 subagents.list」 |
 * | mode（agentPreset） | 同上的 `agentPreset` 字段 + `agentPresets.list` | 前者是"这个会话实际在跑什么"，后者是花名册 |
 * | jobs | `ctx.get("jobs")` | **可选服务**，缺席就是空列表 |
 * | 导出 | 不在这儿 | client 半边点网页那个真按钮，零重复实现（见 `client.js`） |
 *
 * ## 为什么 catalog 树不用 `subagents.list`
 *
 * 上游 `dsh-client-ui-subagent` 是逐层懒加载的——client 侧只拿得到
 * `subagents.list` 给的**直接** catalog，展开一层就往返一次，还得先铺一排
 * disabled loading 行。**node 半边没有这个限制**：`session.list` 的契约原话是
 * "v1 returns everything"，一次就把子代理行连同 `projections.values`
 * （`title` / `subagent` / `subagentTiming` / `tokenUsage`）一起给了。
 * 于是这里一次算好整棵树推上去，原生那边展开是纯本地操作、零往返。
 *
 * `subagents.list` 仍有一小块不可替代：`kind:"diagnostic"` 行
 * （corrupt / unsupported / unavailable）与 `parentAvailable`——坏掉的会话
 * 未必出现在 `session.list` 里。**眼下不取**：它是边缘情况，而为它挡住首帧
 * 会把"零往返"这个唯一的优势赔光。要补就后台补、别挡在渲染前面。
 *
 * **没有单会话 RPC**：`session.*` 域只有 `list`，所以拿一条会话的标题也得取全量。
 * clam-sidebar 也在取同一份，两个插件各取一次确实是重复的 I/O——缓解办法是
 * 本文件**只在焦点会话及其祖先相关的事件上重取**（`isWatched`），而不是任何
 * `session/event` 都重取。一轮 agent turn 能刷出上百条事件，绝大多数与
 * header 无关。
 *
 * ## 事件（node 侧 cordis 事件名 ≠ wire 帧名）
 *
 * | 我们订的 | 干什么 |
 * |---|---|
 * | `session/created` / `session/disposed` | 结构变了 → 重取 |
 * | `session/event` | **只在关注集合内**才重取（标题、blank 翻牌） |
 * | `agent/status` | 同上；running 不进 header，但 preset 的可改性跟着 blank 走 |
 * | `jobs.onJobsChanged` | 不是 cordis 事件，是 jobs 服务自己的回调 |
 *
 * @module clam-header/dsh-source
 */
import { randomUUID } from "node:crypto";

/**
 * 需要的宿主服务。`apiProxy` 一个就够——它自己 inject 了 sessions / agents /
 * agentPresets 等十来个，cordis 会替我们等齐。
 * `agents` 与 `jobs` 走 `ctx.get()` 探测：缺了只是 jobs 这一格空着，
 * 不该让面包屑和 mode 跟着消失。
 */
export const SOURCE_SERVICES = ["apiProxy"];

/** 结构类变化的合并窗口（毫秒）。比 clam-sidebar 的 400 长一点：header 只有一行，
 * 晚半拍没人看得出来，而每次重取都是一轮全量 `session.list`。 */
const REFETCH_DEBOUNCE_MS = 600;

/**
 * @param {object} ctx 已注入 `apiProxy` 的 cordis 上下文。
 * @param {{info:Function, warn:Function, error:Function}} log
 */
export function createHeaderSource(ctx, log) {
	/** sessionId → session.list 的行。 */
	let rows = new Map();
	/** agentPresets.list 的花名册。 */
	let roster = { presets: [], authorable: false };
	/** 焦点会话（浏览器 UI 状态，由 Swift 经 `focus` 动作告诉我们）。 */
	let focusId = null;
	/** 焦点会话 + 其祖先链的 id 集合。事件过滤用。 */
	let watched = new Set();

	let listeners = [];
	let timer;
	let disposed = false;
	let inFlight;

	const disposers = [
		ctx.on("session/created", () => scheduleRefetch()),
		ctx.on("session/disposed", () => scheduleRefetch()),
		ctx.on("session/event", (session) => {
			if (isWatched(session?.id)) scheduleRefetch();
		}),
		ctx.on("agent/status", ({ agent }) => {
			if (isWatched(agent?.id)) scheduleRefetch();
		}),
	];

	// jobs 是可选服务：没有就永远是空列表，header 上那一格不出现。
	const jobs = ctx.get?.("jobs");
	if (jobs?.onJobsChanged !== undefined) {
		try {
			disposers.push(jobs.onJobsChanged(() => emit(true)));
		} catch (error) {
			log.warn(`订阅 jobs 变化失败（header 不显示后台任务）：${errorText(error)}`);
		}
	}

	scheduleRefetch(true);

	return {
		onChange(listener) { listeners.push(listener); },

		/** 焦点会话变了（页面报上来的）。变了就立刻重投影，必要时重取。 */
		setFocus(sessionId) {
			const next = sessionId === null || sessionId === undefined
				? null : normalizeSessionId(sessionId);
			if (next === focusId) return;
			focusId = next;
			recomputeWatched();
			// 新焦点的行可能还没在缓存里（刚建的会话）——要一轮。
			if (focusId !== null && !rows.has(focusId)) scheduleRefetch(true);
			else emit(true);
		},

		projection,

		/**
		 * 换 agentPreset。**只有 blank 会话能换**（上游：一旦跑过 turn，
		 * 历史里的工具调用是在旧 composition 下产生的），非 blank 会得到
		 * `agent-preset-locked`，这里原样抛给上层弹一次。
		 */
		async selectPreset(sessionId, agentPreset) {
			await call("agentPresets", "select",
				{ sessionId: normalizeSessionId(sessionId), agentPreset }, "切换 agent preset");
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
	 * 焦点会话的 header 事实。没有焦点、或焦点那行还没取到 → null
	 * （Swift 那边据此把工具栏那几项收起来，而不是画一个半空的壳）。
	 */
	function projection() {
		if (focusId === null) return null;
		const row = rows.get(focusId);
		if (row === undefined) return null;
		const crumbs = ancestry(focusId);
		return {
			id: focusId,
			crumbs,
			preset: presetView(row),
			jobs: jobCounts(focusId),
			subagents: subagentTree(crumbs.length === 0 ? focusId : crumbs[0].id),
		};
	}

	/**
	 * 焦点所在的那棵 subagent 树，**一次投影给全**。
	 *
	 * 上游（`dsh-client-ui-subagent`）是逐层懒加载的：client 侧只拿得到
	 * `subagents.list` 给的*直接* catalog，所以展开一层就得往返一次、
	 * 还得先铺一排 disabled loading 行。**node 半边没有这个限制**——
	 * `session.list` 的契约原话是 "v1 returns everything"，一次就把子代理行
	 * 连同 `projections.values` 一起给了。于是这里把整棵树算好推上去，
	 * 原生那边展开是纯本地操作，零往返。
	 *
	 * 只投影**焦点这一棵**（从面包屑的根出发），不是全库所有 subagent：
	 * 别的树跟当前 header 没关系，投上去白占带宽。
	 *
	 * @param {string} rootId 面包屑第一段——subagent 链的根（它自己不是 subagent）。
	 */
	function subagentTree(rootId) {
		/** @type {Record<string, string[]>} */
		const byParent = {};
		/** @type {Record<string, object>} */
		const nodes = {};

		// 广度优先铺开，环靠 seen 挡住（数据坏了也不能死循环）。
		const seen = new Set([rootId]);
		let frontier = [rootId];
		while (frontier.length > 0) {
			const next = [];
			for (const parentId of frontier) {
				const children = childrenOf(parentId);
				if (children.length === 0) continue;
				byParent[parentId] = children.map((child) => child.id);
				for (const child of children) {
					if (seen.has(child.id)) continue;
					seen.add(child.id);
					nodes[child.id] = child.node;
					next.push(child.id);
				}
			}
			frontier = next;
		}

		if (Object.keys(nodes).length === 0) return null;
		// 根不在 nodes 里（它自己不是 subagent），它的原始 id 单独带上——
		// 它正是 `subagents.list` 要的 parentSessionId。
		const rootRow = rows.get(rootId);
		const rootRaw = typeof rootRow?.sessionId === "string" ? rootRow.sessionId : rootId;
		return { root: rootId, rootRaw, byParent, nodes, descendants: indexDescendants(nodes) };
	}

	/** 一个会话的直接子代理行，按 updatedAt 升序（建立顺序，稳定）。 */
	function childrenOf(parentId) {
		const out = [];
		for (const [id, row] of rows) {
			if (id === parentId) continue;
			if (!isSubagent(row)) continue;
			const parent = row.parentSessionId === undefined
				? undefined : normalizeSessionId(row.parentSessionId);
			if (parent !== parentId) continue;
			out.push({ id, node: nodeOf(id, row) });
		}
		out.sort((a, b) => a.node.updatedAt - b.node.updatedAt);
		return out;
	}

	/**
	 * catalog 一行的全部事实。
	 *
	 * `mode` / `label` 来自 `subagent` 这条 projection（`dsh-subagent` 登记的），
	 * 而不是 `subagents.list`——两者是同一份 descriptor 折出来的。
	 * **时长不在这里算成一个数**：给的是 `settledMs` / `activeSince` /
	 * `activeThrough` / `running` 四个原始值，让 Swift 侧自己用本地 timer 推进。
	 * 每秒重投一整棵树是不可接受的。
	 */
	function nodeOf(id, row) {
		const values = row.projections?.values ?? {};
		const identity = values.subagent;
		const timing = values.subagentTiming;
		const mode = identity?.mode === "one-shot" || identity?.mode === "continuable"
			? identity.mode : null;
		const label = typeof identity?.label === "string" && identity.label !== ""
			? identity.label : null;
		return {
			id,
			// **上游认的那个 id**，未经归一化。
			//
			// 实测（对着活服务问了一次 `subagents.list`）：
			// ```
			// parentSessionId="session-08bc0cb8-…" → parentAvailable=true／2 条
			//     9aa7efb5-…(continuable)  dd23d54e-…(continuable)
			// parentSessionId="08bc0cb8-…"         → parentAvailable=false／0 条
			// ```
			// **同一个 RPC 两端形态不同**：parent 必须带 `session-` 前缀，
			// 而它 catalog 里回的 child 是光 uuid。归一化后的 `id` 只配当本地
			// 的键，发给 `openSubagent` 必须用这个原始的
			// ——否则一律 `is not a healthy catalog child`。
			rawId: typeof row.sessionId === "string" ? row.sessionId : id,
			title: titleOf(row),
			// 上游优先用 descriptor 的 label 覆盖 session-summary 标题
			// （"a catalog label overrides the session-summary title"）。
			label,
			mode,
			running: row.running === true,
			updatedAt: Number(row.updatedAt ?? 0),
			tokens: tokenTotal(values.tokenUsage),
			settledMs: Number(timing?.settledMs ?? 0),
			activeSince: typeof timing?.active?.since === "number" ? timing.active.since : null,
			activeThrough: typeof timing?.active?.through === "number" ? timing.active.through : null,
		};
	}

	/**
	 * 后代计数，复刻上游的 `indexSubagentDescendants`
	 * （`dsh-client-runtime/lib/client.js`，导出的纯函数）：每个后代给**沿途
	 * 每一个祖先**各记一笔，沿 parentId 上溯**遇非 subagent 即止**。
	 * 所以根会话拿到的是"完整的 subagent-only 后代链"总数，而不只是直接子代。
	 */
	function indexDescendants(nodes) {
		/** @type {Record<string, {count:number, runningCount:number}>} */
		const indexed = {};
		for (const descendant of Object.values(nodes)) {
			const seen = new Set();
			let cursor = descendant;
			while (cursor !== undefined && !seen.has(cursor.id)) {
				seen.add(cursor.id);
				const row = rows.get(cursor.id);
				const parentRaw = row?.parentSessionId;
				if (parentRaw === undefined) break;
				const parentId = normalizeSessionId(parentRaw);
				const aggregate = indexed[parentId];
				if (aggregate === undefined) {
					indexed[parentId] = { count: 1, runningCount: descendant.running ? 1 : 0 };
				} else {
					aggregate.count += 1;
					if (descendant.running) aggregate.runningCount += 1;
				}
				cursor = nodes[parentId];
			}
		}
		return indexed;
	}

	/** 四个**不相交**的 durable provider usage 桶求和（上游 `tokenTotal` 逐字复刻）。 */
	function tokenTotal(usage) {
		if (usage === undefined || usage === null) return null;
		const sum = Number(usage.uncachedInputTokens ?? 0) + Number(usage.outputTokens ?? 0)
			+ Number(usage.cacheReadTokens ?? 0) + Number(usage.cacheWriteTokens ?? 0);
		return Number.isFinite(sum) ? sum : null;
	}

	/**
	 * 祖先链，根在前。复刻 ui-conversation 的 `deriveAncestry`
	 * （`dsh-client-ui-conversation/lib/client.js:7291`）：沿 `parentSessionId`
	 * 上溯，**遇到非 subagent 就停**——那是这条链的根，再往上是 fork 关系，
	 * 不属于同一次对话的层级。
	 *
	 * `title` 为 null 时不在这里编一个：显示层的 fallback（"未命名会话"还是
	 * 显示 id）是 UI 政策，归 Swift。
	 */
	function ancestry(id) {
		const chain = [];
		const seen = new Set();
		let cursor = id;
		while (cursor !== undefined && cursor !== null) {
			if (seen.has(cursor)) break; // 环：数据坏了也不能死循环
			seen.add(cursor);
			const row = rows.get(cursor);
			if (row === undefined) break;
			const subagent = isSubagent(row);
			chain.unshift({ id: cursor, title: titleOf(row), subagent });
			if (!subagent) break;
			cursor = row.parentSessionId === undefined
				? undefined : normalizeSessionId(row.parentSessionId);
		}
		return chain;
	}

	/**
	 * mode 那一格。`current` 是**这个会话实际在跑的** composition，不是部署
	 * 当前的默认值——上游专门为此在 SessionSummary 上留了 `agentPreset`。
	 * `locked` 跟着 blank 走（见 `selectPreset`）。
	 * 花名册为空 = 该部署根本不编排 preset，整格不出现。
	 */
	function presetView(row) {
		const options = roster.presets
			.filter((preset) => typeof preset?.id === "string" && preset.id !== "")
			.map((preset) => ({
				id: preset.id,
				// 上游：`name` 缺席时退回 id，且 name 永远不是第二身份。
				label: typeof preset.name === "string" && preset.name !== "" ? preset.name : preset.id,
				// 坏掉的 preset 仍然列出（它占着这个 id），但不该被选中。
				broken: typeof preset.broken === "string" && preset.broken !== "",
			}));
		if (options.length === 0) return null;
		return {
			current: typeof row.agentPreset === "string" ? row.agentPreset : null,
			options,
			locked: row.blank !== true,
		};
	}

	/**
	 * 这个会话的后台任务，**只给两个数字**。
	 *
	 * 上游 ui-jobs 自己也只给看不给停，所以这一格退进了 `window.subtitle`，
	 * 消费方只数 running/total。别再把 apiproxy 的 `jobViews` 整份复刻过来——
	 * 投了没人读的字段就是死数据。
	 */
	function jobCounts(id) {
		if (jobs?.list === undefined) return { count: 0, running: 0 };
		try {
			const agents = ctx.get?.("agents");
			const agent = agents?.get?.(bareSessionId(id)) ?? agents?.get?.(id);
			if (agent === undefined) return { count: 0, running: 0 };
			const list = jobs.list(agent) ?? [];
			return {
				count: list.length,
				running: list.filter((job) => String(job.status ?? "") === "running").length,
			};
		} catch (error) {
			log.warn(`读取 jobs 失败（这一格留空）：${errorText(error)}`);
			return { count: 0, running: 0 };
		}
	}

	function titleOf(row) {
		const title = row.projections?.values?.title;
		return typeof title === "string" && title !== "" ? title : null;
	}

	/** wire 上 subagent 行带 `origin:"subagent"`；`parentSessionId` 在场也算
	 * （与 clam-sidebar 的判据一致，宁可多认不可漏认）。 */
	function isSubagent(row) {
		return row.origin === "subagent" || typeof row.parentSessionId === "string";
	}

	// ---------------------------------------------------------------- 事件过滤

	/**
	 * 焦点会话 + 祖先链 + **整棵 subagent 树**。
	 *
	 * 祖先在面包屑上、后代在 catalog 里，两边的标题与 running 都要跟得上
	 * （计数触发器要在"任一被计数的后代在跑"时亮活动指示）。收窄的意义仍在：
	 * 一轮 agent turn 刷上百条事件，绝大多数属于**别的**树。
	 */
	function recomputeWatched() {
		watched = new Set();
		if (focusId === null) return;
		watched.add(focusId);
		const chain = ancestry(focusId);
		for (const crumb of chain) watched.add(crumb.id);
		const tree = subagentTree(chain.length === 0 ? focusId : chain[0].id);
		if (tree !== null) for (const id of Object.keys(tree.nodes)) watched.add(id);
	}

	function isWatched(rawId) {
		if (rawId === undefined || rawId === null) return false;
		// 焦点还没定下来时一律放行：开局那几条事件正是"列表该有内容了"的信号。
		if (focusId === null) return true;
		return watched.has(normalizeSessionId(rawId));
	}

	// ---------------------------------------------------------------- 取数

	function scheduleRefetch(immediate = false) {
		if (disposed) return;
		clearTimeout(timer);
		if (immediate) { void refetch(); return; }
		timer = setTimeout(() => void refetch(), REFETCH_DEBOUNCE_MS);
		timer.unref?.();
	}

	/** 一轮全量。并发调用合并成一次（后来者等着前一次的结果）。 */
	function refetch() {
		if (inFlight !== undefined) return inFlight;
		inFlight = (async () => {
			try {
				const [sessions, presets] = await Promise.all([
					call("sessions", "list", {}, "拉取会话列表"),
					// 花名册几乎不变，但它便宜（读几个目录），跟着一起取省一条时序。
					call("agentPresets", "list", {}, "拉取 agent preset 名单")
						.catch((error) => {
							// 部署没有 preset 根本不是错——但真出错时也不该让整个
							// header 消失，退化成"没有 mode 这一格"。
							log.warn(`拉取 agent preset 名单失败（mode 一格不出现）：${errorText(error)}`);
							return { presets: [] };
						}),
				]);
				if (disposed) return;
				rows = new Map((sessions?.items ?? [])
					.filter((row) => typeof row?.sessionId === "string" && row.sessionId !== "")
					.map((row) => [normalizeSessionId(row.sessionId), { ...row }]));
				roster = { presets: presets?.presets ?? [], authorable: presets?.authorable === true };
				recomputeWatched();
				emit(false);
			} catch (error) {
				// **读失败不抬到用户面前**：header 保持上一份，下一个事件自然会再试。
				// 写操作失败才值得弹窗（那是用户刚点过的东西）。
				log.warn(`刷新 header 失败（保留上一份）：${errorText(error)}`);
			} finally {
				inFlight = undefined;
			}
		})();
		return inFlight;
	}

	function emit(immediate) {
		if (disposed) return;
		for (const listener of listeners) {
			try { listener(immediate); } catch (error) {
				log.warn(`header 订阅者抛错：${errorText(error)}`);
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
 * 上游的 session id 规范形是 `session-<uuid>`，但 subagent 行在 `session.list`
 * 里可能是**光的 uuid**（clam-sidebar 那边对着活服务点过）。两边都归一化。
 */
function normalizeSessionId(raw) {
	const id = String(raw);
	return id.startsWith("session-") ? id : `session-${id}`;
}

/** 反向：`ctx.agents` 用的是光 id。 */
function bareSessionId(raw) {
	const id = String(raw);
	return id.startsWith("session-") ? id.slice("session-".length) : id;
}

function errorText(error) {
	return error instanceof Error ? error.message : String(error);
}
