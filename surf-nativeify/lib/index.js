/**
 * surf-nativeify，node 半边。
 *
 * 原本只干一件事（注册「对话区字号」那个设置命名空间），P4 之后多了一件：
 * **登记 `swift/` 载荷，并把 dsh 的 `ui-theme` 偏好投影给它**，好让原生那半边
 * （窗口底色、NSAppearance）跟着 dsh 的主题走，而不是各跟各的。
 *
 * 于是本包成了**三半边**：
 *
 * | 半边 | 干什么 | 缺席时 |
 * |---|---|---|
 * | `lib/client.js` | 注入那一大摞 CSS（本包九成的价值） | 网页回到 dsh 原样 |
 * | `lib/index.js`（这里） | 注册字号设置 ns + 把 `ui-theme` 投给 Swift | 字号退默认、主题不投影 |
 * | `swift/` | 收投影，设 `NSApp.appearance` 与主窗口底色 | 原生侧跟系统外观（今天的行为） |
 *
 * ## 为什么主题的真相在 dsh 而不是系统
 *
 * 计划 `docs/archive/native-feel-upgrade-plan.md` §0.1：**自然延伸 dsh，不另建主真相来源。**
 * dsh 设浅色而系统是深色时，原生侧边栏/工具栏深、网页正文浅，一眼穿帮；窗口
 * `backgroundColor` 跟系统而非 dsh 主题，首帧与 resize 会露底闪错色。所以这里只做
 * 投影，不做第二偏好源——用户改主题的地方仍然只有 dsh 那一处。
 *
 * ## 桥协议
 *
 * 下行（`push`）：
 *
 * | 频道 | 载荷 | 什么时候 |
 * |---|---|---|
 * | `theme` | `{theme: "light"\|"dark"\|"system", bgBase: {light, dark}}` | `ui-theme` 变化时，以及被 `theme` 动作请求时 |
 *
 * 上行（Swift `bridge.send(action:)`）：
 *
 * | 动作 | 载荷 | node 做什么 |
 * |---|---|---|
 * | `theme` | `{}` | 现读现推一份（每代 activate 时问一次，桥不给新世代补发） |
 *
 * **「每代问一次」不只是照抄纪律，这里还堵着一个真实的时序洞**：`ui-theme` 是
 * dsh-client-ui-theme 在自己的 `ctx.inject(["settings"])` 里注册的，跟我们的注册
 * 没有先后保证。挂载那一刻读，完全可能读到"尚未注册"（`settings.get` 返回
 * undefined）；而 `settings/updated` 只在**变化**时发，用户不动设置就永远等不到。
 * 壳的 activate 远晚于整棵插件树挂载完，那一刻现读必然读得到。
 *
 * @module surf-nativeify
 */
import z from "@deepseek-ai/schemastery";
import { createSwiftPlugin } from "../../surf-bridge/lib/plugin.js";

/**
 * dsh 主题设置的权威坐标，核实自
 * `@deepseek-ai/dsh-client-ui-theme/lib/index.js`（0.1.1-rc.2）：
 * `THEME_SETTINGS_NAMESPACE = "ui-theme"`、`THEME_PREFERENCE_FIELD = "preference"`、
 * `THEME_PREFERENCES = ["light","dark","system"]`、`DEFAULT_PREFERENCE = "system"`。
 * surf-settings 的通用页读的也是这一处（`swift/SettingsTabs.swift` 的
 * `GeneralRow(ns: "ui-theme", path: ["preference"])`）。
 *
 * **我们只读不注册**：ns 的主人是那个插件，重复 register 会 fail loud。
 */
const THEME_NS = "ui-theme";
const THEME_FIELD = "preference";
const THEME_VALUES = ["light", "dark", "system"];

/**
 * 页面底色，**按主题分档**——窗口 `backgroundColor` 要与网页第一屏同色，
 * 否则首帧和 resize 时会从窗口底下漏出一条别的颜色。
 *
 * - 浅色 `#FFFFFF`：dsh 的 `--dsw-alias-bg-base` → `--dsw-static-neutral-bluish-00`
 *   = `#fff`（核实自 `dsh-client-ui-theme/lib/client.js` 的构建产物）。我们不覆盖它。
 * - 深色 `#1E1E1E`：dsh 自己的深色档是 `--dsw-static-neutral-bluish-950` = `#151517`，
 *   但 **client.js 把它重映射成了 `#1E1E1E`**（见那边 `--dsw-alias-bg-base` 那条规则
 *   与 README「深色档页面底色定成 #1E1E1E」一节）。窗口要跟的是**页面实际画出来的
 *   那个色**，所以这里抄的是我们自己的覆盖值，不是 dsh 的原值。
 *
 * 值走投影而不是让 Swift 那边再写死一份：两处写死迟早分叉。
 * **改 client.js 里那条重映射时，这里必须同步改。**
 */
const BG_BASE = { light: "#FFFFFF", dark: "#1E1E1E" };

/** 本插件与 Swift 半身之间数据形状的版本。改载荷字段就 +1（它折进 contentHash）。 */
const SCHEMA_VERSION = 1;

/** 已经抱怨过"读不到 ui-theme"的那些 api（每次挂载只吵一次）。 */
const WARNED = new WeakSet();

export default createSwiftPlugin({
	name: "surf-nativeify",
	swiftDir: new URL("../swift/", import.meta.url),
	schemaVersion: SCHEMA_VERSION,

	subscribe: (api) => {
		const { ctx } = api;

		// `settings` 走**运行时嵌套 inject**，不是静态 `export const inject`。
		//
		// 静态 inject 的语义是"服务不在就整个插件不挂载"，而这个插件的全部价值是
		// client 半边那段 CSS——绝不能因为一个可选的设置项就让整个原生化消失。
		// 缺席时字号退到默认值、原生侧维持系统外观，其余一切照旧。（这个 cordis
		// fork 的 `inject` 没有 `{required, optional}` 形态，嵌套是它表达可选依赖的
		// 唯一方式。）
		//
		// 注意本包顶层**确实**有一条硬依赖：`createSwiftPlugin` 会自动 inject
		// `surfBridge`。那是同一张编排表里的兄弟、且是 Swift 载荷的必要条件，
		// 与 surf-layout 同一个赌注；它不在就没有壳，CSS 有没有也无所谓了。
		ctx.inject(["settings"], (scoped) => {
			// ── 我们自己的 ns：注册完就没了 ────────────────────────────
			//
			// 值由浏览器半边经 `ctx.settingsScope` 自己读，这半边从不碰它，
			// 也不需要 push 给谁。注册一个 ns 就等于同时点亮了两个界面，两边都
			// 不用改一行：surf-settings 那扇原生窗口（「插件 → 插件配置」把
			// `describe()` 里的每个 ns 一视同仁地列出来），以及 dsh 自己的页内
			// 设置对话框。
			//
			// 字段与范围的取值理由写在 client 半边 `BODY_DEFAULT` 那段注释里
			// ——**范围是被那边一张实测行高表的边界卡死的**，改这里之前先读那段。
			scoped.settings.register("surf-nativeify", z.object({
				// role('slider') + min/max 让原生设置窗口给出滑杆而不是一个让人手敲
				// 数字的文本框；认不出 role 的界面退化成数字输入，仍然可用。
				bodyFontSize: z.number().min(12).max(22).step(1).default(15).role("slider"),
				// header 滚动边缘的 Soft 模糊带开关（品味项，用户裁决要可配）。
				// **关 ≠ 裸穿**：关掉退到官方 Hard 形态（不透明底 + 细线），
				// 细线两种形态都在、不设开关——内容穿过边缘时那根线是"这里有
				// 边界"的最低限度陈述。CSS 侧的消费在 client 半边
				// `data-surf-webheader-noblur` 那几条规则。
				headerScrollBlur: z.boolean().default(true),
			}), {
				// 改完立刻重画，不需要重启：client 半边订着这个 ns，值一变就重写
				// 字体那张 style。界面据此标注"立即生效"。
				applies: "live",
			});

			// ── 别人的 ns：只订不注册 ──────────────────────────────────
			//
			// 订的是全局的 `settings/updated`（非 owner 拿不到 `SettingsScope`，
			// 那是 register 的返回值），自己按 ns 过滤。事件签名见
			// `@deepseek-ai/dsh-settings/types`：`(ns, next, prev, source)`，
			// 只在**解析后的值真的变了**时发，所以不需要再去抖。
			scoped.on("settings/updated", (ns) => {
				if (ns !== THEME_NS) return;
				pushTheme(api);
			});

			// 就绪即推一份：此刻壳可能早就连上、也早就问过一次了。
			// （读不到也不吵——挂载期读不到是正常的，见文件头那段时序说明。）
			pushTheme(api, { quiet: true });
		});
	},

	expose: {
		/** 壳每代 activate 问一次。现读现推，读不到就不投影。 */
		theme: (_payload, api) => { pushTheme(api); },
	},
});

/**
 * 读一次 `ui-theme` 并投给 Swift 半身。
 *
 * **读不到就不推**（`settings` 服务缺席、或 ns 还没注册）：不推 = Swift 那边
 * 什么都不做 = 原生侧维持系统外观 = 今天的行为。推一个猜出来的 "system" 反而会
 * 把 `NSApp.appearance` 主动按回 nil，那是拿默认值覆盖真相。
 *
 * @param {{ctx: object, push: (channel: string, payload: object) => void}} api
 * @param {{quiet?: boolean}} [options] `quiet` = 读不到时不抱怨（挂载期正常现象）。
 */
function pushTheme(api, { quiet = false } = {}) {
	const theme = readPreference(api.ctx);
	if (theme === undefined) {
		if (!quiet && !WARNED.has(api)) {
			WARNED.add(api);
			const message = `读不到设置 ns "${THEME_NS}"，原生侧维持系统外观`
				+ "（dsh 版本变动改了 ns 名？核对 dsh-client-ui-theme）";
			api.ctx.logger("surf-nativeify").warn(message);
			// cordis logger 在 `dsh web` 下没有 exporter，终端一个字看不见。
			process.stderr.write(`surf-nativeify: ${message}\n`);
		}
		return;
	}
	api.push("theme", { theme, bgBase: { ...BG_BASE } });
}

/**
 * 当前的 dsh 主题偏好，读不到返回 undefined。
 *
 * 走 `ctx.get("settings")` 而不是闭包里存一份服务句柄：**现读现算**才躲得开
 * "读的时候 ui-theme 还没注册"那个时序洞（文件头有说明）。这也正是 dsh 自己
 * `readPreference(ctx)` 的写法。
 *
 * @param {import('@deepseek-ai/cordis').Context} ctx
 * @returns {"light"|"dark"|"system"|undefined}
 */
function readPreference(ctx) {
	const settings = ctx.get("settings");
	if (settings === undefined) return undefined;
	let section;
	try {
		section = settings.get(THEME_NS);
	} catch {
		return undefined;
	}
	const value = section?.[THEME_FIELD];
	return THEME_VALUES.includes(value) ? value : undefined;
}
