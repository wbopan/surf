// clam-memory 的路径决议。
//
// 硬约束（docs/clam-memory-plan.md §0）：**零依赖**——只用 node 内置模块，
// 不 import 任何 clam-* 也不 import @deepseek-ai/*。这个文件必须能在
// 一台只有 node 的 Linux 机器上原样跑起来。
//
// 两件事：
//   1. 目录决议（三种 dir 模式 + slug）
//   2. slug = git repo root 的绝对路径把 `/` 换成 `-`（与 Claude Code 逐字节一致，
//      §2.5 风险 1：算错会在 Claude 旁边安静地建一个空目录）
//
// **曾经还有第三件事：路径加固**（名字白名单 + 逐级 realpath 的逃逸检查，思路抄
// anthropic-sdk-typescript 的 src/tools/memory/node.ts）。2026-08-30 随两个专用工具
// 一起删了——加固的对象是"模型交给我们的名字"，而现在模型不再交名字，它直接用
// `write` / `edit` 操作文件，路径归 dsh 的工具沙箱管。留着就是没有调用者的死代码。
// `mkdirp700` 留下了：store 的 ensureDir 还要用它。

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

/** 展开前导 `~`。只认前导，`a/~/b` 里的波浪号是普通字符。 */
export function expandHome(p) {
	if (typeof p !== "string" || p.length === 0) return p;
	if (p === "~") return os.homedir();
	if (p.startsWith("~/")) return path.join(os.homedir(), p.slice(2));
	return p;
}

/**
 * dsh 的 home。
 * **故意不 import `@deepseek-ai/dsh-home-paths`**——存储层要保持零依赖（§0.0）。
 * 决议规则与它一致：`DSH_HOME` 优先，否则 `~/.dsh`。
 */
export function dshHome() {
	const env = process.env.DSH_HOME;
	if (typeof env === "string" && env.trim() !== "") return path.resolve(expandHome(env.trim()));
	return path.join(os.homedir(), ".dsh");
}

/**
 * 从 cwd 逐级向上找 git repo root（含 `.git` 的目录）。
 *
 * `.git` **可以是文件**——git worktree 里它是一行 `gitdir: …` 的文本文件。
 * 本机实测（`ls ~/.claude/projects/`）证实 Claude Code 对 worktree 用的是
 * **worktree 自己的根**而不是主仓库根：`.claude/worktrees/<x>` 各有独立 slug。
 * 所以"含 .git 就停"是对的，不要跟着 gitdir 再跳一次。
 *
 * 找不到就返回 cwd 本身（§2.5）。
 */
export function gitRootFor(cwd) {
	let cur = path.resolve(cwd || process.cwd());
	for (;;) {
		let hit = false;
		try {
			fs.statSync(path.join(cur, ".git"));
			hit = true;
		} catch {
			hit = false;
		}
		if (hit) return cur;
		const parent = path.dirname(cur);
		if (parent === cur) return path.resolve(cwd || process.cwd());
		cur = parent;
	}
}

/**
 * slug = git repo root 绝对路径的每个 `/` 换成 `-`。
 * 结果以 `-` 开头（`/Users/x/y` → `-Users-x-y`），这不是笔误，是 Claude 的实际格式。
 */
export function slugFor(cwd) {
	const root = gitRootFor(cwd);
	return root.split(path.sep).join("-");
}

/**
 * 解出本次该用哪个记忆目录（§2.5）。**只算路径，不创建。**
 *
 *   ""/undefined → <dshHome>/memory/<slug>/
 *   "claude"     → ~/.claude/projects/<slug>/memory/
 *   其它          → 当绝对路径用（展开 `~`）
 */
export function memoryDirFor({ dir, cwd } = {}) {
	const raw = typeof dir === "string" ? dir.trim() : "";
	if (raw === "") return path.join(dshHome(), "memory", slugFor(cwd));
	if (raw === "claude") return path.join(os.homedir(), ".claude", "projects", slugFor(cwd), "memory");
	return path.resolve(expandHome(raw));
}

/**
 * 逐级建目录，每级 0o700。
 * **不能用 `mkdirSync(dir, { recursive: true, mode })`**：那个 mode 只作用在叶子上，
 * 中间层拿的是 umask 默认值（记忆可能含私密内容，不该 world-readable）。
 */
export function mkdirp700(dir) {
	const abs = path.resolve(dir);
	const missing = [];
	let cur = abs;
	for (;;) {
		if (fs.existsSync(cur)) break;
		missing.unshift(cur);
		const parent = path.dirname(cur);
		if (parent === cur) break;
		cur = parent;
	}
	for (const seg of missing) {
		try {
			fs.mkdirSync(seg, { mode: 0o700 });
		} catch (err) {
			if (!err || err.code !== "EEXIST") throw err;
		}
	}
	return abs;
}
