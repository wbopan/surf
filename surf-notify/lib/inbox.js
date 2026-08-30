/**
 * 待办模型 —— 「有什么在等着你」的唯一真相。
 *
 * 三个消费者共用这一份：系统通知、Dock 角标、以及侧边栏那枚「待处理」胶囊
 * （经 `surfPending` 服务，见 `index.js`）。
 *
 * ## 收录与打扰是两件事
 *
 * 这里**照单全收**，`settings` 里那几个"要不要通知"的开关一个都不看。
 * 判断要不要弹横幅需要知道用户此刻在看哪个会话、窗口是不是 key、有没有被盖住，
 * 这三件事只在 app 进程里存在；node 侧一个都不知道，硬猜就会重演旧实现
 * 「前台过滤过于粗糙」那条老路。分工是：
 * **node 说发生了什么，Swift 决定打不打扰。**
 *
 * 这条纪律有个直接后果，也正是要的：把「回合结束」的通知关掉之后，侧边栏那枚
 * 胶囊里**照样**看得见它——关的是打扰，不是事实。早先那版把开关写在收录这一侧，
 * 于是关掉通知连带把侧边栏也弄瞎了。
 *
 * ## 身份
 *
 * 一条待办 = 一个 `id`，同时就是通知的 identifier：
 *
 * | kind | id | 为什么是它 |
 * |---|---|---|
 * | `approval` | `approval.<rpcId>` | rpcId 就是回答用的钥匙，天然唯一 |
 * | `question` | `question.<rpcId>` | 同上 |
 * | `done` | `done.<sessionId>` | 一个会话只留最新一条"回合结束"，同 id 自动替换 |
 * | `error` | `error.<sessionId>` | 同上；新错误盖掉旧错误 |
 *
 * **所以一个时间常数都不需要**。旧实现拿 60s/300s 的冷却去重，本质是没有身份可用
 * 才退而求其次；这里有 rpcId，去重就是身份问题而不是时间问题。
 *
 * ## 已办的行留着
 *
 * `resolved` 之后 item 不从表里删，只翻成 `state:"resolved"` 并记下 outcome
 * ——系统通知会被撤下，历史那一行留着（置灰）。表有上限（`HISTORY_LIMIT`），
 * 超了从最老的已办开始丢。
 *
 * ## 语言
 *
 * 每条 item 的文案在**组它的那一刻**按当时的界面语言渲染，并把语言 id 一起记在
 * 行上（`item.locale`）。语言后来变了**不追改已有的行**（计划 §5）：屏幕上那条
 * 通知的文案变了就等于撤下重发，会再响一次、再跳一次——为一个已经看过的提醒
 * 打扰第二次不划算。`refresh()` 重算按钮时按**那一行自己的语言**，
 * 免得出现「标题中文、按钮英文」的半拉子。
 *
 * @module surf-notify/inbox
 */
import { strings } from "./strings.js";

/** 已办的行最多留多少（待办不受限——待办是真相，不能丢）。 */
const HISTORY_LIMIT = 50;

/** 通知正文裁多长。横幅两三行就到头了，再长只是喂给通知中心的详情。 */
const BODY_MAX_CHARS = 220;

/**
 * 提问最多映射几个选项按钮。
 *
 * 横幅上塞不下更多——超出的按钮会被系统吞掉，而**被吞掉的那个恰好可能是用户
 * 想选的**，比不给按钮更糟。超过就一个选项都不给，只留「打开查看」。
 */
const MAX_OPTION_ACTIONS = 4;

/**
 * @param {{titleOf: (id:string) => string|undefined}} source 用来查会话标题。
 * @param {() => object} readSettings 当前设置（随时可能变，每次组 item 时现读）。
 * @param {() => string} readLocale 当前界面语言（同上，现读；见顶部「语言」一节）。
 * @param {() => void} onChange 集合变了（Swift 该收新的一份了）。
 */
export function createInbox(source, readSettings, readLocale, onChange) {
	/** id → item。插入序 = Map 的迭代序，正是我们要的时间序。 */
	const items = new Map();
	/** sessionId → 是否在跑。`turn/end` 之后还 running 说明只是回合间暂停。 */
	const running = new Map();

	return {
		/** 待办 + 已办，按时间倒序（新的在前）。 */
		list() {
			return [...items.values()].sort((a, b) => b.createdAt - a.createdAt);
		},

		/** 未办的条数（Dock 角标用；done/error 是否计入归 Swift 侧的设置）。 */
		pending() {
			return [...items.values()].filter((item) => item.state === "pending");
		},

		/** 一条待办的回答钥匙。已办/不存在都返回 undefined。 */
		keyOf(id) {
			const item = items.get(id);
			return item?.state === "pending" ? item : undefined;
		},

		onPending(event) {
			const settings = readSettings();
			const item = buildPending(event, source, settings, readLocale());
			if (item === undefined) return;
			items.set(item.id, item);
			trim();
			onChange();
		},

		/**
		 * 别处把它办了（web UI 答了、超时、中断），或者我们自己刚答完。
		 * `match` 两种形态：`{id}` 直接命中，`{sessionId, approvalId}` 反查
		 * ——`approval/resolved` 帧是纯 push，身上没有 rpcId。
		 */
		onResolved({ match, outcome }) {
			const item = match.id !== undefined
				? items.get(match.id)
				: [...items.values()].find((row) =>
					row.kind === "approval"
					&& row.state === "pending"
					&& row.sessionId === match.sessionId
					&& row.meta?.approvalId === match.approvalId);
			if (item === undefined || item.state !== "pending") return;
			item.state = "resolved";
			item.outcome = String(outcome ?? "");
			item.resolvedAt = Date.now();
			trim();
			onChange();
		},

		onRunning({ sessionId, running: isRunning }) {
			running.set(sessionId, isRunning);
			// 又跑起来了 = 上一条"回合结束"和上一次出错都过期了。撤掉它们
			// （Swift 收到集合里没了这一条，就把通知撤下；侧边栏的待处理标记同理）。
			if (!isRunning) return;
			let changed = items.delete(`done.${sessionId}`);
			changed = items.delete(`error.${sessionId}`) || changed;
			if (changed) onChange();
		},

		/**
		 * 用户此刻在看这个会话（Swift 侧的 `focus` 动作送下来）。
		 *
		 * **只清「看一眼就算了」的那两类**（回合结束、出错）：看见了就是看见了，
		 * 不该再算欠他的事。待批准与待回答**不清**——那两类要真答了才算完，
		 * 光看着不作数（清了侧边栏与角标就会骗人说没事了）。
		 */
		onFocus(sessionId) {
			if (typeof sessionId !== "string" || sessionId === "") return;
			let changed = items.delete(`done.${sessionId}`);
			changed = items.delete(`error.${sessionId}`) || changed;
			if (changed) onChange();
		},

		onTurnEnd({ sessionId }) {
			// **还在跑就是回合间暂停，不是完成**（旧实现这一条判对了，留着）。
			if (running.get(sessionId) === true) return;
			const locale = readLocale();
			const L = strings(locale);
			const item = {
				id: `done.${sessionId}`,
				kind: "done",
				sessionId,
				sessionTitle: source.titleOf(sessionId) ?? null,
				createdAt: Date.now(),
				state: "pending",
				locale,
				title: source.titleOf(sessionId) ?? L.doneTitle,
				body: L.doneBody,
				actions: [openAction(L)],
				textInput: null,
				importance: "passive",
				meta: {},
			};
			items.set(item.id, item);
			trim();
			onChange();
		},

		onAgentError({ sessionId, message }) {
			const locale = readLocale();
			const L = strings(locale);
			const item = {
				id: `error.${sessionId}`,
				kind: "error",
				sessionId,
				sessionTitle: source.titleOf(sessionId) ?? null,
				createdAt: Date.now(),
				state: "pending",
				locale,
				title: L.errorTitle,
				// 上游没给原话时才轮到我们说话——`mux-source.js` 一个字都不组。
				body: clip(message) || L.errorBody,
				actions: [openAction(L)],
				textInput: null,
				importance: "interrupt",
				meta: {},
			};
			items.set(item.id, item);
			trim();
			onChange();
		},

		/** 标题到货：把已经组好的行上的会话名补上。 */
		onTitles() {
			let changed = false;
			for (const item of items.values()) {
				const title = source.titleOf(item.sessionId) ?? null;
				if (item.sessionTitle === title) continue;
				item.sessionTitle = title;
				if (item.kind === "done" && title !== null) item.title = title;
				changed = true;
			}
			if (changed) onChange();
		},

		/** 划掉一行（不回答 dsh，只是不想看见了）。 */
		dismiss(id) {
			if (!items.delete(id)) return;
			onChange();
		},

		dismissAll() {
			let changed = false;
			for (const [id, item] of [...items.entries()]) {
				// **待办不能被"全部清除"抹掉**：dsh 还在等回答，抹了只是让人忘了它。
				if (item.state === "pending" && (item.kind === "approval" || item.kind === "question")) continue;
				items.delete(id);
				changed = true;
			}
			if (changed) onChange();
		},

		/**
		 * 设置变了：已在表里的行重算一遍按钮（如「直接批准」被关掉）。
		 *
		 * 用**这一行自己的语言**重算，不是此刻的语言：这一行的标题与正文早在组它
		 * 那一刻就定死了（顶部「语言」一节），拿新语言重算按钮只会拼出半拉子。
		 */
		refresh() {
			const settings = readSettings();
			let changed = false;
			for (const item of items.values()) {
				if (item.kind !== "approval" || item.state !== "pending") continue;
				const next = approvalActions(settings, strings(item.locale));
				if (JSON.stringify(next) === JSON.stringify(item.actions)) continue;
				item.actions = next;
				changed = true;
			}
			if (changed) onChange();
		},
	};

	/** 超出历史上限时，从最老的**已办**开始丢。待办永远不丢。 */
	function trim() {
		const resolved = [...items.values()]
			.filter((item) => item.state !== "pending")
			.sort((a, b) => (a.resolvedAt ?? a.createdAt) - (b.resolvedAt ?? b.createdAt));
		let excess = resolved.length - HISTORY_LIMIT;
		for (const item of resolved) {
			if (excess <= 0) break;
			items.delete(item.id);
			excess -= 1;
		}
	}
}

/**
 * 「打开查看」——四类通知都有它，且**只有它**带 foreground（会把 app 拉到前台）。
 * @param {ReturnType<typeof strings>} L
 */
function openAction(L) {
	return { id: "open", label: L.open, style: "foreground" };
}

function approvalActions(settings, L) {
	const actions = [];
	// 关掉「直接批准」之后只剩拒绝——**拒绝始终留着**：它是安全方向的动作，
	// 在通知上办掉它永远不会造成意外授权。
	if (settings.actionableApproval === true) {
		actions.push({ id: "allow", label: L.allowOnce });
	}
	actions.push({ id: "reject", label: L.reject, style: "destructive" });
	actions.push(openAction(L));
	return actions;
}

/**
 * 把一条 requested 帧组成 item。返回 undefined = 这条帧组不出 item（形状不认得）。
 *
 * **这里不看"要不要通知"那几个设置开关**——收录与打扰是两件事，见本文件顶部
 * 那条分层纪律。`settings` 仍要传进来，因为按钮的组成（`actionableApproval`）
 * 是 item 内容的一部分。
 */
function buildPending(event, source, settings, locale) {
	const L = strings(locale);
	const base = {
		id: event.id,
		sessionId: event.sessionId,
		sessionTitle: source.titleOf(event.sessionId) ?? null,
		createdAt: Date.now(),
		state: "pending",
		// 这一行说哪门语言，组它的这一刻就定死了（顶部「语言」一节）。
		locale,
		rpcId: event.rpcId,
		textInput: null,
		importance: "interrupt",
	};

	if (event.kind === "approval") {
		const tool = String(event.data.toolName ?? "").trim();
		const reason = String(event.data.reason ?? "").trim();
		const lines = [];
		if (tool !== "") lines.push(L.toolLine(tool));
		if (reason !== "") lines.push(reason);
		return {
			...base,
			kind: "approval",
			title: L.approvalTitle,
			body: clip(lines.join("\n")) || L.approvalBody,
			actions: approvalActions(settings, L),
			meta: {
				approvalId: event.data.approvalId,
				toolName: tool,
				...(event.data.callId === undefined ? {} : { callId: event.data.callId }),
			},
		};
	}

	if (event.kind === "question") {
		const questions = Array.isArray(event.data.questions) ? event.data.questions : [];
		const first = questions[0];
		if (first === undefined) return undefined;
		const detail = String(first.detail ?? "").trim();
		const body = [String(first.question ?? "").trim(), detail]
			.filter((line) => line !== "").join("\n");
		return {
			...base,
			kind: "question",
			title: first.header !== undefined && String(first.header).trim() !== ""
				? String(first.header).trim()
				: L.questionTitle,
			body: clip(body) || L.questionBody,
			actions: questionActions(questions, L),
			// 自由回答。**多问题的一批不给输入框**：一次 ask 的所有问题必须一起答
			// （上游 `matchesQuestions` 会核对问题 id 集合），一个输入框答不了两道题。
			//
			// 三个字都由这边下发（`label` 是展开输入框那颗按钮的名字）：Swift 那边
			// 一个字都不自己编，语言就只有这一个真相。
			textInput: questions.length === 1
				? { id: "custom", label: L.other, placeholder: L.answerPlaceholder, button: L.send }
				: null,
			meta: {
				questionCount: questions.length,
				questionIds: questions.map((q) => String(q?.id ?? "")),
			},
		};
	}

	return undefined;
}

/**
 * 提问的按钮。
 *
 * 三条降级路线，一条都不能少：
 * - 多问题的一批 → 一个选项按钮都不给（一次 ask 要整批答，横幅表达不了）。
 * - `multiSelect` → 同上（勾选在横幅上无法表达）。
 * - 选项多于 `MAX_OPTION_ACTIONS` → 同上（塞不下，被吞掉的那个可能正是要选的）。
 *
 * `intent: plan-review` 是唯一的特例：**按 label 认哪个是批准，不看顺序**
 * （上游明写"no UI infers the verdict from option order"）。
 */
function questionActions(questions, L) {
	if (questions.length !== 1) return [openAction(L)];
	const first = questions[0];
	if (first.multiSelect === true) return [openAction(L)];
	const options = Array.isArray(first.options) ? first.options : [];
	if (options.length === 0 || options.length > MAX_OPTION_ACTIONS) return [openAction(L)];

	const approve = first.intent?.kind === "plan-review"
		? String(first.intent.approve ?? "")
		: undefined;

	const actions = options.map((option, index) => {
		const label = String(option?.label ?? "").trim() || L.optionLabel(index + 1);
		const action = { id: `opt.${index}`, label };
		// plan-review：批准之外的都是"不批准"，标红提醒这是个否定动作。
		if (approve !== undefined && label !== approve) action.style = "destructive";
		return action;
	});
	actions.push(openAction(L));
	return actions;
}

function clip(text) {
	const value = String(text ?? "").replace(/\s+$/g, "");
	if (value.length <= BODY_MAX_CHARS) return value;
	return `${value.slice(0, BODY_MAX_CHARS - 1)}…`;
}
