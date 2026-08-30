/**
 * 分叉标题的序号递增（M10 从 DSHKit `SessionStore.increasedForkTitle` 移植回 JS）。
 *
 * **不变式：两个界面分叉出来的会话必须同名。** 上游把这条规则放在 client runtime 的
 * `fork(increaseTitle: true)` 里，服务层与 wire 上都只有 `session.fork` + 一次
 * `session.rename`——所以谁绕过 client runtime 分叉，谁就得自己补这一步。
 * M6 时它住在 Swift（DSHKit），M10 数据面搬进 node 半边后跟着搬回来；原来的
 * XCTest 用例逐条搬成 `test/fork-title.test.js`。
 *
 * 这里是上游 `dsh-client-runtime` 那段的等价实现（2026-08-26 对着 0.1.1-rc.2 的
 * 源码核过），两条正则一模一样：
 *
 * ```js
 * const ascii = /^(.*?)\((\d+)\)$/u.exec(title);
 * if (…) return `${ascii[1]}(${BigInt(ascii[2]) + 1n})`;
 * const fullWidth = /^(.*?)（(\d+)）$/u.exec(title);
 * if (…) return `${fullWidth[1]}（${BigInt(fullWidth[2]) + 1n}）`;
 * return `${title} (1)`;
 * ```
 *
 * 三个容易写错的地方：
 *
 * - `\d` **只认 ASCII 数字**。`x(１)`（全角一）不是序号，走兜底变成 `x(１) (1)`。
 * - 前缀是原样保留的捕获组，**空格在里面**：`foo (1)` → `foo (2)`，而无编号的
 *   标题是 `` `${title} (1)` ``，多出来的空格由这里补。
 * - 加一用 **BigInt**，没有上限。`Number` 在 2^53 之后会开始撒谎。
 *
 * @module surf-sidebar/fork-title
 */

/** 半角优先、全角其次；两条都锚定行尾，所以只认最后一对括号。 */
const PATTERNS = [
	{ re: /^(.*?)\((\d+)\)$/u, open: "(", close: ")" },
	{ re: /^(.*?)（(\d+)）$/u, open: "（", close: "）" },
];

/**
 * @param {string} title 源会话标题。
 * @returns {string} 子会话应有的标题。
 */
export function increasedForkTitle(title) {
	for (const { re, open, close } of PATTERNS) {
		const match = re.exec(title);
		if (match?.[1] === undefined || match[2] === undefined) continue;
		return `${match[1]}${open}${BigInt(match[2]) + 1n}${close}`;
	}
	return `${title} (1)`;
}

export default increasedForkTitle;
