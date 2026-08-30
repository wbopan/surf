/**
 * clam-app 两半边共用的几个小工具。
 *
 * **这份是随包分发的**（`files` 白名单里的 `lib/`），所以只放"两边都要用"的东西
 * ——`run` / `errorText` / `readTextOrUndefined` / `delay`。只有构建那半边用得上的
 * （`tail`、hash、xcodebuild 那一套）一律住在 `clam-app/host-build/`，
 * 那个目录**不进包**（`docs/archive/distribution-plan.md` §3.3）。
 *
 * 单独成模块只为一个理由：`lib/index.js` 与 `host-build/index.js` 之间不能有静态
 * 循环依赖——前者 `await import()` 后者，后者要是反过来 `import` 前者就成了环。
 *
 * @module clam-app/util
 */
import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";

/**
 * `execFile` 的 Promise 包装。**`cwd` 是必填的**，因为这个包里两种调用的 cwd
 * 政策截然不同：
 *
 *  - 构建那几条（xcodegen / xcodebuild / write-build-timestamp.sh）必须站在
 *    `HOST_DIR` 里；
 *  - `open` / `pgrep` / `xcodebuild -version` 对 cwd 毫无依赖，站在家目录就行。
 *
 * 曾经所有调用点都无脑传 `HOST_DIR`，那在**壳源码不在场的形态下会把不相干的命令
 * 一起毒死**——`HOST_DIR` 不存在，`execFile` 连 `open` / `pgrep` 都起不来，
 * 报的却是 `spawn open ENOENT`（ENOENT 说的是 cwd，不是那个二进制）。
 * 实测症状链：`pgrep` 静默失败 → `isRunning` 恒假 → 明明 App 正跑着还要 `open`
 * 一次 → `open` 自己也 ENOENT → 日志里一句"拉起 surfclam 失败"，而 App 好端端的。
 */
export function run(file, args, cwd, options = {}) {
	return new Promise((resolve, reject) => {
		execFile(file, args, { cwd, maxBuffer: 8 * 1024 * 1024, ...options }, (error, stdout, stderr) => {
			if (error) {
				error.stdout = stdout;
				error.stderr = stderr;
				reject(error);
				return;
			}
			resolve({ stdout, stderr });
		});
	});
}

export function readTextOrUndefined(path) {
	try {
		return readFileSync(path, "utf8");
	} catch {
		return undefined;
	}
}

export function delay(ms) {
	return new Promise((resolve) => { setTimeout(resolve, ms).unref?.(); });
}

/**
 * profile 名。dsh 不把它放进环境变量，只能从 argv 反推
 * （`dsh web` 是 `--profile web` 的别名）。
 *
 * 两半边都要它：`lib/index.js` 拿它给 endpoint 发现文件分片，
 * `host-build/index.js` 拿它给构建日志分片。取不到时调用方必须有兜底
 * ——这里仍然只负责如实返回 undefined。
 */
export function resolveProfileName() {
	const argv = process.argv.slice(2);
	const flag = argv.indexOf("--profile");
	if (flag >= 0 && argv[flag + 1] !== undefined) return argv[flag + 1];
	if (argv.includes("web")) return "web";
	return undefined;
}

export function errorText(error) {
	return error instanceof Error ? error.message : String(error);
}
