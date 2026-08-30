/**
 * Swift 载荷的**扫描与内容 hash**。桥与构建脚本共用的那一份算法。
 *
 * 抽出来只为一件事：`surf-app/host/scripts/prebuild-plugins.mjs`（分发计划 M3，
 * 预编译 dylib）必须算出**与桥逐字相同**的 contentHash——构建机上算的那个数
 * 就是用户机器上壳去 bundle 里找预编译产物时用的钥匙。抄成两份的话，抄错了
 * **不报错**：hash 对不上就静默退回现场编译，而用户机器上很可能根本没有 swiftc，
 * 症状是"插件全部缺席"。同 `./module-name.js` 的理由。
 *
 * **零依赖**（只用 node 内置）：构建脚本跑在 Xcode 的 build phase 里，
 * `@deepseek-ai/schemastery` 与 `ws` 未必解析得到。
 *
 * @module surf-bridge/swift-payload
 */
import { createHash } from "node:crypto";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, sep } from "node:path";

/** 只收这些扩展名进 snapshot——插件的 swift/ 目录里放别的都不算源码。 */
export const SOURCE_EXTENSIONS = [".swift"];

/** 轮询/扫描时跳过的目录名。 */
export const SKIP_DIRS = new Set([
	".git", ".build", "build", "DerivedData", ".DS_Store", "node_modules",
]);

/**
 * 「这份源码是分发载荷，进程活着的时候不会变」的标记文件。
 *
 * 由 `surf-app/host/scripts/pack-payload.mjs` 写进打包出来的每个
 * `SurfNode/<pkg>/swift/`，随镜像一路拷进 `<profile>/.surf/<pkg>/swift/`。
 * 桥据此**关掉对它的 500ms 轮询**（分发计划 §7.10）——正式形态下那是对一份
 * 只读载荷持续约 1 MB/s 的纯浪费。
 *
 * **判据是事实不是旋钮**：有这个文件 = 这份源码是 App 打包时写下的，
 * 唯一会改动它的是 App 自举，而自举跑在 dsh 起来之前。开发形态下的
 * `swift/` 是仓库工作区，没有这个文件，轮询照旧。
 */
export const STATIC_MARKER = ".surf-static";

/** 这个 swiftDir 是不是分发载荷（见 `STATIC_MARKER`）。 */
export function isStaticPayload(dir) {
	if (typeof dir !== "string") return false;
	return statSync(join(dir, STATIC_MARKER), { throwIfNoEntry: false })?.isFile() === true;
}

/** 目录扫描：签名（廉价）+ 文件内容（签名变了才用得上）。 */
export function scanSwiftDir(dir) {
	const files = {};
	const parts = [];
	for (const path of walk(dir)) {
		if (!SOURCE_EXTENSIONS.some((ext) => path.endsWith(ext))) continue;
		const rel = relative(dir, path).split(sep).join("/");
		let stats;
		try {
			stats = statSync(path);
		} catch {
			continue; // 扫描途中被删：当它不存在
		}
		parts.push(`${rel}:${stats.mtimeMs}:${stats.size}`);
		try {
			files[rel] = readFileSync(path, "utf8");
		} catch {
			continue;
		}
	}
	return { signature: parts.sort().join("|"), files };
}

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
		if (SKIP_DIRS.has(entry)) continue;
		yield* walk(join(path, entry));
	}
}

/**
 * 一个插件的 contentHash。
 *
 * **上游的 hash 折进下游的 hash**：上游一变下游必变，级联重编由数据结构保证，
 * 壳侧不需要任何传播逻辑（M2 断言 6 的沉默认知分裂由此杜绝）。
 *
 * 共享 module 只有**声明**进 hash——桥看不见 bundle 里的 `.swiftinterface`，
 * 那部分由壳的 `CompilerService` 另外折进去。
 *
 * 命令声明**刻意不进**（改一句菜单文案不该让 Swift 半边全量重编）。
 *
 * @param {{module: string, files?: Record<string,string>, swiftDeps?: string[],
 *          sharedModules?: string[]}} record
 * @param {(dep: string) => string|undefined} depHash 上游插件名 → 它的 contentHash
 */
export function swiftContentHash(record, depHash) {
	const hash = createHash("sha256");
	hash.update(record.module);
	hash.update("\0");
	for (const [path, content] of Object.entries(record.files ?? {}).sort(byKey)) {
		hash.update(path);
		hash.update("\0");
		hash.update(content);
		hash.update("\0");
	}
	for (const dep of record.swiftDeps ?? []) {
		hash.update(`dep:${dep}=${depHash(dep) ?? "missing"}\0`);
	}
	for (const module of record.sharedModules ?? []) hash.update(`shared:${module}\0`);
	return hash.digest("hex");
}

function byKey(a, b) {
	return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0;
}
