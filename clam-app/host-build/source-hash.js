/**
 * 壳源码的内容 hash 与「上次构建到哪个 hash」的账本路径。
 *
 * **住在 `host-build/` 而不是 `lib/`**：`lib/` 是随包分发的那一半，而算源码 hash
 * 只在"壳源码在场"时有意义（`docs/archive/distribution-plan.md` §3.3）。整个目录不进
 * `files` 白名单、也不进 App 的 `ClamNode/` 载荷。
 *
 * **单独成模块，只为一件事：`host/scripts/build.sh` 也要写这份账。**
 * 手跑一次 `build.sh`（或 `./release` 里的那一步）之后，常驻 dsh 那半边
 * （`host-build/index.js` 的盯源码重建）必须知道"这个 hash 已经构建过了"，否则它一起来就把刚装好的那份原样再编一遍。
 * 让 bash 自己算一遍 sha256 就是把算法抄成两份——抄错了不报错，
 * 症状是每次 `./release` 之后 daemon 都白编一次。
 *
 * 零依赖（只用 node 内置），因为 build.sh 可能跑在还没 link 过 node_modules 的
 * 新 worktree 里；那边 `import "@deepseek-ai/schemastery"` 会直接炸。
 *
 * 命令行两个查询子命令（build.sh 用，自己不写文件）：
 *
 * ```sh
 * node host-build/source-hash.js hash            # 打印当前源码 hash，算不出来则退出码 1
 * node host-build/source-hash.js marker Release  # 打印该配置的 marker 路径
 * ```
 *
 * @module clam-app/host-build/source-hash
 */
import { createHash } from "node:crypto";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/** Xcode 工程载荷根（本包的 `host/`）。`host-build/` 与 `host/` 是兄弟。 */
export const HOST_DIR = fileURLToPath(new URL("../host/", import.meta.url));

/** 参与源码 hash 的子树；`tools/`（xcodegen 二进制）与 `build/`（产物）不算源码。 */
const HASHED_ROOTS = ["project.yml", "Sources", "scripts", "Icons"];

/** 每次构建都会被 prebuild 脚本重写，进 hash 会让"源码没变"永远不成立。 */
const HASH_EXCLUDED = new Set(["Sources/Resources/BuildTimestamp.txt"]);

/** 目录名黑名单（构建中间产物与版本控制噪声）。 */
const HASH_SKIP_DIRS = new Set([".git", ".build", "build", "DerivedData", ".DS_Store"]);

/** 上次构建时的源码 hash，与产物同处 build/ 下——产物被清掉时它一起消失，语义自洽。 */
export const hashMarkerPath = (configuration) =>
	join(HOST_DIR, "build", `.clam-app-source-hash.${configuration}`);

/**
 * 壳源码的内容 hash：路径 + 内容一起摘要，与 mtime 无关
 * （git checkout 换分支不该被误判成"改过"）。任一步出错返回 undefined，
 * 调用方据此退化为"每次都构建"，而不是错误地判定"没变"。
 */
export function hashSources() {
	try {
		const hash = createHash("sha256");
		for (const root of HASHED_ROOTS) {
			for (const file of walk(join(HOST_DIR, root))) {
				const rel = relative(HOST_DIR, file);
				if (HASH_EXCLUDED.has(rel)) continue;
				hash.update(rel);
				hash.update("\0");
				hash.update(readFileSync(file));
				hash.update("\0");
			}
		}
		return hash.digest("hex");
	} catch {
		return undefined;
	}
}

/**
 * 廉价签名：只 stat 不读内容。轮询每一拍都跑它，签名没变就省下整棵树的 readFile。
 * 与 `hashSources` 用同一套根与排除项——两者对"什么算源码"的看法必须一致。
 */
export function signatureSources() {
	try {
		const parts = [];
		for (const root of HASHED_ROOTS) {
			for (const file of walk(join(HOST_DIR, root))) {
				const rel = relative(HOST_DIR, file);
				if (HASH_EXCLUDED.has(rel)) continue;
				const stats = statSync(file);
				parts.push(`${rel}:${stats.mtimeMs}:${stats.size}`);
			}
		}
		return parts.join("|");
	} catch {
		// 扫描出错就返回空串：与"上一次的签名"必然不同，退化为多算一次 hash。
		return "";
	}
}

/** 确定序遍历（readdirSync 已按名排序，逐层排序保证跨机一致）。 */
function* walk(path) {
	let stats;
	try {
		stats = statSync(path);
	} catch {
		return;
	}
	if (stats.isFile()) {
		yield path;
		return;
	}
	if (!stats.isDirectory()) return;
	for (const entry of readdirSync(path).sort()) {
		if (HASH_SKIP_DIRS.has(entry)) continue;
		yield* walk(join(path, entry));
	}
}

// ---------------------------------------------------------------- CLI

// 只在被直接执行时跑（`import` 进来的不受影响）。
if (process.argv[1] !== undefined
	&& fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
	const [command, argument] = process.argv.slice(2);
	if (command === "hash") {
		const hash = hashSources();
		if (hash === undefined) process.exit(1);
		process.stdout.write(hash);
	} else if (command === "marker") {
		if (argument !== "Debug" && argument !== "Release") {
			process.stderr.write("用法：source-hash.js marker <Debug|Release>\n");
			process.exit(2);
		}
		process.stdout.write(hashMarkerPath(argument));
	} else {
		process.stderr.write("用法：source-hash.js hash | source-hash.js marker <Debug|Release>\n");
		process.exit(2);
	}
}
