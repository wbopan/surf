// clam-memory 存储层的单测。零依赖，`node --test clam-memory/test/*.test.js`。
// 全部在 os.tmpdir() 里造目录，**不碰真实的 ~/.claude 或 ~/.dsh**。

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { createMemoryStore, LIMITS, parseFrontmatter, renderIndexLine } from "../lib/store.js";

const CWD = "/anything"; // dir 是绝对路径时 cwd 不参与决议

function tmpDir(tag) {
	return fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), `clam-memory-${tag}-`)));
}

/** 造一条记忆文件。`meta` 里的键原样写进 metadata。 */
function put(dir, name, { description = `${name} 的一行摘要`, meta = {}, body = "正文\n" } = {}) {
	const lines = ["---", `name: ${name}`, `description: ${description}`, "metadata:"];
	for (const [k, v] of Object.entries({ node_type: "memory", type: "project", ...meta })) {
		lines.push(`  ${k}: ${v}`);
	}
	lines.push("---", "", body);
	fs.writeFileSync(path.join(dir, `${name}.md`), lines.join("\n"));
	return path.join(dir, `${name}.md`);
}

function touch(file, ms) {
	const t = new Date(ms);
	fs.utimesSync(file, t, t);
}

// ── frontmatter ──────────────────────────────────────────────────────────────

test("frontmatter：正常解析（含真实文件里 `metadata: ` 那个尾随空格）", () => {
	const text = [
		"---",
		"name: analytics-perf",
		"description: 一行摘要，含冒号: 也不该炸",
		"metadata: ", // ← 本机 ~/.claude 里的真实文件就是带尾随空格的
		"  node_type: memory",
		"  type: project",
		"  originSessionId: f5552872",
		"  modified: 2026-08-29T12:34:56Z",
		"  pinned: true",
		"---",
		"",
		"正文第一行",
		"",
	].join("\n");
	const parsed = parseFrontmatter(text);
	assert.ok(parsed);
	assert.equal(parsed.data.name, "analytics-perf");
	assert.equal(parsed.data.description, "一行摘要，含冒号: 也不该炸");
	assert.equal(parsed.data.metadata.type, "project");
	assert.equal(parsed.data.metadata.modified, "2026-08-29T12:34:56Z");
	assert.equal(parsed.data.metadata.pinned, "true");
	assert.equal(text.slice(parsed.bodyOffset), "正文第一行\n");
});

test("frontmatter：引号被剥掉", () => {
	const parsed = parseFrontmatter(['---', 'name: "quoted"', "description: 'also quoted'", "---", "", "x"].join("\n"));
	assert.equal(parsed.data.name, "quoted");
	assert.equal(parsed.data.description, "also quoted");
});

test("frontmatter：缺字段 / 没开头 / 没闭合 一律返回 null", () => {
	assert.equal(parseFrontmatter("# Memory Index\n\n- [a](a.md)\n"), null, "残留的 MEMORY.md 那种裸 markdown");
	assert.equal(parseFrontmatter("---\nname: a\n---\n\nx"), null, "缺 description");
	assert.equal(parseFrontmatter("---\ndescription: d\n---\n\nx"), null, "缺 name");
	assert.equal(parseFrontmatter("---\nname: a\ndescription: d\n\nx"), null, "没闭合");
	assert.equal(parseFrontmatter(""), null);
	assert.equal(parseFrontmatter(undefined), null);
});

test("建索引每个文件只读前 30 行：闭合的 --- 落在第 31 行就当解析失败", () => {
	const dir = tmpDir("head");
	const padded = ["---", "name: too-deep", "description: 摘要", ...Array.from({ length: 28 }, (_, i) => `pad${i}: 填充`), "---", "", "正文"].join("\n");
	fs.writeFileSync(path.join(dir, "too-deep.md"), padded);
	put(dir, "shallow");

	const store = createMemoryStore({ dir });
	const { entries } = store.index(CWD);
	assert.deepEqual(
		entries.map((e) => e.name),
		["shallow"],
	);

	// 只是**不进索引**：文件照样在磁盘上，模型用普通 read 工具照样读得到全文。
	// 前 30 行是建索引的取样上限，不是对文件本身的限制。
	assert.ok(fs.readFileSync(path.join(dir, "too-deep.md"), "utf8").includes("正文"));
});

test("Claude 目录里残留的 MEMORY.md 被自然滤掉（无需特判）", () => {
	const dir = tmpDir("legacy");
	fs.writeFileSync(path.join(dir, "MEMORY.md"), "# Memory Index\n\n- [a](a.md) — 旧索引\n");
	put(dir, "real-one");
	const { entries } = createMemoryStore({ dir }).index(CWD);
	assert.deepEqual(
		entries.map((e) => e.name),
		["real-one"],
	);
});

// ── 索引 ─────────────────────────────────────────────────────────────────────

test("索引按 modified 倒序，缺 modified 的排最后并用 mtime 兜底", () => {
	const dir = tmpDir("order");
	put(dir, "old-mod", { meta: { modified: "2026-01-01T00:00:00Z" } });
	put(dir, "new-mod", { meta: { modified: "2026-08-01T00:00:00Z" } });
	const a = put(dir, "no-mod-a");
	const b = put(dir, "no-mod-b");
	touch(a, Date.UTC(2020, 0, 1));
	touch(b, Date.UTC(2026, 11, 31)); // mtime 再新也排在有 modified 的后面

	const { entries, truncated } = createMemoryStore({ dir }).index(CWD);
	assert.equal(truncated, null);
	assert.deepEqual(
		entries.map((e) => e.name),
		["new-mod", "old-mod", "no-mod-b", "no-mod-a"],
	);
	assert.equal(entries[0].modified, "2026-08-01T00:00:00Z");
	assert.equal(entries[2].modified, null);
});

test("索引行格式与 name/description 截断", () => {
	const dir = tmpDir("clamp");
	put(dir, "wordy", { description: "d".repeat(500) });
	const { entries, text } = createMemoryStore({ dir }).index(CWD);
	assert.equal(entries[0].description.length, LIMITS.descriptionChars);
	assert.equal(text, renderIndexLine(entries[0]));
	assert.match(text, /^- `wordy`: d+$/);
});

test("截断 · files：扫描文件数上限（默认 200，真造 201 个）", () => {
	const dir = tmpDir("cut-files");
	for (let i = 0; i < 201; i += 1) {
		const f = put(dir, `mem-${String(i).padStart(3, "0")}`);
		touch(f, Date.UTC(2026, 0, 1) + i * 60_000); // i 越大越新
	}
	const { entries, truncated } = createMemoryStore({ dir }).index(CWD);
	assert.equal(entries.length, LIMITS.scanFiles);
	assert.deepEqual(truncated, { reason: "files", shown: 200, total: 201 });
	assert.equal(entries[0].name, "mem-200", "留下的是 mtime 最新的那 200 个");
	assert.ok(!entries.some((e) => e.name === "mem-000"));
});

test("截断 · lines：索引行数上限", () => {
	const dir = tmpDir("cut-lines");
	for (let i = 0; i < 5; i += 1) put(dir, `mem-${i}`, { meta: { modified: `2026-08-0${i + 1}T00:00:00Z` } });
	const store = createMemoryStore({ dir, limits: { indexLines: 2 } });
	const { entries, truncated, text } = store.index(CWD);
	assert.equal(entries.length, 2);
	assert.deepEqual(truncated, { reason: "lines", shown: 2, total: 5 });
	assert.equal(text.split("\n").length, 2);
});

test("截断 · bytes：在最后一个换行处截断，不切半行", () => {
	const dir = tmpDir("cut-bytes");
	for (let i = 0; i < 5; i += 1) put(dir, `mem-${i}`, { description: "x".repeat(40), meta: { modified: `2026-08-0${i + 1}T00:00:00Z` } });
	const one = Buffer.byteLength("- `mem-4`: " + "x".repeat(40), "utf8");
	const store = createMemoryStore({ dir, limits: { indexBytes: one * 2 + 1 } });
	const { entries, truncated, text } = store.index(CWD);
	assert.equal(entries.length, 2);
	assert.deepEqual(truncated, { reason: "bytes", shown: 2, total: 5 });
	assert.ok(Buffer.byteLength(text, "utf8") <= one * 2 + 1);
	assert.equal(text.split("\n").length, 2, "整行整行地留，不切半行");
});

test("目录不存在 / 为空 → 空索引，不抛", () => {
	const dir = path.join(tmpDir("empty"), "does-not-exist");
	const store = createMemoryStore({ dir });
	assert.deepEqual(store.index(CWD), { entries: [], truncated: null, text: "" });
	assert.deepEqual(store.pinned(CWD), []);
});

test("保留子目录名不进扫描", () => {
	const dir = tmpDir("reserved");
	for (const n of ["team", "logs", "sessions", "proposals"]) put(dir, n);
	put(dir, "keeper");
	fs.mkdirSync(path.join(dir, "sessions-dir.md")); // 目录也不算数
	const { entries } = createMemoryStore({ dir }).index(CWD);
	assert.deepEqual(
		entries.map((e) => e.name),
		["keeper"],
	);
});

test("缓存按目录签名失效：文件一变就重建", () => {
	const dir = tmpDir("cache");
	put(dir, "one");
	const store = createMemoryStore({ dir });
	assert.equal(store.index(CWD).entries.length, 1);
	const f = put(dir, "two");
	touch(f, Date.now());
	assert.equal(store.index(CWD).entries.length, 2, "新文件立刻可见，不需要 invalidate");
	fs.unlinkSync(f);
	assert.equal(store.index(CWD).entries.length, 1);
});

// ── pinned ───────────────────────────────────────────────────────────────────

test("pinned：上限 8、modified 倒序、只回正文", () => {
	const dir = tmpDir("pinned");
	for (let i = 0; i < 12; i += 1) {
		put(dir, `p-${String(i).padStart(2, "0")}`, {
			meta: { pinned: "true", modified: `2026-08-${String(i + 1).padStart(2, "0")}T00:00:00Z` },
			body: `第 ${i} 条的正文\n`,
		});
	}
	put(dir, "not-pinned");
	put(dir, "explicit-false", { meta: { pinned: "false" } });

	const got = createMemoryStore({ dir }).pinned(CWD);
	assert.equal(got.length, LIMITS.pinned);
	assert.deepEqual(
		got.map((p) => p.name),
		["p-11", "p-10", "p-09", "p-08", "p-07", "p-06", "p-05", "p-04"],
	);
	assert.equal(got[0].content.trim(), "第 11 条的正文");
	assert.ok(!got.some((p) => p.name === "not-pinned" || p.name === "explicit-false"));
});

// ── read ─────────────────────────────────────────────────────────────────────

// ── ensureDir ────────────────────────────────────────────────────────────────
// 两个专用工具删掉之后，本层唯一的写动作。注入文本对模型说"目录已存在，别自己建"，
// 这几条就是那句话的兑现。

test("ensureDir 逐级建出目录（0o700），幂等，且只进一次系统调用", () => {
	const home = tmpDir("ensure");
	const repo = path.join(home, "repo");
	fs.mkdirSync(path.join(repo, ".git"), { recursive: true });
	const prev = process.env.DSH_HOME;
	try {
		process.env.DSH_HOME = home;
		const store = createMemoryStore({ dir: "" });
		const expected = path.join(home, "memory", repo.split(path.sep).join("-"));
		assert.equal(store.resolveDir(repo), expected);
		assert.equal(fs.existsSync(expected), false);

		assert.equal(store.ensureDir(repo), expected);
		assert.ok(fs.statSync(expected).isDirectory());
		assert.equal(fs.statSync(expected).mode & 0o777, 0o700);

		// 幂等：再叫一次不抛、路径不变。走的是 ensured 记账那条短路。
		fs.rmSync(expected, { recursive: true });
		assert.equal(store.ensureDir(repo), expected);
		assert.equal(fs.existsSync(expected), false, "记过账之后不该再进系统调用");
	} finally {
		if (prev === undefined) delete process.env.DSH_HOME;
		else process.env.DSH_HOME = prev;
	}
});

test("ensureDir 建不出来也不抛（装配路径不能因此赔掉一个 agent step）", () => {
	const root = tmpDir("ensure-ro");
	const blocked = path.join(root, "file-in-the-way");
	fs.writeFileSync(blocked, "not a directory\n");
	const store = createMemoryStore({ dir: path.join(blocked, "memory") });
	assert.doesNotThrow(() => store.ensureDir(CWD));
	// 目录没建成，但索引照常返回空——这一步当作没有记忆。
	assert.deepEqual(store.index(CWD).entries, []);
});
