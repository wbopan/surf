/**
 * 通知文案表（计划 `docs/clam-i18n-plan.md` §5 的 node 侧那一半）。
 *
 * **全仓唯一写在 JS 里的用户文案**：通知的标题 / 正文 / 按钮由 node 组好，
 * Swift 那半边收到什么画什么（`swift/NotifyModel.swift` 顶注那条纪律）。
 * 别处的文案都在各插件的 `swift/Strings.swift` 里。
 *
 * 形态与 Swift 侧那张表刻意一致：zh 与 en **并排写在同一行**，审校时一眼对照；
 * 带插值的条目是函数而不是 `{name}` 模板。zh 是键集真相（对齐 dsh 的词典约定）。
 *
 * **完备性检查在模块加载时做**：Swift 那边漏一条 en 就编译不过，JS 没有这道闸，
 * 所以这里自己关一道——两张表的键集或值的类型对不上，`import` 当场 throw
 * （fails loud，而不是运行到那一条通知才露出 `undefined`）。
 *
 * 打磨过、与原文出入较大的条目在行尾以 `// 原：…` 标出，供 i6 汇总审校表。
 *
 * @module clam-notify/strings
 */
import { FALLBACK } from "../../clam-bridge/lib/locale.js";

/**
 * 语言 id → 文案表。
 *
 * 措辞规范（计划 §6）：zh 对照 macOS 系统 App 用词、不卖萌、不用「您」；
 * en 按钮 Title Case、正文 Sentence case。
 */
const TABLES = {
	zh: {
		// ---- 按钮（`UNNotificationAction.title`）----
		/** 四类通知都有它，且**只有它**会把 app 拉到前台。 */
		open: "打开查看",
		allowOnce: "允许一次",
		reject: "拒绝",
		/** 自由回答那颗按钮：按下去才展开输入框。 */
		other: "其他…",
		/** 输入框右边那颗提交按钮。 */
		send: "发送",
		/** 输入框里的占位字。 */
		answerPlaceholder: "输入你的回答",

		// ---- 标题与正文 ----
		doneTitle: "任务完成",
		doneBody: "回合已结束",
		errorTitle: "Agent 出错",
		/** 上游没给错误原文时的正文。 */
		errorBody: "未知错误",
		approvalTitle: "需要你的批准",
		approvalBody: "有一项操作等待批准", // 原：有一步操作在等你放行
		questionTitle: "需要你的回答",
		questionBody: "有一个问题等待回答", // 原：有一个问题在等你回答

		// ---- 拼行 ----
		/** 审批正文的第一行。 */
		toolLine: (tool) => `工具：${tool}`,
		/** 选项按钮没有 label 时的兜底名（`n` 从 1 起）。 */
		optionLabel: (n) => `选项 ${n}`,
	},
	en: {
		open: "Open",
		allowOnce: "Allow Once",
		reject: "Deny",
		other: "Other…",
		send: "Send",
		answerPlaceholder: "Type your answer",

		doneTitle: "Task complete",
		doneBody: "The turn has ended",
		errorTitle: "Agent error",
		errorBody: "Unknown error",
		approvalTitle: "Approval needed",
		approvalBody: "An action is waiting for your approval",
		questionTitle: "Answer needed",
		questionBody: "A question is waiting for your answer",

		toolLine: (tool) => `Tool: ${tool}`,
		optionLabel: (n) => `Option ${n}`,
	},
};

// ---- 完备性检查（模块加载时跑一次，差一条就 throw）----
verifyTables();

/**
 * 取一张文案表。认不得的语言退到兜底那门（值域外的输入不该让通知发不出去）。
 * @param {string|undefined} locale `"zh"` | `"en"`
 * @returns {typeof TABLES.zh}
 */
export function strings(locale) {
	return TABLES[locale] ?? TABLES[FALLBACK];
}

/**
 * zh 是键集真相：en 少一条、多一条、或者一条是字符串另一条是函数，都当场炸。
 *
 * 这是 node 侧替代「编译不过」的那道闸——漏译在运行期的症状是通知上一个
 * `undefined`，而它只在恰好那一类通知发生时才露面，可能几天都撞不上。
 */
function verifyTables() {
	const truth = Object.keys(TABLES.zh).sort();
	for (const [locale, table] of Object.entries(TABLES)) {
		const keys = Object.keys(table).sort();
		const missing = truth.filter((key) => !keys.includes(key));
		const extra = keys.filter((key) => !truth.includes(key));
		const mistyped = truth.filter((key) =>
			keys.includes(key) && typeof table[key] !== typeof TABLES.zh[key]);
		if (missing.length === 0 && extra.length === 0 && mistyped.length === 0) continue;
		throw new Error(`clam-notify 文案表 ${locale} 与 zh 对不上：`
			+ [
				missing.length ? `缺 ${missing.join(", ")}` : "",
				extra.length ? `多 ${extra.join(", ")}` : "",
				mistyped.length ? `类型不同 ${mistyped.join(", ")}` : "",
			].filter(Boolean).join("；"));
	}
}
