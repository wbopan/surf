// 注入文本的单测。零依赖，`node --test clam-memory/test/*.test.js`。
//
// 这里守的是**三种形态**（计划 §0 不变量 3 在 2026-08-30 被改写，见 §8 执行日志）：
//   无会话 → 空字符串；空目录 → 只有维护段；有记忆 → 信封 + pinned + 索引 + 维护段。

import assert from "node:assert/strict";
import test from "node:test";

import { joinSections, renderSections, SECTION_MAINTENANCE, SECTION_MEMORIES } from "../lib/prompt.js";

/** 旧测试按"一整段文本"写的，换 C 通道后出口是分段——这里拼回去继续守同样的断言。 */
const renderInjection = (snapshot) => joinSections(renderSections(snapshot));

const DIR = "/tmp/clam-memory-test";

test("没有 dir（= 没有会话、没有 cwd）→ 一段都不发", () => {
	assert.deepEqual(renderSections({}), []);
	assert.deepEqual(renderSections({ dir: "" }), []);
	assert.deepEqual(renderSections({ dir: undefined, entries: [] }), []);
});

test("分段：两段，段名固定——它们会成为 Web UI 里的 <dt>", () => {
	const names = (s) => renderSections(s).map((x) => x.name);
	assert.deepEqual(names({ dir: DIR }), [SECTION_MEMORIES, SECTION_MAINTENANCE]);
	assert.deepEqual(names({ dir: DIR, pinned: [{ name: "p", content: "c" }], entries: [{ name: "a", description: "b" }] }), [
		SECTION_MEMORIES,
		SECTION_MAINTENANCE,
	]);
	// 维护段永远在，且永远带着目录绝对路径——模型靠它知道往哪写。
	const maintenance = renderSections({ dir: DIR }).find((x) => x.name === SECTION_MAINTENANCE);
	assert.ok(maintenance.text.includes(DIR));
});

test("空目录仍然注入维护段——否则永远写不出第一条记忆", () => {
	const text = renderInjection({ dir: DIR, pinned: [], entries: [] });
	assert.match(text, /^# Project memory/);
	assert.match(text, /no memories yet/);
	assert.ok(text.includes(DIR), "维护段必须报出目录的绝对路径，模型才知道往哪写");
	assert.match(text, /## Maintaining this memory/);
	// 没有记忆就没有"下面这些笔记"，读者视角那半不该出现。
	assert.doesNotMatch(text, /background reference/);
	assert.doesNotMatch(text, /## Pinned memories/);
});

test("有记忆：信封 + pinned 全文 + 索引 + 核实规则 + 维护段，顺序固定", () => {
	const text = renderInjection({
		dir: DIR,
		pinned: [{ name: "house-style", content: "全文在此" }],
		entries: [
			{ name: "a-note", description: "第一条" },
			{ name: "b-note", description: "第二条" },
		],
	});
	const order = [
		"# Project memory",
		"background reference",
		"## Pinned memories (full text)",
		"### `house-style`",
		"## Memory index",
		"- `a-note`: 第一条",
		"assertion about the past",
		"## Maintaining this memory",
	];
	let at = -1;
	for (const needle of order) {
		const next = text.indexOf(needle, at + 1);
		assert.ok(next > at, `${needle} 应当出现且排在前一段之后`);
		at = next;
	}
});

test("三种截断各有自己的处置建议，不合并成一句", () => {
	const of = (reason) =>
		renderInjection({ dir: DIR, entries: [{ name: "x", description: "y" }], truncated: { reason, shown: 3, total: 9 } });
	assert.match(of("files"), /Longer descriptions will not help/);
	assert.match(of("bytes"), /descriptions are running long/);
	assert.match(of("lines"), /too many memories to/);
});

test("不再提任何专用工具（它们已经删了，提了就是指向不存在的东西）", () => {
	const text = renderInjection({
		dir: DIR,
		pinned: [{ name: "p", content: "c" }],
		entries: [{ name: "a", description: "b" }],
		truncated: { reason: "lines", shown: 1, total: 2 },
	});
	assert.doesNotMatch(text, /memory_read|memory_write|memory_list|memory_append|memory_str_replace/);
});
