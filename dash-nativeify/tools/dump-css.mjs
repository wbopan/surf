/*
 * 把 client.js 真正注入的那段 CSS 打出来，不用起 dsh、不用开壳。
 *
 * 为什么需要它：整段样式是**拼字符串**拼出来的，`node --check` 只看 JS 语法，
 * 看不出 CSS 括号有没有配对、选择器前缀有没有漏加（逗号串上只写一次前缀
 * 只会命中第一条，这个坑踩过两次）。这里跑一遍 apply()，抓下 style.textContent，
 * 顺带数括号。
 *
 *   node dash-nativeify/tools/dump-css.mjs            # 全量
 *   node dash-nativeify/tools/dump-css.mjs nofx tint  # 只看含关键字的规则
 *
 * 桩的两个坑：
 *  · Node 18+ 自带只读的 `navigator`，直接赋值会静默失效 —— 必须 defineProperty，
 *    否则 UA 门控不过，apply() 直接 return，你会得到一个"什么都没发生"。
 *  · `document.getElementById` 得存在（apply 开头要 remove 旧 style 节点）。
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, "..", "lib", "client.js"), "utf8");

Object.defineProperty(globalThis, "navigator",
	{ value: { userAgent: "Mozilla/5.0 Clam/1.0" }, configurable: true, writable: true });

let css = null;
const el = () => ({ setAttribute() {}, removeAttribute() {}, toggleAttribute() {}, remove() {},
                    appendChild() {}, offsetHeight: 0, style: {}, textContent: "" });
globalThis.window = { __ModuleLoader__: { load: (m) => { globalThis.__mod = m.factory(); } },
                      addEventListener() {}, removeEventListener() {} };
globalThis.document = {
	documentElement: el(), head: el(), body: el(), getElementById: () => null,
	createElement: () => { const e = el();
		Object.defineProperty(e, "textContent", { set: (v) => { css = v; }, get: () => css });
		return e; },
	addEventListener() {}, removeEventListener() {}, hasFocus: () => true, querySelectorAll: () => [],
};
globalThis.addEventListener = () => {};
globalThis.removeEventListener = () => {};

(0, eval)(src);
globalThis.__mod.apply({ effect: (f) => { try { f(); } catch (e) { console.error("effect 抛错:", e.message); } } });
if (css === null) { console.error("没抓到 CSS —— apply() 大概在 UA 门控那儿就 return 了"); process.exit(1); }

let depth = 0, bad = 0, line = 0;
for (const l of css.split("\n")) {
	line++;
	for (const ch of l) {
		if (ch === "{") depth++;
		else if (ch === "}" && --depth < 0) { console.error(`第 ${line} 行多出一个 }`); bad++; depth = 0; }
	}
}
const keys = process.argv.slice(2);
if (keys.length) {
	// 按规则切块再过滤，省得只打出孤零零一行
	const blocks = css.split(/\n(?=\S)/);
	console.log(blocks.filter((b) => keys.some((k) => b.includes(k))).join("\n"));
} else {
	console.log(css);
}
console.error(`\n— ${css.split("\n").length} 行 · ${(css.match(/\{/g) || []).length} 条规则 · ` +
              (depth === 0 && !bad ? "括号配对正确" : `括号不平衡 depth=${depth}`));
