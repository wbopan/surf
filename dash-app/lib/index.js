/**
 * dash-app —— 壳源码与构建过程的插件化（阶段二计划 §7.5 v0）。
 *
 * 启动方向反转后 dsh 先于 app 存在，于是它就是壳天然的 bootstrapper：
 * 本插件的载荷是 `host/` 里的整个 Xcode 工程，activate 时做三件事——
 *
 *   1. 写 endpoint 发现文件（`~/Library/Application Support/io.wenbo.dash/endpoint.json`），
 *      让手动双击启动的 app 也能找到这个 dsh；fiber 卸载时删除。
 *   2. 源码 hash 变了或产物缺失 → xcodegen + xcodebuild（无 Xcode 则降级为只探测既有产物）。
 *   3. 产物存在且 app 尚未运行 → `open --args --dash-endpoint …` 拉起。
 *
 * 全程"优雅缺席"：构建失败、没有 Xcode、连既有产物都没有，都只在终端留一句话，
 * dsh 照常服务浏览器。失败不重试、不成环——防的是构建风暴。
 *
 * 桥（WS 双向通信）是 dash-bridge 的事，M4 再加；本插件只管把壳弄出来并告诉它 dsh 在哪。
 *
 * @module dash-app
 */
import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import z from "@deepseek-ai/schemastery";

export const name = "dash-app";

/** webServer 决定了 endpoint 里的 host/port，没有它这个插件无事可做。 */
export const inject = ["webServer"];

export const Config = z.object({
	configuration: z.union([z.const("Debug"), z.const("Release")]).default("Debug")
		.description("xcodebuild 配置。Debug 产物是 “dash Dev.app”，Release 是 “dash.app”。"),
	build: z.boolean().default(true)
		.description("源码 hash 变化或产物缺失时自动 xcodebuild；关掉则只探测既有产物。"),
	launch: z.boolean().default(true)
		.description("产物就绪且 app 尚未运行时自动拉起。"),
});

/** 壳的 Application Support 根目录，与 Swift 侧 `DashPaths.appSupport` 必须一致。 */
const APP_SUPPORT = join(homedir(), "Library", "Application Support", "io.wenbo.dash");

/** endpoint 发现文件；Swift 侧 `DashPaths.endpointURL`。 */
const ENDPOINT_FILE = join(APP_SUPPORT, "endpoint.json");

/** M4 的桥路径。M1 只写进发现文件、随 flag 透传，两侧都还没挂载它。 */
const BRIDGE_PATH = "/dash/bridge";

/** Xcode 工程载荷根（本包的 `host/`）。 */
const HOST_DIR = fileURLToPath(new URL("../host/", import.meta.url));

/** 参与源码 hash 的子树；`tools/`（xcodegen 二进制）与 `build/`（产物）不算源码。 */
const HASHED_ROOTS = ["project.yml", "Sources", "Packages", "scripts"];

/** 每次构建都会被 prebuild 脚本重写，进 hash 会让"源码没变"永远不成立。 */
const HASH_EXCLUDED = new Set(["Sources/Resources/BuildTimestamp.txt"]);

/** 目录名黑名单（构建中间产物与版本控制噪声）。 */
const HASH_SKIP_DIRS = new Set([".git", ".build", "build", "DerivedData", ".DS_Store"]);

/** 产物落点由 xcodebuild 的 `-derivedDataPath build` 固定（见仓库 CLAUDE.md 硬约束）。 */
const productPath = (configuration) =>
	join(HOST_DIR, "build", "Build", "Products", configuration,
		`${configuration === "Debug" ? "dash Dev" : "dash"}.app`);

/** 没有 Xcode 时的兜底产物：上次装到 /Applications 的 Release。 */
const INSTALLED_RELEASE = "/Applications/dash.app";

/** 上次构建时的源码 hash，与产物同处 build/ 下——产物被清掉时它一起消失，语义自洽。 */
const hashMarkerPath = (configuration) =>
	join(HOST_DIR, "build", `.dash-app-source-hash.${configuration}`);

export function apply(ctx, config) {
	const logger = reporter(ctx.logger("dash-app"));
	const httpBase = resolveHttpBase(ctx.webServer);

	// 先登记服务名，让下游 inject 能等；产物定下来后再 set 值。
	ctx.provide("dashApp", undefined);

	// 发现文件先于构建落地：一个手动启动的 app 立刻就能接入，
	// 不必等分钟级的首次构建。
	ctx.effect(() => {
		writeEndpointFile({ httpBase, logger });
		return () => removeEndpointFile(logger);
	}, "dash-app endpoint 发现文件");

	// 构建与拉起是长活，不能挂在 apply 的返回值上——那会把 dsh 的启动
	// 一起拖住（首次构建分钟级，浏览器这段时间将无人应答）。
	let disposed = false;
	ctx.effect(() => () => { disposed = true; }, "dash-app 构建/拉起");

	bootstrap({ ctx, config, logger, httpBase, isDisposed: () => disposed })
		.catch((error) => {
			// 到这儿说明是意料之外的异常（预期内的失败都已在内部记过日志并返回）。
			logger.warn(`dash-app 启动流程异常：${errorText(error)}`);
		});
}

/**
 * 同时喂 cordis logger 与终端。`dsh web` 默认不装 logger exporter
 * （消息只进环形缓冲），而本插件的进度是要给正蹲在终端等 app 弹出来的人看的，
 * 所以照 dsh 自己 `dsh web: <url>` 的样子直接写 stderr。
 */
function reporter(logger) {
	const emit = (level, message) => {
		logger[level](message);
		process.stderr.write(`dash-app: ${message}\n`);
	};
	return {
		info: (message) => emit("info", message),
		warn: (message) => emit("warn", message),
		error: (message) => emit("error", message),
	};
}

// ---------------------------------------------------------------- 主流程

async function bootstrap({ ctx, config, logger, httpBase, isDisposed }) {
	const { configuration } = config;
	const built = config.build
		? await ensureBuilt({ configuration, logger, isDisposed })
		: locateExistingProduct(configuration);

	if (isDisposed()) return;

	if (built.appPath === undefined) {
		logger.warn(`未找到可用的 ${configuration} 产物，${name} 优雅缺席——dsh 照常服务浏览器。`
			+ ` 需要 macOS 壳的话，在仓库里手动跑一次 dash-app/host/scripts/dev.sh。`);
		return;
	}

	ctx.set("dashApp", {
		appPath: built.appPath,
		freshness: built.freshness,
		configuration,
		httpBase,
		bridgePath: BRIDGE_PATH,
	});

	if (!config.launch) return;
	await launch({ appPath: built.appPath, httpBase, logger });
}

/**
 * 保证 `configuration` 的产物是新的：hash 没变且产物在 → 直接用；
 * 否则跑一遍 xcodegen + xcodebuild。没有 Xcode 时退化为只探测既有产物。
 */
async function ensureBuilt({ configuration, logger, isDisposed }) {
	const product = productPath(configuration);
	const hash = hashSources();
	const marker = hashMarkerPath(configuration);

	if (hash !== undefined && existsSync(product) && readTextOrUndefined(marker) === hash) {
		logger.info(`${configuration} 产物已是最新（源码 hash ${hash.slice(0, 12)}），跳过构建。`);
		return { appPath: product, freshness: "cached" };
	}

	if (!(await hasXcode())) {
		logger.warn("未检测到完整 Xcode（xcodebuild 不可用，Command Line Tools 不够），跳过构建，只找既有产物。");
		return locateExistingProduct(configuration);
	}

	logger.info(`壳源码有变动，开始构建 ${configuration}（首次约需分钟级）…`);
	const startedAt = Date.now();
	const buildLog = join(APP_SUPPORT, "logs", `dash-app-build.${configuration}.log`);
	mkdirSync(dirname(buildLog), { recursive: true });

	try {
		// dev.sh 的同一套步骤：时间戳文件不入库，须在 generate 扫描目录前落地。
		await run(join(HOST_DIR, "scripts", "write-build-timestamp.sh"), [], HOST_DIR);
		if (isDisposed()) return { appPath: undefined, freshness: "missing" };
		await run(join(HOST_DIR, "tools", "xcodegen"), ["generate"], HOST_DIR);
		if (isDisposed()) return { appPath: undefined, freshness: "missing" };
		// -derivedDataPath build 是硬约束：产物必须落在 build/Build/Products/，
		// 换位置会造成“BUILD SUCCEEDED 但改动永不生效”。
		const result = await run("xcodebuild", [
			"-project", join(HOST_DIR, "dash.xcodeproj"),
			"-scheme", "dash",
			"-configuration", configuration,
			"-derivedDataPath", "build",
			"build",
		], HOST_DIR, { maxBuffer: 64 * 1024 * 1024 });
		writeFileSync(buildLog, result.stdout + result.stderr);
	} catch (error) {
		// 完整日志落文件，终端只留结论 + 尾巴几行——xcodebuild 的输出淹没 dsh 终端没有意义。
		const detail = `${error?.stdout ?? ""}${error?.stderr ?? ""}` || errorText(error);
		writeFileSync(buildLog, detail);
		logger.error(`构建 ${configuration} 失败（不重试）。完整日志：${buildLog}\n${tail(detail, 20)}`);
		return locateExistingProduct(configuration);
	}

	if (!existsSync(product)) {
		logger.error(`xcodebuild 报成功但产物不在 ${product}，放弃（不重试）。`);
		return locateExistingProduct(configuration);
	}
	if (hash !== undefined) writeFileSync(marker, hash);
	logger.info(`${configuration} 构建完成，用时 ${((Date.now() - startedAt) / 1000).toFixed(1)}s：${product}`);
	return { appPath: product, freshness: "fresh" };
}

/** 不构建时的产物探测：先本地 build/，再 /Applications 的 Release 安装。 */
function locateExistingProduct(configuration) {
	const product = productPath(configuration);
	if (existsSync(product)) return { appPath: product, freshness: "prebuilt" };
	if (existsSync(INSTALLED_RELEASE)) return { appPath: INSTALLED_RELEASE, freshness: "prebuilt" };
	return { appPath: undefined, freshness: "missing" };
}

/**
 * 拉起 app 并把 endpoint 从命令行递给它（三级定位的第一级）。
 * 已在运行则跳过——防双开；`open` 不带 `-n`，即使这里判断失误，
 * 最坏结果也只是把已有窗口带到前台，而不是开出第二个实例。
 */
async function launch({ appPath, httpBase, logger }) {
	if (await isRunning(appPath)) {
		logger.info(`dash 已在运行（${appPath}），跳过拉起；它会自己从发现文件接入。`);
		return;
	}
	try {
		await run("open", [appPath, "--args",
			"--dash-endpoint", httpBase,
			"--dash-bridge-path", BRIDGE_PATH], HOST_DIR);
		logger.info(`已拉起 dash：${appPath} → ${httpBase}`);
	} catch (error) {
		logger.error(`拉起 dash 失败（不重试）：${errorText(error)}`);
	}
}

// ---------------------------------------------------------------- endpoint 文件

/** webServer 绑 0.0.0.0 时对 app 而言仍是 loopback——它总在同一台机器上。 */
function resolveHttpBase(webServer) {
	const host = webServer.host === "0.0.0.0" ? "127.0.0.1" : webServer.host;
	return `http://${host}:${webServer.port}`;
}

/** 原子写：先写临时文件再 rename，app 永远读不到半截 JSON。 */
function writeEndpointFile({ httpBase, logger }) {
	const payload = {
		httpBase,
		bridgePath: BRIDGE_PATH,
		pid: process.pid,
		startedAt: new Date().toISOString(),
		profile: resolveProfileName(),
	};
	try {
		mkdirSync(APP_SUPPORT, { recursive: true });
		const tmp = `${ENDPOINT_FILE}.${process.pid}.tmp`;
		writeFileSync(tmp, `${JSON.stringify(payload, undefined, "\t")}\n`);
		renameSync(tmp, ENDPOINT_FILE);
		logger.info(`endpoint 发现文件已写入：${ENDPOINT_FILE} → ${httpBase}`);
	} catch (error) {
		logger.warn(`写 endpoint 发现文件失败（手动启动的 app 将找不到本进程）：${errorText(error)}`);
	}
}

/** 只删自己写的那一份：两个 dsh 并存时，先退的不该把后来者的文件删掉。 */
function removeEndpointFile(logger) {
	try {
		const raw = readTextOrUndefined(ENDPOINT_FILE);
		if (raw === undefined) return;
		if (JSON.parse(raw)?.pid !== process.pid) return;
		rmSync(ENDPOINT_FILE, { force: true });
	} catch (error) {
		logger.warn(`清理 endpoint 发现文件失败：${errorText(error)}`);
	}
}

/**
 * profile 名。dsh 不把它放进环境变量，只能从 argv 反推
 * （`dsh web` 是 `--profile web` 的别名）——纯诊断字段，取不到就留空。
 */
function resolveProfileName() {
	const argv = process.argv.slice(2);
	const flag = argv.indexOf("--profile");
	if (flag >= 0 && argv[flag + 1] !== undefined) return argv[flag + 1];
	if (argv.includes("web")) return "web";
	return undefined;
}

// ---------------------------------------------------------------- 源码 hash

/**
 * 壳源码的内容 hash：路径 + 内容一起摘要，与 mtime 无关
 * （git checkout 换分支不该被误判成"改过"）。任一步出错返回 undefined，
 * 调用方据此退化为"每次都构建"，而不是错误地判定"没变"。
 */
function hashSources() {
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

// ---------------------------------------------------------------- 子进程

function run(file, args, cwd, options = {}) {
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

/** 完整 Xcode 才有 xcodebuild；Command Line Tools 单独装是不够的。 */
async function hasXcode() {
	try {
		await run("xcodebuild", ["-version"], HOST_DIR);
		return true;
	} catch {
		return false;
	}
}

/** 按可执行文件路径认进程（同 dev.sh），Debug/Release 名字不同不会互相误伤。 */
async function isRunning(appPath) {
	try {
		await run("pgrep", ["-f", `${appPath}/Contents/MacOS/`], HOST_DIR);
		return true;
	} catch {
		return false;
	}
}

// ---------------------------------------------------------------- 杂项

function readTextOrUndefined(path) {
	try {
		return readFileSync(path, "utf8");
	} catch {
		return undefined;
	}
}

function tail(text, lines) {
	return text.trimEnd().split("\n").slice(-lines).join("\n");
}

function errorText(error) {
	return error instanceof Error ? error.message : String(error);
}
