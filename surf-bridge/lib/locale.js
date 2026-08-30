/**
 * node 侧语言决议的**共用零件**（计划 `docs/archive/surf-i18n-plan.md` §3 末段、§7）。
 *
 * 全仓面向用户的文案绝大多数在 Swift 里，语言经 `surf.locale` 粘性总线送到；
 * 但有两类东西长在 node 进程里、够不着那条总线：
 *
 *   1. surf-notify 的通知文案（标题/正文/按钮由 node 组好，Swift 收到什么画什么）；
 *   2. 各插件 settings schema 的 `.description()`——它们只进 dsh 页内设置对话框。
 *
 * 这个文件只放**纯函数**：语言标签怎么映射、环境怎么推导。真正的接线
 * （`ctx.settings.get("locale")`、听 `settings/updated`）各家自己写——形态差得远，
 * surf-notify 要一个活的读取口，注册 description 的地方只要"此刻是哪门语言"。
 *
 * **为什么住在 surf-bridge**：本仓库 surf-* 之间一律相对路径 import，而**所有**
 * 箭头都指向 surf-bridge（`./plugin.js` 那条），它是天然的底座。反过来让 surf-bridge
 * 去 import surf-notify 就把"缺席即无通知"的可选插件变成了特权插件的硬依赖。
 *
 * @module surf-bridge/locale
 */

/** 值域跟 dsh 走（`dsh-client-locale` 的 `LOCALES`），不自作主张加语言。 */
export const LOCALES = ["zh", "en"];

/** 一条都不中时的兜底，与 dsh 的 `resolveInitialLocale()` 一致。 */
export const FALLBACK = "en";

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
