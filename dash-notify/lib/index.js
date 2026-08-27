/**
 * dash-notify —— 可交互桌面通知（计划 `docs/dash-notify-plan.md`）。
 *
 * 把 dsh 里「需要人」的四件事变成 macOS 原生通知：点一下跳到那个会话，
 * 通知上的按钮**直接把它办了**，人在 app 里看到之后通知自己消失。
 *
 * ## 分层（不变量，别越界）
 *
 * - **node 说「发生了什么」**：订 `apiProxy` 的帧流、组待办、把用户的决定
 *   原路答回 dsh。所有 wire 知识都在 `mux-source.js` 一个文件里。
 * - **Swift 决定「要不要打扰」**：只有 app 进程知道用户此刻在看哪个会话、
 *   窗口是不是 key、有没有被盖住。旧实现（已废弃的 `EventsBridge.swift`）
 *   把策略放在壳里但只有 `NSApp.isActive` 一个输入，于是「你盯着 A 会话时
 *   B 会话要审批」这个最常见的场景一条通知都收不到。层没错，输入太少。
 *
 * ## 桥协议
 *
 * 下行（`push(channel, payload)`）：
 *
 * | 频道 | 载荷 | 什么时候 |
 * |---|---|---|
 * | `inbox` | `{version, items:[…], settings:{…}}` | 待办集合或设置变化时（去抖 30ms），以及被 `inbox` 动作请求时 |
 * | `error` | `{action, message}` | 任一上行动作失败 |
 *
 * item 的字段见 `inbox.js`。**Swift 不解释任何字段**——`title`/`body`/`actions`
 * 都是 node 组好的，那边收到什么画什么。加一类通知 = 改 node，Swift 不动。
 *
 * 上行（Swift `bridge.send(action:payload:)`，一律 fire-and-forget）：
 *
 * | 动作 | 载荷 | node 做什么 |
 * |---|---|---|
 * | `inbox` | `{}` | 全量重推（每代 activate 时问一次，桥不给新世代补发） |
 * | `act` | `{id, actionId, text?}` | 翻成 `respond()` 答回 dsh |
 * | `dismiss` | `{id}` | 从待办里划掉（不回答 dsh，只是不想看见） |
 * | `dismissAll` | `{}` | 同上，批量（**待办不会被抹掉**，见 inbox.js） |
 * | `focus` | `{sessionId}` | 用户此刻在看这个会话——清掉它的「回合结束」「出错」 |
 *
 * `open`（打开查看）不上行：跳转是纯 Swift 侧动作，走 `DashConversationSurface`。
 *
 * @module dash-notify
 */
import z from "@deepseek-ai/schemastery";
import { createSwiftPlugin } from "../../dash-bridge/lib/plugin.js";
import { createInbox } from "./inbox.js";
import { SOURCE_SERVICES, createMuxSource } from "./mux-source.js";

/** 桥这一侧的合并窗口。挡的是"同一拍里几条帧都说变了"。 */
const COALESCE_MS = 30;

/**
 * 本插件与 Swift 半身之间数据形状的版本。**改了 item 字段就 +1**——它折进
 * contentHash，Swift 那半边会被强制重编，不会出现新 node 配旧 Swift 的认知分裂。
 */
const SCHEMA_VERSION = 1;

/**
 * `dashPending` 里原因的重要性次序（越靠前越该管）。
 *
 * 「等你批准」「等你回答」是**欠着的事**，不办就卡在那儿；「出错」「跑完了」
 * 是**已经发生的事**，看一眼就过去了——所以前两者永远排在前面。
 */
const PENDING_ORDER = ["approval", "question", "error", "done"];

/** 设置命名空间。注册一次同时点亮 dash-settings 的原生窗口与 dsh 页内设置对话框。 */
const SETTINGS_NS = "dash-notify";

/** 设置缺席时的取值（`settings` 服务不在也要能正常发通知）。 */
const SETTINGS_DEFAULTS = {
	enabled: true,
	approval: true,
	question: true,
	done: true,
	error: true,
	actionableApproval: true,
	sound: true,
	doneWhenForeground: false,
	badgeIncludesDone: false,
};

const ACTIONS = ["inbox", "act", "dismiss", "dismissAll", "focus"];

/** 插件实例 → 动作实现（照 dash-sidebar：`expose` 表在模块求值时就要定好）。 */
const RUNTIME = new WeakMap();

export default createSwiftPlugin({
	name: "dash-notify",
	provide: "dash-notify",
	inject: ["dash-layout"],
	swiftDir: new URL("../swift/", import.meta.url),
	swiftDeps: ["dash-layout"],
	schemaVersion: SCHEMA_VERSION,

	subscribe: (api) => {
		const { ctx, push } = api;
		const log = reporter(ctx.logger("dash-notify"));
		let version = 0;
		let timer;
		/** `dashPending` 的订阅者（跨插件，见下面 provide 那段）。 */
		const watchers = new Set();
		/** 当前设置。`settings` 服务缺席时永远是这一份默认值。 */
		let settings = { ...SETTINGS_DEFAULTS };
		/** @type {ReturnType<typeof createInbox>|undefined} */
		let inbox;
		/** @type {ReturnType<typeof createMuxSource>|undefined} */
		let source;

		// ---- 供出去的一笔：`dashPending` ----
		//
		// 侧边栏那枚「待处理」胶囊要列的东西，跟通知要说的是同一件事：
		// **有什么在等着你**。真相只该有一份，所以由这里供出去，而不是让侧边栏
		// 自己再订一遍 mux 推一遍状态机（那样两份实现迟早分叉，而且 approval 那份
		// 它已经有了、question/done/error 那三份它推不出来）。
		//
		// 服务名里没有 "notify" 二字是故意的：它表达的是"有事等着你"这个事实，
		// 通知只是这个事实的一个消费者。消费方一律走**运行时嵌套 inject**
		// ——dash-notify 缺席时侧边栏退回自己那份 approval-only，不能不挂载。
		ctx.provide("dashPending", {
			/**
			 * `sessionId` → 原因数组，**按重要性排好序**（第一个最该管）。
			 * 优先级只定义在这一处，消费方取 `[0]` 就是"该画哪个指示器"。
			 * 数据面没就绪时返回空对象，而不是抛错。
			 */
			snapshot() {
				const out = {};
				for (const item of inbox?.pending() ?? []) {
					(out[item.sessionId] ??= []).push(item.kind);
				}
				for (const reasons of Object.values(out)) {
					reasons.sort((a, b) => PENDING_ORDER.indexOf(a) - PENDING_ORDER.indexOf(b));
				}
				return out;
			},
			/** 变了就叫一声（无参）。返回退订函数。 */
			subscribe(callback) {
				if (typeof callback !== "function") return () => {};
				watchers.add(callback);
				return () => watchers.delete(callback);
			},
		});

		// 设置走**运行时嵌套 inject**，不写进插件顶层的 `inject`：写上去就是硬依赖，
		// dsh 哪天没挂 settings 会让整条通知线安静地不挂载。缺席时退到默认值，
		// 其余一切照旧（与 dash-nativeify 同一条纪律）。
		ctx.inject(["settings"], (scoped) => {
			const scope = scoped.settings.register(SETTINGS_NS, z.object({
				enabled: z.boolean().default(true)
					.description("关掉之后一条系统通知都不发。侧边栏那枚「待处理」胶囊不受影响"
						+ "——关的是打扰，不是事实。"),
				approval: z.boolean().default(true)
					.description("需要批准工具执行时通知。"),
				question: z.boolean().default(true)
					.description("Agent 提问时通知。"),
				done: z.boolean().default(true)
					.description("一个回合跑完时通知。"),
				error: z.boolean().default(true)
					.description("Agent 出错时通知。"),
				actionableApproval: z.boolean().default(true)
					.description("允许直接在通知上点「允许一次」。关掉之后通知上只剩「拒绝」与「打开查看」，"
						+ "放行必须进 app 看清上下文再点。"),
				sound: z.boolean().default(true)
					.description("通知带提示音。"),
				doneWhenForeground: z.boolean().default(false)
					.description("app 在前台（但你正看着别的会话）时也报「回合结束」。"
						+ "待批准/待回答不受这一项影响——那两类任何时候都会通知。"),
				badgeIncludesDone: z.boolean().default(false)
					.description("Dock 角标把未读的「回合结束」「出错」也算进去（默认只数待批准与待回答）。"),
			}), {
				// 改完立刻生效：node 侧订着这个 ns，值一变就把新的一份随 inbox 推下去。
				applies: "live",
			});
			settings = { ...SETTINGS_DEFAULTS, ...(scope.get() ?? {}) };
			scoped.effect(() => scope.watch((next) => {
				settings = { ...SETTINGS_DEFAULTS, ...(next ?? {}) };
				inbox?.refresh();
				schedulePush(true);
			}), "dash-notify 设置订阅");
		});

		// 宿主服务同样走作用域 inject：最坏情况是一条通知都没有 + 终端一行 warn，
		// 而不是整个插件（连同 Swift 半身）安静地不挂载。
		ctx.inject(SOURCE_SERVICES, (inner) => {
			inbox = createInbox(
				{ titleOf: (id) => source?.titleOf(id) },
				() => settings,
				() => schedulePush(),
			);
			source = createMuxSource(inner, log, {
				onPending: (event) => inbox.onPending(event),
				onResolved: (event) => inbox.onResolved(event),
				onTurnEnd: (event) => inbox.onTurnEnd(event),
				onAgentError: (event) => inbox.onAgentError(event),
				onRunning: (event) => inbox.onRunning(event),
				onTitles: () => inbox.onTitles(),
			});
			RUNTIME.set(api, buildActions());

			log.info(`数据面就绪（宿主服务 ${SOURCE_SERVICES.join(" / ")}）`);
			// 就绪即推一份：此刻壳可能早就连上、也早就问过 inbox 了。
			schedulePush(true);

			inner.effect(() => () => {
				RUNTIME.delete(api);
				clearTimeout(timer);
				source?.dispose();
				source = undefined;
				inbox = undefined;
			}, "dash-notify 事件源");
		});

		// 开发用的自测钩子：`DASH_NOTIFY_SELFTEST=1 ./dev` 会在挂载 3 秒后塞两条
		// 假待办（一条审批、一条单选提问）。**为什么值得留着**：验证通知链路
		// （外观、按钮、点击跳转、撤下、角标、前台策略）本来要先真去触发一次
		// 工具审批，那是分钟级的往返；假待办把这一圈压到三秒。
		// 假的 rpcId 在 `act` 时会被上游判成 `not-pending`——那条路径同样是真的
		// （别人先答了就是这个结局），所以连"答完之后怎么收场"都一起验了。
		if (process.env.DASH_NOTIFY_SELFTEST === "1") {
			const timer = setTimeout(() => {
				log.warn("自测：塞两条假待办（DASH_NOTIFY_SELFTEST=1）");
				const sessionId = "session-selftest";
				inbox?.onPending({
					kind: "approval", id: "approval.selftest", rpcId: "selftest-approval",
					sessionId,
					data: { approvalId: "selftest", toolName: "bash", reason: "rm -rf build" },
				});
				inbox?.onPending({
					kind: "question", id: "question.selftest", rpcId: "selftest-question",
					sessionId,
					data: { questions: [{
						id: "q1", question: "这次改动要不要顺便把 README 也更新了？",
						options: [{ label: "更新" }, { label: "先不用" }],
					}] },
				});
			}, 3000);
			timer.unref?.();
			ctx.effect(() => () => clearTimeout(timer), "dash-notify 自测钩子");
		}

		// 服务名对不上时不会有任何异常，只是回调永远不跑——主动查一次哨。
		const sentinel = setTimeout(() => {
			if (RUNTIME.has(api)) return;
			log.warn(`等不到宿主服务 ${SOURCE_SERVICES.join(" / ")}，`
				+ "通知线静默（dsh 版本变动改了服务名？核对 lib/mux-source.js）");
		}, 10_000);
		sentinel.unref?.();
		ctx.effect(() => () => clearTimeout(sentinel), "dash-notify 数据面守望");

		function buildActions() {
			return {
				inbox: () => pushInbox(),

				/**
				 * 用户在通知上按了一个按钮。
				 *
				 * **这是本插件唯一一处把 UI 动作翻成 wire 的地方**，翻译表就在下面。
				 * 回执不是布尔：`not-pending` 意味着别人先答了（先到先得，见
				 * `mux-source.js`），那不是失败——把它当成"已办"照样翻牌就对了。
				 */
				act: async ({ id, actionId, text }) => {
					const item = inbox?.keyOf(String(id));
					if (item === undefined) {
						// 已经被别处办掉了。Swift 那边把通知撤下即可，不用报错。
						log.info(`动作 ${actionId} 落空：${id} 已不在待办里`);
						schedulePush(true);
						return;
					}
					const result = translate(item, String(actionId), text);
					if (result === undefined) {
						throw new Error(`不认得的动作 ${actionId}（${item.kind}）`);
					}
					const receipt = await source.respond(item.rpcId, result);
					if (receipt.accepted !== true && receipt.reason !== "not-pending") {
						throw new Error(`dsh 拒绝了这次回答：${receipt.reason}`);
					}
					// 乐观翻牌：`approval/resolved` / `question/resolved` 随后也会到，
					// 那时 inbox 已经是 resolved，第二次是幂等的空转。
					inbox.onResolved({
						match: { id: item.id },
						outcome: receipt.accepted === true ? actionId : "superseded",
					});
				},

				dismiss: ({ id }) => inbox?.dismiss(String(id)),
				dismissAll: () => inbox?.dismissAll(),
				focus: ({ sessionId }) => inbox?.onFocus(String(sessionId ?? "")),
			};
		}

		function schedulePush(immediate = false) {
			clearTimeout(timer);
			if (immediate) {
				pushInbox();
				return;
			}
			timer = setTimeout(() => pushInbox(), COALESCE_MS);
			timer.unref?.();
		}

		function pushInbox() {
			version += 1;
			push("inbox", {
				version,
				items: inbox?.list() ?? [],
				settings,
			});
			// 同一拍里叫醒 `dashPending` 的订阅者。一个订阅者抛错不该带塌别人，
			// 更不该带塌通知线本身。
			for (const watcher of watchers) {
				try {
					watcher();
				} catch (error) {
					log.warn(`dashPending 订阅者抛错：${errorText(error)}`);
				}
			}
		}
	},

	// `expose` 的返回值桥不看（invoke 是单向帧），失败只能自己经 error 频道报回去
	// ——原生那边没有控制台，静默失败等于骗人。
	expose: Object.fromEntries(ACTIONS.map((action) => [action, async (payload, api) => {
		const handler = RUNTIME.get(api)?.[action];
		if (handler === undefined) {
			api.push("error", { action, message: "通知数据面尚未就绪" });
			return;
		}
		try {
			await handler(payload ?? {});
		} catch (error) {
			const message = errorText(error);
			api.ctx.logger("dash-notify").warn(`${action} 失败：${message}`);
			process.stderr.write(`dash-notify: ${action} 失败：${message}\n`);
			api.push("error", { action, message });
		}
	}])),
});

/**
 * UI 动作 → `respond()` 的 result。返回 undefined = 不认得这个动作。
 *
 * **答案的形状由上游校验得很严**（`matchesQuestions` 会核对问题 id 集合），
 * 所以这里的每一条都对着 `dsh-host-apiproxy` 的 schema 写，别凭印象改。
 */
function translate(item, actionId, text) {
	if (item.kind === "approval") {
		const outcome = actionId === "allow" ? "allowed-once"
			: actionId === "reject" ? "rejected"
			: undefined;
		if (outcome === undefined) return undefined;
		return {
			ok: true,
			value: { sessionId: item.sessionId, approvalId: item.meta.approvalId, outcome },
		};
	}

	if (item.kind === "question") {
		const [questionId] = item.meta.questionIds ?? [];
		if (actionId === "cancel") {
			// 取消是 error 分支且**只认 `cancelled` 这一个 code**，别的 code 会被
			// 判成 bad-response 而 pending 原地不动（agent 就永远卡着）。
			return { ok: false, error: { code: "cancelled", message: "用户在通知上取消了提问" } };
		}
		if (actionId === "custom") {
			const custom = String(text ?? "").trim();
			if (custom === "") return undefined;
			return {
				ok: true,
				value: {
					sessionId: item.sessionId,
					answer: { answers: [{ id: questionId, selected: [], custom }] },
				},
			};
		}
		const match = /^opt\.(\d+)$/.exec(actionId);
		if (match === null) return undefined;
		// 按钮 label 就是选项 label（`inbox.js` 组的时候是逐字抄的），
		// 而答案要的正是 label——所以这里不需要回头去查原始 options。
		const label = item.actions.find((action) => action.id === actionId)?.label;
		if (label === undefined) return undefined;
		return {
			ok: true,
			value: {
				sessionId: item.sessionId,
				answer: { answers: [{ id: questionId, selected: [label] }] },
			},
		};
	}

	return undefined;
}

/**
 * cordis logger 在 `dsh web` 下没有 exporter：消息只进环形缓冲，终端一个字看不见。
 * 要给蹲终端的人看的东西必须自己写 stderr（与 dash-bridge / dash-sidebar 同款）。
 */
function reporter(logger) {
	const emit = (level, message) => {
		logger[level](message);
		process.stderr.write(`dash-notify: ${message}\n`);
	};
	return {
		info: (message) => emit("info", message),
		warn: (message) => emit("warn", message),
		error: (message) => emit("error", message),
	};
}

function errorText(error) {
	return error instanceof Error ? error.message : String(error);
}
