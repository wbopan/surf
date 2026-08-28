/**
 * clam-notify 的 node 侧语言决议（计划 `docs/clam-i18n-plan.md` §3 末段）。
 *
 * **为什么 clam-notify 要自己算一遍**：全仓其余面向用户的文案都在 Swift 里，
 * 语言经 `clam.locale` 粘性总线送到；只有通知的标题/正文/按钮是 node 组好的
 * （Swift 那半边「收到什么画什么」），它够不着总线，只能自己从 dsh 设置里读。
 *
 * 决议链（与壳那条平行、结果一致）：
 *
 * 1. `ctx.settings.get("locale")` 的 `preference`——dsh 的唯一权威。
 * 2. 没配（`preference` 缺省是**有语义的**：dsh 那边缺省 = 环境推导）就用
 *    `Intl.DateTimeFormat().resolvedOptions().locale` 推。dsh 进程与壳同机，
 *    推出来的就是系统语言，和页面侧 `navigator.languages` 的推导对得上。
 * 3. 都不中 → `en`。
 *
 * **绝不 `register("locale")`**：ns 是单占的，dsh-client-locale 已经占了，
 * 重复注册 fails loud（会赔掉整个插件）。这里只 `get` + 听 `settings/updated`。
 *
 * @module clam-notify/locale
 */

/** dsh 的 `locale` 设置命名空间。**只读，不注册。** */
const LOCALE_NS = "locale";

/** 值域跟 dsh 走（`dsh-client-locale` 的 `LOCALES`），不自作主张加语言。 */
const LOCALES = ["zh", "en"];

/** 一条都不中时的兜底，与 dsh 的 `resolveInitialLocale()` 一致。 */
const FALLBACK = "en";

/**
 * 语言标签 → 支持的语言 id。取 primary subtag（`zh-Hans-CN` → `zh`、
 * `en-GB` → `en`），不在值域内返回 undefined。
 * @param {unknown} tag
 * @returns {string|undefined}
 */
export function localeFromTag(tag) {
	if (typeof tag !== "string" || tag === "") return undefined;
	const primary = tag.toLowerCase().split("-")[0];
	return LOCALES.includes(primary) ? primary : undefined;
}

/**
 * 环境推导：这台机器的系统语言。`Intl` 在 node 里读的是进程 locale，
 * 而 dsh 与壳同机，所以这一级与页面侧的浏览器推导天然一致。
 * @returns {string} `"zh"` 或 `"en"`
 */
export function environmentLocale() {
	try {
		return localeFromTag(Intl.DateTimeFormat().resolvedOptions().locale) ?? FALLBACK;
	} catch {
		// Intl 在剥掉 ICU 的 node 上可能给不出有意义的值——退兜底，不抛。
		return FALLBACK;
	}
}

/**
 * 订上 dsh 的语言设置，返回一个「当前语言」的读取口。
 *
 * 缺席即退化：`settings` 服务不在、ns 还没注册、值读不出来，一律退到环境推导，
 * 通知照发——语言不对比一条通知都没有好得多。
 *
 * @param {import('@deepseek-ai/cordis').Context} ctx 插件自己的 ctx（清理随 fiber）。
 * @param {(locale: string) => void} [onChange] 语言真的变了时叫一声（同值不叫）。
 * @returns {{ current: string }} `current` 是活的：每次读都是此刻的值。
 */
export function createLocaleSource(ctx, onChange) {
	let current = environmentLocale();

	/** 把一份 `locale` ns 的原始值收进来。`preference` 缺省 = 回到环境推导。 */
	const adopt = (section) => {
		const preference = section && typeof section === "object"
			? /** @type {{ preference?: unknown }} */ (section).preference
			: undefined;
		const next = localeFromTag(preference) ?? environmentLocale();
		if (next === current) return;
		current = next;
		// 消费方自己的错不该拖垮设置回调（dsh 会把抛出的监听器记成 warn，
		// 但那样这一轮后面的活就不做了）。
		try { onChange?.(next); } catch { /* 消费方的事故不外溢 */ }
	};

	try {
		ctx.inject(["settings"], (scoped) => {
			try {
				adopt(scoped.settings.get(LOCALE_NS));
			} catch { /* ns 尚未注册时读不到，退环境推导 */ }
			// `settings/updated` 是全局提交事件，每个 ns 的写都会来一遍——自己过滤。
			scoped.effect(
				() => scoped.on("settings/updated", (ns, next) => {
					if (String(ns) !== LOCALE_NS) return;
					adopt(next);
				}),
				"clam-notify 语言订阅",
			);
		});
	} catch { /* settings 缺席：一直用环境推导 */ }

	return {
		get current() { return current; },
	};
}
