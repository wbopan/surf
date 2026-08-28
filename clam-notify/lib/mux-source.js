/**
 * 事件源 —— 本插件与 dsh 内部 API 唯一接触的地方。
 *
 * **dsh 升级后先核对这一个文件。** 帧型、方法签名、回答形状的所有假设都写在这里，
 * 别的文件一处不碰 dsh。
 *
 * ## 为什么是 `ctx.apiProxy.events.mux()` 而不是 cordis 事件
 *
 * 待批准（`approval/requested`）与待回答（`question/requested`）**在 node 侧没有
 * cordis 事件可订**：
 *
 * - `approval/request` 是个 waterfall 抢答钩子，插一脚进去会和 apiproxy 抢着回答
 *   用户的审批（`clam-sidebar/lib/dsh-source.js` 已经踩过这条线，别再踩）。
 *   session log 里那两条 `approval/asked｜decided` 是**审计事件**，只说"问过了"，
 *   不给你回答用的钥匙。
 * - `ask_user_question` 更彻底：既不发 cordis 事件、也不落 session log，唯一的
 *   观察位 `userQuestions.registerProvider` 是**独占**的，apiproxy 占着——抢过来
 *   等于把 web UI 的问答面板掐了。
 *
 * `events.mux()` 是**进程内 async iterable**（`ApiProxyService`，零网络，
 * HTTP 那条 `/api/events.mux` 只是它的搬运工），而且：
 *
 * 1. **是广播**：`muxQueues` 是个 Set，每帧推给每个订阅者。多订一条不会让 web UI
 *    少收一帧，我们只是"多开的一个客户端"。
 * 2. **开流时重放所有仍 pending 的 requested 帧，rpcId 逐字复用**。所以插件重挂载、
 *    dsh 重启、app 重连之后待办不会丢——重新订一次就全回来了，**我们自己一行
 *    重放逻辑都不需要写**。
 *
 * ## 回答：`ctx.apiProxy.respond()`
 *
 * 钥匙是**信封上的 `rpcId`**（不是 payload 里的 `approvalId`——那个只是审计相关性，
 * 校验时要一起带上，但不是路由用的）。实现是**先到先得**：命中进程内的 pending 表
 * 就 settle 并删除，晚到的一方拿到 `{accepted:false, reason:"not-pending"}`。
 * 这不是错误，是正常结局——意味着"通知上点了允许"和"网页里点了允许"天然不打架，
 * 先点的赢。我们据此把通知撤下即可。
 *
 * @module clam-notify/mux-source
 */
import { randomUUID } from "node:crypto";

/**
 * 需要的宿主服务。`apiProxy` 一个就够（它自己 inject 了 sessions / agents /
 * userQuestions 等十来个，cordis 会替我们等齐）。
 */
export const SOURCE_SERVICES = ["apiProxy"];

/** 会话标题重取的合并窗口。标题变动不急，压得比 sidebar 的 400ms 更狠。 */
const TITLE_REFETCH_DEBOUNCE_MS = 600;

/**
 * @param {object} ctx 已注入 `apiProxy` 的 cordis 上下文。
 * @param {{info:Function, warn:Function, error:Function}} log
 * @param {object} sink 事件出口（由 inbox 实现）。
 * @param {(e:{kind:string, id:string, rpcId:string, sessionId:string, data:object}) => void} sink.onPending
 * @param {(e:{id:string, outcome:string}) => void} sink.onResolved
 * @param {(e:{sessionId:string}) => void} sink.onTurnEnd
 * @param {(e:{sessionId:string, message:string}) => void} sink.onAgentError
 * @param {(e:{sessionId:string, running:boolean}) => void} sink.onRunning
 * @param {() => void} sink.onTitles
 */
export function createMuxSource(ctx, log, sink) {
	const abort = new AbortController();
	/** sessionId → 标题（`session.list` 打底，`session/projection` 增量维护）。 */
	const titles = new Map();
	let titleTimer;
	let titleInFlight;
	let disposed = false;

	void pump("mux", (signal) => ctx.apiProxy.events.mux(request({}), signal), onMuxFrame);
	// host 流只为 `host/agent-error` 一条：它是**唯一**没有 cordis 等价物的信号
	// （`agent/status` 在 dsh-agent 里有，我们用不着从这儿拿）。
	void pump("host", (signal) => ctx.apiProxy.events.host(request({}), signal), onHostFrame);
	scheduleTitles(true);

	return {
		/** 会话标题；没取到就是 undefined（显示层自己退到短 id）。 */
		titleOf(sessionId) {
			const title = titles.get(sessionId);
			return typeof title === "string" && title !== "" ? title : undefined;
		},

		/**
		 * 回答一条 requested。**`rpcId` 逐字回抄**，别自己造。
		 * @returns {Promise<{accepted:boolean, reason?:string}>} 回执。
		 *   `accepted:false, reason:"not-pending"` = 别人先答了，不是错误。
		 */
		async respond(rpcId, result) {
			try {
				const receipt = await ctx.apiProxy.respond({
					type: "client-response",
					rpcId,
					result,
				});
				return receipt ?? { accepted: false, reason: "bad-response" };
			} catch (error) {
				log.warn(`回答 ${rpcId} 失败：${error?.message ?? error}`);
				return { accepted: false, reason: "transport" };
			}
		},

		dispose() {
			disposed = true;
			clearTimeout(titleTimer);
			abort.abort();
		},
	};

	// ---------------------------------------------------------------- 帧流

	/** 信封：`rpcId` 只是个被原样回显的字符串，随便给个 uuid。 */
	function request(payload) {
		return { rpcId: randomUUID(), payload };
	}

	/**
	 * 跑一条流直到 dispose。
	 *
	 * **进程内的流不会"断线"**（没有网络），所以这里没有指数退避重连——它要么跑到
	 * 我们自己 abort，要么是上游出了真问题，那种情况重连也没用，记一行日志更诚实。
	 * 唯一的例外是 dsh 内部把流关了（服务重载），此时重开一次是对的：**重开的代价
	 * 恰好是零**，因为 mux 会把 pending 全部重放回来。
	 */
	async function pump(name, open, handle) {
		let restarts = 0;
		while (!disposed) {
			try {
				for await (const envelope of open(abort.signal)) {
					if (disposed) return;
					try {
						handle(envelope);
					} catch (error) {
						// 一帧解不动不该掀翻整条流。
						log.warn(`${name} 帧处理失败：${error?.message ?? error}`);
					}
				}
			} catch (error) {
				if (disposed || abort.signal.aborted) return;
				log.warn(`${name} 流中断：${error?.message ?? error}`);
			}
			if (disposed) return;
			restarts += 1;
			if (restarts > 5) {
				log.error(`${name} 流反复中断（${restarts} 次），放弃重开——通知线从此静默，`
					+ "重启 dsh 可恢复。");
				return;
			}
			await sleep(500 * restarts);
		}
	}

	function onMuxFrame(envelope) {
		const frame = envelope.payload;
		const rpcId = envelope.rpcId;
		switch (frame?.type) {
			case "approval/requested":
				sink.onPending({
					kind: "approval",
					id: `approval.${rpcId}`,
					rpcId,
					sessionId: frame.sessionId,
					data: {
						approvalId: frame.approvalId,
						toolName: frame.toolName,
						callId: frame.callId,
						reason: frame.reason,
					},
				});
				return;

			case "approval/resolved":
				// 帧上没有 rpcId（它是纯 push），只有 approvalId——所以 inbox 那边
				// 按 (sessionId, approvalId) 反查自己那条。
				sink.onResolved({
					match: { sessionId: frame.sessionId, approvalId: frame.approvalId },
					outcome: frame.outcome,
				});
				return;

			case "question/requested":
				sink.onPending({
					kind: "question",
					id: `question.${rpcId}`,
					rpcId,
					sessionId: frame.sessionId,
					data: { questions: frame.questions ?? [] },
				});
				return;

			case "question/resolved":
				// 这条**带 rpcId**（`questionRpcId`），直接按 id 命中。
				sink.onResolved({
					match: { id: `question.${frame.questionRpcId}` },
					outcome: frame.outcome,
				});
				return;

			case "session/projection":
				if (frame.key === "title" && typeof frame.value === "string") {
					titles.set(frame.sessionId, frame.value);
					sink.onTitles();
				}
				return;

			case "session/event":
				// 回合结束。**不在这里判"要不要通知"**——那是 Swift 侧的事（它才知道
				// 用户此刻在看什么）。这里只说"发生了"。
				if (frame.event?.type === "turn/end") {
					sink.onTurnEnd({ sessionId: frame.sessionId });
				}
				return;

			default:
				// 其余帧（session/subscribed、session/queue、session/jobs、
				// stream/error…）与通知无关，忽略。协议向前兼容：新帧型不认得就不认得。
				return;
		}
	}

	function onHostFrame(envelope) {
		const frame = envelope.payload;
		switch (frame?.type) {
			case "host/agent-error":
				sink.onAgentError({
					sessionId: frame.sessionId,
					message: String(frame.message ?? "未知错误"),
				});
				return;
			case "host/session-status":
				sink.onRunning({ sessionId: frame.sessionId, running: frame.running === true });
				return;
			case "host/session-added":
			case "host/session-removed":
				scheduleTitles();
				return;
			default:
				return;
		}
	}

	// ---------------------------------------------------------------- 标题

	/**
	 * 标题打底。`session/projection` 帧只在**变化时**推，开流时不给基线
	 * （基线在 history tail 的 projections block 里，取它要一次文件尾读），
	 * 所以这里用一次 `session.list` 打底——它本来就带 projections。
	 */
	function scheduleTitles(immediate = false) {
		if (disposed) return;
		clearTimeout(titleTimer);
		if (immediate) {
			void refetchTitles();
			return;
		}
		titleTimer = setTimeout(() => void refetchTitles(), TITLE_REFETCH_DEBOUNCE_MS);
		titleTimer.unref?.();
	}

	function refetchTitles() {
		if (titleInFlight !== undefined) return titleInFlight;
		titleInFlight = (async () => {
			try {
				const value = await unwrap(ctx.apiProxy.sessions.list(request({})), "拉取会话列表");
				if (disposed) return;
				let changed = false;
				for (const row of value?.items ?? []) {
					const id = row?.sessionId;
					const title = row?.projections?.values?.title;
					if (typeof id !== "string" || typeof title !== "string" || title === "") continue;
					if (titles.get(id) !== title) {
						titles.set(id, title);
						changed = true;
					}
				}
				if (changed) sink.onTitles();
			} catch (error) {
				log.warn(`标题打底失败：${error?.message ?? error}`);
			} finally {
				titleInFlight = undefined;
			}
		})();
		return titleInFlight;
	}

	/** `{result:{ok,value|error}}` → value，失败即抛。 */
	async function unwrap(promise, what) {
		const response = await promise;
		const result = response?.result;
		if (result?.ok === true) return result.value;
		const error = result?.error;
		throw new Error(`${what}：${error?.code ?? "unknown"} ${error?.message ?? ""}`.trim());
	}
}

function sleep(ms) {
	return new Promise((resolve) => {
		const timer = setTimeout(resolve, ms);
		timer.unref?.();
	});
}
