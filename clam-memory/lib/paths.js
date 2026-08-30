// clam-memory 的路径决议与路径加固。
//
// 硬约束（docs/clam-memory-plan.md §0）：**零依赖**——只用 node 内置模块，
// 不 import 任何 clam-* 也不 import @deepseek-ai/*。这个文件必须能在
// 一台只有 node 的 Linux 机器上原样跑起来。
//
// 三件事：
//   1. 目录决议（三种 dir 模式 + slug）
//   2. slug = git repo root 的绝对路径把 `/` 换成 `-`（与 Claude Code 逐字节一致，
//      §2.5 风险 1：算错会在 Claude 旁边安静地建一个空目录）
//   3. 路径加固（名字白名单 + 逐级 realpath 的逃逸检查 + 逐级 0o700 mkdir），
//      思路抄 anthropic-sdk-typescript 的 src/tools/memory/node.ts

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

/** 名字上限（§3）。 */
export const NAME_MAX = 60;

/** 合法名字：扁平命名空间，没有子目录 = 路径穿越这一整类 bug 不存在（§2.1）。 */
const NAME_RE = /^[a-z0-9_-]+$/;

/**
 * 保留名。`MEMORY.md` 是 Claude Code 那条**被废弃的**磁盘索引路径的残留（§1.3），
 * 拒绝它是为了防模型覆盖掉人家的历史文件。比对不区分大小写。
 */
const RESERVED_NAMES = new Set(["memory"]);

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
 * 校验一条记忆的名字。非法就抛——错误信息是给模型看的，要说清怎么改。
 */
export function validateName(name) {
	if (typeof name !== "string" || name.length === 0) {
		throw new Error("A memory name cannot be empty. Use lowercase kebab-case, e.g. `build-uses-xcodegen`.");
	}
	if (name.includes("\0")) {
		throw new Error("A memory name cannot contain a null byte.");
	}
	if (name.includes("/") || name.includes("\\")) {
		throw new Error(`A memory name cannot contain a path separator (got \`${name}\`). Memories are flat; there are no subdirectories.`);
	}
	if (name === "." || name === ".." || name.includes("..")) {
		throw new Error(`A memory name cannot contain \`..\` (got \`${name}\`).`);
	}
	if (name.startsWith(".")) {
		throw new Error(`A memory name cannot start with \`.\` (got \`${name}\`).`);
	}
	if (RESERVED_NAMES.has(name.toLowerCase())) {
		throw new Error(`\`${name}\` is a reserved name and cannot be used.`);
	}
	if (name.length > NAME_MAX) {
		throw new Error(`A memory name is at most ${NAME_MAX} characters (got ${name.length}).`);
	}
	if (!NAME_RE.test(name)) {
		throw new Error(`A memory name may only contain lowercase letters, digits, \`-\` and \`_\` (got \`${name}\`).`);
	}
	return name;
}

/**
 * 把 `p` 逐级 realpath：从最深的**已存在**祖先开始解，把剩下那截不存在的尾巴拼回去。
 * 纯前缀比较挡不住 `<root>/foo -> /etc` 这种符号链接逃逸，必须真的解一次。
 */
function realpathDeep(p) {
	let cur = path.resolve(p);
	const tail = [];
	for (;;) {
		try {
			const real = fs.realpathSync(cur);
			return tail.length === 0 ? real : path.join(real, ...tail);
		} catch (err) {
			if (err && err.code !== "ENOENT" && err.code !== "ENOTDIR") throw err;
			const parent = path.dirname(cur);
			if (parent === cur) return tail.length === 0 ? cur : path.join(cur, ...tail);
			tail.unshift(path.basename(cur));
			cur = parent;
		}
	}
}

/**
 * 把 `child` 拼到 `root` 底下，并断言它**真的**还在 root 之下（解完符号链接之后）。
 * 两边都走同一套 realpathDeep，所以 `/tmp` 与 `/private/tmp` 这种系统级链接不会误判。
 */
export function resolveInside(root, child) {
	if (typeof child !== "string" || child.length === 0 || child.includes("\0")) {
		throw new Error("Invalid memory path component.");
	}
	const rootReal = realpathDeep(root);
	const targetReal = realpathDeep(path.resolve(root, child));
	if (targetReal !== rootReal && !targetReal.startsWith(rootReal + path.sep)) {
		throw new Error(`Path escape: \`${child}\` resolves outside the memory directory.`);
	}
	if (targetReal === rootReal) {
		throw new Error(`\`${child}\` resolves to the memory directory itself.`);
	}
	return targetReal;
}

/** 一条记忆的文件路径（含校验与逃逸检查）。 */
export function fileFor(root, name) {
	validateName(name);
	return resolveInside(root, `${name}.md`);
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
