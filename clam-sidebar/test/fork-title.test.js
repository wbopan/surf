/**
 * `increasedForkTitle` 的用例，逐条搬自 DSHKit 的 `ForkTitleTests.swift`（M10 退役前）。
 *
 * 跑法（零依赖，node 内置 test runner）：
 *
 * ```sh
 * node --test clam-sidebar/test/*.test.js
 * ```
 *
 * （给 `--test` 一个目录会让 node 26 去 `require` 那个目录本身而不是遍历它，
 * 直接 `MODULE_NOT_FOUND`——写通配符。）
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import { increasedForkTitle } from "../lib/fork-title.js";

test("没有编号的标题从 (1) 起", () => {
	assert.equal(increasedForkTitle("重构侧边栏"), "重构侧边栏 (1)");
});

test("半角序号递增", () => {
	assert.equal(increasedForkTitle("重构侧边栏 (1)"), "重构侧边栏 (2)");
	assert.equal(increasedForkTitle("x(9)"), "x(10)");
});

test("全角括号原样保留", () => {
	assert.equal(increasedForkTitle("重构侧边栏（2）"), "重构侧边栏（3）");
});

// 上游正则里的 `\d` 只认 ASCII 数字：全角数字不是序号，整串当作没编号。
test("全角数字不算序号", () => {
	assert.equal(increasedForkTitle("x(１)"), "x(１) (1)");
});

// 括号里不是纯数字 → 不是序号。
test("非数字括号走兜底", () => {
	assert.equal(increasedForkTitle("修 bug (紧急)"), "修 bug (紧急) (1)");
	assert.equal(increasedForkTitle("空括号()"), "空括号() (1)");
});

// 只认最后一对括号（上游正则的非贪婪前缀 + 行尾锚点）。
test("只认结尾那个序号", () => {
	assert.equal(increasedForkTitle("(3) 计划 (7)"), "(3) 计划 (8)");
	assert.equal(increasedForkTitle("a (1) (2)"), "a (1) (3)");
});

// DSHKit 那份用 Int，上游用 BigInt。移植回 JS 顺手把上限补回来。
test("大数不失真", () => {
	assert.equal(increasedForkTitle("x(9007199254740993)"), "x(9007199254740994)");
});
