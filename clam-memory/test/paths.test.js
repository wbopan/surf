// clam-memory 路径决议与路径加固的单测。零依赖，`node --test`。
//
//   node --test clam-memory/test/*.test.js
//
// **别省那个通配符**：给 `--test` 一个目录在 node 26 上会 MODULE_NOT_FOUND。
//
// 本文件只**读**真实 ~/.claude / ~/.dsh 的路径字符串，绝不往里写东西。

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
	dshHome,
	expandHome,
	fileFor,
	gitRootFor,
	memoryDirFor,
	mkdirp700,
	NAME_MAX,
	resolveInside,
	slugFor,
	validateName,
} from "../lib/paths.js";

function tmpRoot(tag) {
	return fs.mkdtempSync(path.join(os.tmpdir(), `clam-memory-${tag}-`));
}

// ── slug ─────────────────────────────────────────────────────────────────────
// §2.5 风险 1：算错了不会报错，只会在 Claude 旁边安静地建一个空目录。

test("slugFor 与本机真实的 Claude 目录名逐字节一致", () => {
	// 这个断言与机器无关：路径存在时 gitRootFor 停在含 .git 的 surfclam 本身，
	// 不存在时一路走到 / 再退回原路径——两条路给出同一个字符串。
	assert.equal(slugFor("/Users/wenbopan/Repos/surfclam"), "-Users-wenbopan-Repos-surfclam");
	// 以 `-` 开头不是笔误，是 Claude 的实际格式。
	assert.ok(slugFor("/Users/wenbopan/Repos/surfclam").startsWith("-"));
});

test("git worktree 里 .git 是文件，slug 用 worktree 自己的根", () => {
	const root = fs.realpathSync(tmpRoot("wt"));
	const repo = path.join(root, "repo");
	const wt = path.join(repo, ".claude", "worktrees", "feature-x");
	fs.mkdirSync(path.join(repo, ".git"), { recursive: true });
	fs.mkdirSync(path.join(wt, "src"), { recursive: true });
	// worktree 的 .git 是一行 `gitdir: …` 的**文件**
	fs.writeFileSync(path.join(wt, ".git"), `gitdir: ${repo}/.git/worktrees/feature-x\n`);

	assert.equal(gitRootFor(path.join(wt, "src")), wt, "含 .git 文件的那一级就是根，不跟着 gitdir 再跳");
	assert.equal(slugFor(path.join(wt, "src")), wt.split(path.sep).join("-"));
	// 本机实测佐证：~/.claude/projects/ 里 worktree 与主仓库各有独立 slug。
	assert.notEqual(slugFor(path.join(wt, "src")), slugFor(repo));
});

test("不在 git 仓库里就退回 cwd 本身", () => {
	const root = fs.realpathSync(tmpRoot("nogit"));
	const deep = path.join(root, "a", "b");
	fs.mkdirSync(deep, { recursive: true });
	// tmpdir 之上不可能有 .git；真有的话这条断言会明确报出来而不是静默走偏
	assert.equal(gitRootFor(deep), deep);
});

// ── 三种 dir 模式 ─────────────────────────────────────────────────────────────

test("dir 缺省 → <dshHome>/memory/<slug>", () => {
	const prev = process.env.DSH_HOME;
	try {
		process.env.DSH_HOME = "/tmp/fake-dsh-home";
		assert.equal(
			memoryDirFor({ dir: "", cwd: "/Users/wenbopan/Repos/surfclam" }),
			"/tmp/fake-dsh-home/memory/-Users-wenbopan-Repos-surfclam",
		);
		assert.equal(
			memoryDirFor({ cwd: "/Users/wenbopan/Repos/surfclam" }),
			"/tmp/fake-dsh-home/memory/-Users-wenbopan-Repos-surfclam",
		);
		delete process.env.DSH_HOME;
		assert.equal(dshHome(), path.join(os.homedir(), ".dsh"));
	} finally {
		if (prev === undefined) delete process.env.DSH_HOME;
		else process.env.DSH_HOME = prev;
	}
});

test('dir === "claude" → ~/.claude/projects/<slug>/memory', () => {
	assert.equal(
		memoryDirFor({ dir: "claude", cwd: "/Users/wenbopan/Repos/surfclam" }),
		path.join(os.homedir(), ".claude", "projects", "-Users-wenbopan-Repos-surfclam", "memory"),
	);
});

test("dir 是别的值 → 当绝对路径用，展开前导 ~", () => {
	assert.equal(memoryDirFor({ dir: "/srv/mem", cwd: "/anything" }), "/srv/mem");
	assert.equal(memoryDirFor({ dir: "~/mem", cwd: "/anything" }), path.join(os.homedir(), "mem"));
	assert.equal(expandHome("~"), os.homedir());
	assert.equal(expandHome("/a/~/b"), "/a/~/b", "只认前导波浪号");
});

// ── 路径加固 ─────────────────────────────────────────────────────────────────

test("符号链接逃逸被拒（前缀比较挡不住它）", () => {
	const root = fs.realpathSync(tmpRoot("escape"));
	const mem = path.join(root, "memory");
	const outside = path.join(root, "outside");
	fs.mkdirSync(mem);
	fs.mkdirSync(outside);
	fs.writeFileSync(path.join(outside, "secret.md"), "boo\n");

	// 这两个的**字符串前缀**都在 mem 底下，只有解完链接才看得出来它们不在。
	fs.symlinkSync(path.join(outside, "secret.md"), path.join(mem, "escape.md"));
	fs.symlinkSync(outside, path.join(mem, "away"));

	assert.throws(() => resolveInside(mem, "escape.md"), /Path escape/);
	assert.throws(() => resolveInside(mem, "away/secret.md"), /Path escape/);
	assert.throws(() => resolveInside(mem, "../outside/secret.md"), /Path escape/);
	assert.throws(() => resolveInside(mem, "."), /resolves to the memory directory itself/);

	// 正常的、还不存在的文件应当解得出来（realpathDeep 要能处理不存在的尾巴）
	assert.equal(resolveInside(mem, "ok.md"), path.join(mem, "ok.md"));
});

test("fileFor 拼出 <root>/<name>.md 并带上校验", () => {
	const root = fs.realpathSync(tmpRoot("filefor"));
	assert.equal(fileFor(root, "build-notes"), path.join(root, "build-notes.md"));
	assert.throws(() => fileFor(root, "Bad Name"), /may only contain lowercase/);
});

test("validateName 的每条拒绝理由", () => {
	assert.equal(validateName("build-notes_2"), "build-notes_2");

	assert.throws(() => validateName(""), /cannot be empty/);
	assert.throws(() => validateName(undefined), /cannot be empty/);
	assert.throws(() => validateName("a\0b"), /null byte/);
	assert.throws(() => validateName("a/b"), /path separator/);
	assert.throws(() => validateName("a\\b"), /path separator/);
	assert.throws(() => validateName(".."), /\.\./);
	assert.throws(() => validateName("../etc/passwd"), /path separator|\.\./);
	assert.throws(() => validateName(".hidden"), /cannot start with/);
	// 保留名：防模型覆盖 Claude 目录里那个被废弃的磁盘索引
	assert.throws(() => validateName("MEMORY"), /reserved name/);
	assert.throws(() => validateName("memory"), /reserved name/);
	assert.throws(() => validateName("x".repeat(NAME_MAX + 1)), /at most 60 characters/);
	assert.equal(validateName("x".repeat(NAME_MAX)).length, NAME_MAX);
	assert.throws(() => validateName("UPPER"), /may only contain lowercase/);
	assert.throws(() => validateName("has space"), /may only contain lowercase/);
	assert.throws(() => validateName("dot.name"), /may only contain lowercase/);
});

test("mkdirp700 逐级 0o700（recursive+mode 只管叶子）", () => {
	const root = fs.realpathSync(tmpRoot("mkdir"));
	const deep = path.join(root, "a", "b", "c");
	mkdirp700(deep);
	for (const p of [path.join(root, "a"), path.join(root, "a", "b"), deep]) {
		assert.equal(fs.statSync(p).mode & 0o777, 0o700, `${p} 应当是 0700`);
	}
	mkdirp700(deep); // 幂等
	assert.ok(fs.existsSync(deep));
});
