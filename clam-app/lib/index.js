/**
 * clam-app —— 壳源码与构建过程的插件化（阶段二计划 §7.5 v0）。
 *
 * 启动方向反转后 dsh 先于 app 存在，于是它就是壳天然的 bootstrapper：
 * 本插件的载荷是 `host/` 里的整个 Xcode 工程，activate 时做三件事——
 *
 *   1. 写 endpoint 发现文件（`~/Library/Application Support/io.wenbo.surfclam/endpoint.json`），
 *      让手动双击启动的 app 也能找到这个 dsh；fiber 卸载时删除。
 *   2. 源码 hash 变了或产物缺失 → xcodegen + xcodebuild（无 Xcode 则降级为只探测既有产物）。
 *   3. 产物存在且 app 尚未运行 → `open --args --clam-endpoint …` 拉起。
 *
 * 起来之后还盯着壳源码（v1，§7.5）：变了就后台重建，经桥播报
 * `app-build`；壳把它变成一条"有新版，重启生效"的横幅。**重建不等于重启**——
 * 壳重启是重循环（进程退出、页面状态丢失），时机归用户，默认只提示。
 * 运行中的 app bundle 被覆盖在 macOS 上是安全的（旧进程继续跑旧映像）。
 *
 * 全程"优雅缺席"：构建失败、没有 Xcode、连既有产物都没有，都只在终端留一句话，
 * dsh 照常服务浏览器。首次构建失败不重试、不成环——防的是构建风暴；
 * 盯文件的重建则由"源码又变了"驱动，天然不会自己转圈。
 *
 * @module clam-app
 */
import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import z from "@deepseek-ai/schemastery";

export const name = "clam-app";

/** webServer 决定了 endpoint 里的 host/port，没有它这个插件无事可做。 */
export const inject = ["webServer"];

export const Config = z.object({
	configuration: z.union([z.const("Debug"), z.const("Release")]).default("Debug")
		.description("xcodebuild 配置。Debug 产物是 “Surfclam Dev.app”，Release 是 “Surfclam.app”。"),
	build: z.boolean().default(true)
		.description("源码 hash 变化或产物缺失时自动 xcodebuild；关掉则只探测既有产物。"),
	launch: z.boolean().default(true)
		.description("产物就绪且 app 尚未运行时自动拉起。"),
	watch: z.boolean().default(true)
		.description("dsh 运行期间盯着壳源码，变了就后台重建并经桥提示「有新版」。需要 build 也开着。"),
	watchIntervalMs: z.number().step(1).min(300).default(2000)
		.description("盯壳源码的轮询间隔。先比 mtime/size 签名，签名变了才读内容算 hash。"),
	restartOnRebuild: z.boolean().default(false)
		.description("重建成功后不等用户点，直接让壳退出并重拉（开发期方便，会丢页面状态）。"),
});

/** 壳的 Application Support 根目录，与 Swift 侧 `ClamPaths.appSupport` 必须一致。 */
const APP_SUPPORT = join(homedir(), "Library", "Application Support", "io.wenbo.surfclam");

/**
 * endpoint 发现文件的目录；Swift 侧 `ClamPaths.endpointsDir`。
 *
 * **一个 profile 一份**（`endpoints/<profile>.json`），不是全局单文件：
 * 一台机器上可以同时跑好几个 dsh——每个 git worktree 一套插件、一个 profile、
 * 一个 App 实例。共用一份文件的话，后启动的那个会把先启动的抹掉，被抹掉的
 * 那个 dsh 就再也没法被手动双击起来的壳找到了。
 *
 * 同名 profile 重启会覆盖自己那一份，所以文件不会越积越多。
 */
const ENDPOINTS_DIR = join(APP_SUPPORT, "endpoints");

/**
 * 桥路径的兜底值。**真相在 clam-bridge 的 config.path**——它才是挂 WS 的那一方，
 * 而且那是个用户可覆写的配置项。本插件经 `clamBridge.path` 取当前值（见 `apply`），
 * 只在桥缺席时用这个默认；写死一份自己的会让"改了桥的 path 壳就静默连不上"。
 * 与 Swift 侧 `ClamEndpoint.defaultBridgePath` 是同一个默认。
 */
const DEFAULT_BRIDGE_PATH = "/clam/bridge";

/** Xcode 工程载荷根（本包的 `host/`）。 */
const HOST_DIR = fileURLToPath(new URL("../host/", import.meta.url));

/**
 * xcodegen 二进制。**被 .gitignore 挡在库外**（`/clam-app/host/tools/`），
 * 所以新克隆 / 新 worktree 里它不存在——`surfclam/bin/surfclam.js` 的 ensureXcodegen
 * 会在 `./dev` 时从别的 worktree 或 PATH 拷一份补上。这里做一次显式存在性检查，
 * 是因为不做的话失败长成 `spawn …/tools/xcodegen ENOENT`：一句既不说明原因
 * 也不说明补法的话，还埋在构建日志里。
 */
const XCODEGEN = join(HOST_DIR, "tools", "xcodegen");

/** 参与源码 hash 的子树；`tools/`（xcodegen 二进制）与 `build/`（产物）不算源码。 */
const HASHED_ROOTS = ["project.yml", "Sources", "scripts"];

/** 每次构建都会被 prebuild 脚本重写，进 hash 会让"源码没变"永远不成立。 */
const HASH_EXCLUDED = new Set(["Sources/Resources/BuildTimestamp.txt"]);

/** 目录名黑名单（构建中间产物与版本控制噪声）。 */
const HASH_SKIP_DIRS = new Set([".git", ".build", "build", "DerivedData", ".DS_Store"]);

/** 产物落点由 xcodebuild 的 `-derivedDataPath build` 固定（见仓库 CLAUDE.md 硬约束）。 */
const productPath = (configuration) =>
	join(HOST_DIR, "build", "Build", "Products", configuration,
		`${configuration === "Debug" ? "Surfclam Dev" : "Surfclam"}.app`);

/** 没有 Xcode 时的兜底产物：上次装到 /Applications 的 Release。 */
const INSTALLED_RELEASE = "/Applications/Surfclam.app";

/**
 * 壳快捷键的设置命名空间（计划：docs/clam-shortcuts-settings-plan.md）。
 *
 * 名字里没有 `clam-app`，因为它描述的是**壳的菜单**而不是本插件的构建行为；
 * 登记权在这儿只是因为 clam-app 就是壳的 node 半身。ns 名进了 wire——
 * client 半边 `clam-layout` 用同一个字符串 bind scope，改名要两边一起改。
 */
const SHORTCUTS_NAMESPACE = "clam-shortcuts";

/**
 * 键位表 schema。
 *
 * **默认值的真相在壳里那张表**（`MainWindowController` 的 command → 默认 spec），
 * 不在这里：壳建第一版菜单时页面还没加载完，根本没有任何设置值可用，所以它必须
 * 自带一份能独立开工的默认。这里的 `.default(…)` 只为让两扇设置界面把默认值显示
 * 出来、并让「恢复默认」给回同一个东西。**两处必须逐字一致，改一处同步另一处**
 * ——分家了不报错也不校验，症状是界面上写着 A、实际生效的是 B。
 *
 * 键位 spec 格式：小写、`+` 连接（`cmd+shift+]`、`cmd+alt+a`、`esc`）；
 * 修饰符 `cmd` / `shift` / `alt`（`option`）/ `ctrl`；键名支持单字符与
 * `backspace` / `esc` / `space` / `left`…。**空串 = 禁用**（菜单项还在，
 * 只是没有快捷键）。解析失败 = 壳退回默认并在日志记一行，配置错降级、不失能。
 *
 * 只收"改了确实更好用"的那些。系统惯例（⌘W/⌘Q/⌘H/⌘M、编辑菜单、⌘R、⌥⌘S、
 * ⌘±0、⌥⌘D、⌘⇧R、⌘/）**刻意不进设置**——它们能改只会更难用。
 */
const ShortcutsSettings = z.object({
	newSession: z.string().default("cmd+n")
		.description("新建会话。"),
	prevSession: z.string().default("cmd+shift+[")
		.description("切到上一个会话（顺序与侧边栏列表当前显示的一致）。"),
	nextSession: z.string().default("cmd+shift+]")
		.description("切到下一个会话（顺序与侧边栏列表当前显示的一致）。"),
	nextPendingSession: z.string().default("cmd+alt+a")
		.description("跳到下一个待处理会话（有东西在等你回答的那些）。"),
	archiveSession: z.string().default("cmd+shift+backspace")
		.description("归档当前会话。"),
	renameSession: z.string().default("cmd+alt+r")
		.description("重命名当前会话。"),
	focusSearch: z.string().default("cmd+alt+f")
		.description("把光标送进侧边栏搜索框。"),
	openSettings: z.string().default("cmd+,")
		.description("打开设置窗口。"),
	// ⌘1-9 是九个键位，逐个开成字段既啰嗦又留下"第 3 个和第 7 个撞车"这类
	// 无人校验的坑，所以整组只给一个前缀选择；`off` = 九个都不装。
	sessionDigits: z.union([z.const("cmd"), z.const("cmd+alt"), z.const("off")])
		.default("cmd")
		.description("用数字键直接跳到第 1～9 个会话时按的修饰符；off = 不装这组快捷键。"),
	// 这一条不进壳的菜单：页面自己在 keydown 上匹配（原生菜单项拦不住
	// WebView 里的输入焦点）。见 clam-layout/lib/client.js 的 escStop。
	stopGenerating: z.string().default("esc")
		.description("停止当前会话正在生成的回复（在网页内匹配，不是菜单项）。留空 = 关掉这个键。"),
});

/** 上次构建时的源码 hash，与产物同处 build/ 下——产物被清掉时它一起消失，语义自洽。 */
const hashMarkerPath = (configuration) =>
	join(HOST_DIR, "build", `.clam-app-source-hash.${configuration}`);

export function apply(ctx, config) {
	const logger = reporter(ctx.logger("clam-app"));
	const httpBase = resolveHttpBase(ctx.webServer);

	// 先登记服务名，让下游 inject 能等；产物定下来后再 set 值。
	ctx.provide("clamApp", undefined);

	// 桥的当前状态。**可变引用，不是快照**：桥可以晚于本插件挂载、也可以中途卸载，
	// 而 endpoint 文件与 `open --args` 都要用它此刻的值。
	const bridge = { path: DEFAULT_BRIDGE_PATH, announce: () => {} };

	// 发现文件先于构建落地：一个手动启动的 app 立刻就能接入，
	// 不必等分钟级的首次构建。桥若带来不同的 path，下面的 inject 回调会重写它。
	ctx.effect(() => {
		writeEndpointFile({ httpBase, bridgePath: bridge.path, logger });
		return () => removeEndpointFile(logger);
	}, "clam-app endpoint 发现文件");

	// 与桥的全部往来收在这一处：路径、播报、重启请求。
	// 仍是局部 inject 而非顶层依赖——桥缺席时壳照样该起来（WebView 全出血兜底），
	// 只是没有任何原生插件。
	ctx.inject(["clamBridge"], (scoped) => {
		const app = scoped.clamBridge.app;
		scoped.effect(() => {
			const path = typeof scoped.clamBridge.path === "string"
				? scoped.clamBridge.path : DEFAULT_BRIDGE_PATH;
			if (path !== bridge.path) {
				bridge.path = path;
				logger.info(`桥路径取自 clam-bridge 的配置：${path}`);
				writeEndpointFile({ httpBase, bridgePath: path, logger });
			}
			bridge.announce = (status, detail) => app.announce(status, detail);
			// 壳自己要重启：它发完帧就退出，我们等它死透再按新产物拉起来。
			const off = app.onRestartRequest(() =>
				restartApp({ configuration: config.configuration, httpBase, bridge, logger }));
			return () => {
				off();
				bridge.announce = () => {};
				// 桥卸载了，发现文件里的 path 也就不再有依据——退回默认。
				if (bridge.path !== DEFAULT_BRIDGE_PATH) {
					bridge.path = DEFAULT_BRIDGE_PATH;
					writeEndpointFile({ httpBase, bridgePath: DEFAULT_BRIDGE_PATH, logger });
				}
			};
		}, "clam-app ↔ clam-bridge");
	});

	// 快捷键设置面：注册完就没了。值由 clam-layout 的 client 半边经
	// `ctx.settingsScope` 自己读、投影给壳，这半边从不碰它，也不 push 给谁。
	//
	// `settings` 走**运行时嵌套 inject**，不是顶层 `export const inject`。
	// 顶层的语义是"服务不在就整个插件不挂载"，而本插件的核心职责是构建并拉起壳
	// ——绝不能因为一个可选的设置项就让整个 App 消失（headless profile 里
	// settings 确实可能缺席）。缺席时壳一直用自带的默认键位表，其余一切照旧。
	// （这个 cordis fork 的 `inject` 没有 `{required, optional}` 形态，
	// 嵌套是它表达可选依赖的唯一方式。）
	//
	// 注册一个 ns 就同时点亮了两扇界面，两边都不用改一行：clam-settings 那扇原生
	// 窗口（「插件 → 插件配置」把 `describe()` 里的每个 ns 一视同仁地列出来），
	// 以及 dsh 自己的页内设置对话框。
	ctx.inject(["settings"], (scoped) => {
		scoped.settings.register(SHORTCUTS_NAMESPACE, ShortcutsSettings, {
			// 改完立刻生效，不需要重启：client 半边订着这个 ns，值一变就重推给壳，
			// 壳原地重建整条主菜单。界面据此标注"立即生效"。
			applies: "live",
		});
	});

	// 构建与拉起是长活，不能挂在 apply 的返回值上——那会把 dsh 的启动
	// 一起拖住（首次构建分钟级，浏览器这段时间将无人应答）。
	let disposed = false;
	ctx.effect(() => () => { disposed = true; }, "clam-app 构建/拉起");

	bootstrap({ ctx, config, logger, httpBase, bridge, isDisposed: () => disposed })
		.catch((error) => {
			// 到这儿说明是意料之外的异常（预期内的失败都已在内部记过日志并返回）。
			logger.warn(`clam-app 启动流程异常：${errorText(error)}`);
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
		process.stderr.write(`clam-app: ${message}\n`);
	};
	return {
		info: (message) => emit("info", message),
		warn: (message) => emit("warn", message),
		error: (message) => emit("error", message),
	};
}

// ---------------------------------------------------------------- 主流程

async function bootstrap({ ctx, config, logger, httpBase, bridge, isDisposed }) {
	const { configuration } = config;
	const built = config.build
		? await ensureBuilt({ configuration, logger, isDisposed })
		: locateExistingProduct(configuration);

	if (isDisposed()) return;

	if (built.appPath === undefined) {
		logger.warn(`未找到可用的 ${configuration} 产物，${name} 优雅缺席——dsh 照常服务浏览器。`
			+ ` 需要 macOS 壳的话，在仓库里手动跑一次 clam-app/host/scripts/dev.sh。`);
		return;
	}

	ctx.set("clamApp", {
		appPath: built.appPath,
		freshness: built.freshness,
		configuration,
		httpBase,
		// getter：桥可能晚于这里挂载，快照会把兜底值冻住。
		get bridgePath() { return bridge.path; },
	});

	if (config.launch) {
		await launch({ appPath: built.appPath, httpBase, bridgePath: bridge.path, logger });
	}

	// v1：起来之后继续盯着壳源码。只在"真的构建过"时才盯——没有 Xcode、
	// 或 build 关掉时，重建无从谈起，盯了也只会白读文件。
	if (config.build && config.watch && built.freshness !== "prebuilt") {
		watchSources({ ctx, config, logger, bridge, isDisposed, configuration });
	}
}

/**
 * 盯壳源码（§7.5 v1）。与桥盯 `swift/` 同款的廉价轮询：先比 mtime/size 签名，
 * 签名变了才读内容算 hash——hash 才是"要不要重建"的判据（换 git 分支不算改过）。
 *
 * 播报走 `apply` 里那一处 `ctx.inject` 攒下的 `bridge.announce`：clam-bridge 在
 * 就播，不在就只写终端。壳没连上来时重建照做。
 */
function watchSources({ ctx, config, logger, bridge, isDisposed, configuration }) {
	let building = false;
	let pending = false;
	let signature = signatureSources();
	let builtHash = readTextOrUndefined(hashMarkerPath(configuration));

	const tick = async () => {
		if (isDisposed() || building) { if (building) pending = true; return; }
		const next = signatureSources();
		if (next === signature) return;
		signature = next;
		const hash = hashSources();
		if (hash === undefined || hash === builtHash) return;

		building = true;
		logger.info("壳源码有变动，后台重建中…");
		bridge.announce("building", {});
		const startedAt = Date.now();
		const result = await runBuild({ configuration, logger, isDisposed });
		building = false;
		if (isDisposed()) return;

		if (result.ok) {
			builtHash = hash;
			writeFileSync(hashMarkerPath(configuration), hash);
			const seconds = ((Date.now() - startedAt) / 1000).toFixed(1);
			logger.info(`壳已重建（${seconds}s）。${config.restartOnRebuild
				? "按配置立即重启壳。" : "重启 surfclam 生效——窗口里有提示。"}`);
			bridge.announce("ready", {
				hash: hash.slice(0, 12),
				durationMs: Date.now() - startedAt,
				autoRestart: config.restartOnRebuild,
			});
		} else {
			// 失败不回滚 builtHash：源码再变一次就会再试，用户改对了自然就好。
			logger.error(`壳重建失败。完整日志：${result.logPath}\n${tail(result.log, 20)}`);
			bridge.announce("failed", { log: tail(result.log, 40) });
		}

		if (pending) { pending = false; signature = ""; }
	};

	const timer = setInterval(() => { tick().catch(() => {}); }, config.watchIntervalMs);
	timer.unref?.();
	ctx.effect(() => () => clearInterval(timer), "clam-app 壳源码轮询");
	logger.info(`盯着壳源码（每 ${config.watchIntervalMs}ms），改了会自动重建。`);
}

/**
 * 壳自请重启：它发完 `app-restart` 帧就 terminate，这里等进程真的消失再拉起——
 * 拉早了 `open` 只会把正在退出的旧实例带到前台。等不到就照拉，最坏也不过是
 * 把旧窗口前置一下。
 */
async function restartApp({ configuration, httpBase, bridge, logger }) {
	const appPath = productPath(configuration);
	const deadline = Date.now() + 15000;
	while (Date.now() < deadline) {
		if (!(await isRunning(appPath))) break;
		await delay(300);
	}
	if (await isRunning(appPath)) {
		logger.warn("壳说要重启，但 15s 后进程仍在；照常拉起（可能只是把旧窗口前置）。");
	}
	await launch({ appPath, httpBase, bridgePath: bridge.path, logger });
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

	if (!existsSync(XCODEGEN)) {
		logger.error(`缺 ${XCODEGEN}（该二进制不入库，新克隆 / 新 worktree 里没有），跳过构建。`
			+ ` 补法：在仓库根跑一次 ./dev（会自动从同仓库的其它 worktree 或 PATH 拷一份），`
			+ ` 或 brew install xcodegen 后把它拷到上面那个路径。`);
		return locateExistingProduct(configuration);
	}

	logger.info(`壳源码有变动，开始构建 ${configuration}（首次约需分钟级）…`);
	const startedAt = Date.now();
	const result = await runBuild({ configuration, logger, isDisposed });
	if (isDisposed()) return { appPath: undefined, freshness: "missing" };
	if (!result.ok) {
		logger.error(`构建 ${configuration} 失败（不重试）。完整日志：${result.logPath}\n${tail(result.log, 20)}`);
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

/**
 * 跑一遍 `dev.sh` 的构建三步。完整日志落文件（xcodebuild 的输出淹没 dsh 终端
 * 没有意义），返回值只带日志文本供调用方掐个尾巴。**不抛异常**：失败是预期内的
 * 一种结果，调用方各有各的善后。
 */
async function runBuild({ configuration, logger, isDisposed }) {
	const logPath = buildLogPath(configuration);
	mkdirSync(dirname(logPath), { recursive: true });
	// 盯文件的重建走的也是这里，绕过了 ensureBuilt 的那道检查——不拦一下，
	// 日志里就只有一句 ENOENT。
	if (!existsSync(XCODEGEN)) {
		const log = `缺 ${XCODEGEN}（该二进制不入库）。补法：在仓库根跑一次 ./dev，`
			+ ` 或 brew install xcodegen 后把它拷到该路径。`;
		writeFileSync(logPath, log);
		return { ok: false, log, logPath };
	}
	try {
		// 时间戳文件不入库，须在 generate 扫描目录前落地。
		await run(join(HOST_DIR, "scripts", "write-build-timestamp.sh"), [], HOST_DIR);
		if (isDisposed()) return { ok: false, log: "已卸载", logPath };
		await run(XCODEGEN, ["generate"], HOST_DIR);
		if (isDisposed()) return { ok: false, log: "已卸载", logPath };
		// -derivedDataPath build 是硬约束：产物必须落在 build/Build/Products/，
		// 换位置会造成"BUILD SUCCEEDED 但改动永不生效"。
		const result = await run("xcodebuild", [
			"-project", join(HOST_DIR, "surfclam.xcodeproj"),
			"-scheme", "surfclam",
			"-configuration", configuration,
			"-derivedDataPath", "build",
			"build",
		], HOST_DIR, { maxBuffer: 64 * 1024 * 1024 });
		const log = result.stdout + result.stderr;
		writeFileSync(logPath, log);
		return { ok: true, log, logPath };
	} catch (error) {
		const log = `${error?.stdout ?? ""}${error?.stderr ?? ""}` || errorText(error);
		writeFileSync(logPath, log);
		return { ok: false, log, logPath };
	}
}

/**
 * 构建日志的路径，**按 profile 分片**（`clam-app-build.<profile>.<配置>.log`）。
 *
 * 多 worktree 并存时每个 worktree 一个 dsh，各构建各的壳；这份日志是**覆盖写**，
 * 共用一个文件名的话，邻居一构建就把你这份整个换掉——终端说"构建失败，完整日志见
 * <路径>"，你打开看到的却是邻居的编译错误，而且看不出来。分片与 endpoint 发现
 * 文件同一套兜底（见 {@link endpointFilePath}）。
 */
function buildLogPath(configuration) {
	const shard = resolveProfileName() ?? `pid-${process.pid}`;
	return join(APP_SUPPORT, "logs", `clam-app-build.${shard}.${configuration}.log`);
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
async function launch({ appPath, httpBase, bridgePath, logger }) {
	if (await isRunning(appPath)) {
		logger.info(`surfclam 已在运行（${appPath}），跳过拉起；它会自己从发现文件接入。`);
		return;
	}
	try {
		await run("open", [appPath, "--args",
			"--clam-endpoint", httpBase,
			"--clam-bridge-path", bridgePath], HOST_DIR);
		logger.info(`已拉起 surfclam：${appPath} → ${httpBase}`);
	} catch (error) {
		logger.error(`拉起 surfclam 失败（不重试）：${errorText(error)}`);
	}
}

// ---------------------------------------------------------------- endpoint 文件

/** webServer 绑 0.0.0.0 时对 app 而言仍是 loopback——它总在同一台机器上。 */
function resolveHttpBase(webServer) {
	const host = webServer.host === "0.0.0.0" ? "127.0.0.1" : webServer.host;
	return `http://${host}:${webServer.port}`;
}

/**
 * 本进程那一份发现文件的路径。文件名用 profile 名，因为它正是"这套 surfclam 是
 * 哪一套"的天然标识；取不到（不该发生，但 argv 毕竟是外部输入）时退回 pid，
 * 宁可留个不会被复用的文件名，也不要和别的 dsh 抢同一个。
 */
function endpointFilePath() {
	const profile = resolveProfileName();
	return join(ENDPOINTS_DIR, `${profile ?? `pid-${process.pid}`}.json`);
}

/** 原子写：先写临时文件再 rename，app 永远读不到半截 JSON。 */
function writeEndpointFile({ httpBase, bridgePath, logger }) {
	const payload = {
		httpBase,
		bridgePath,
		pid: process.pid,
		startedAt: new Date().toISOString(),
		profile: resolveProfileName(),
		// 壳凭这个认出"哪一份是我这一套"：它自己的 bundle 就躺在
		// `<hostDir>/build/Build/Products/<配置>/`，两边算出同一个绝对路径。
		// 没有它，手动双击起来的壳只能按 startedAt 挑，多 worktree 时就会
		// 连上邻居的 dsh、编译邻居的插件源码（见 Swift 侧 ClamEndpoint.isOwn）。
		hostDir: HOST_DIR.replace(/\/$/, ""),
	};
	const file = endpointFilePath();
	try {
		mkdirSync(ENDPOINTS_DIR, { recursive: true });
		const tmp = `${file}.${process.pid}.tmp`;
		writeFileSync(tmp, `${JSON.stringify(payload, undefined, "\t")}\n`);
		renameSync(tmp, file);
		logger.info(`endpoint 发现文件已写入：${file} → ${httpBase}`);
	} catch (error) {
		logger.warn(`写 endpoint 发现文件失败（手动启动的 app 将找不到本进程）：${errorText(error)}`);
	}
}

/**
 * 只删自己写的那一份。分片之后同名 profile 才可能撞车（比如上一次被 kill -9
 * 没清理干净），pid 这一道校验依然值得留着：先退的不该把后来者的文件删掉。
 */
function removeEndpointFile(logger) {
	const file = endpointFilePath();
	try {
		const raw = readTextOrUndefined(file);
		if (raw === undefined) return;
		if (JSON.parse(raw)?.pid !== process.pid) return;
		rmSync(file, { force: true });
	} catch (error) {
		logger.warn(`清理 endpoint 发现文件失败：${errorText(error)}`);
	}
}

/**
 * profile 名。dsh 不把它放进环境变量，只能从 argv 反推
 * （`dsh web` 是 `--profile web` 的别名）。
 *
 * 从"纯诊断字段"升格成了发现文件的文件名（见 {@link endpointFilePath}），
 * 所以取不到时调用方必须有兜底——这里仍然只负责如实返回 undefined。
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

/**
 * 廉价签名：只 stat 不读内容。轮询每一拍都跑它，签名没变就省下整棵树的 readFile。
 * 与 `hashSources` 用同一套根与排除项——两者对"什么算源码"的看法必须一致。
 */
function signatureSources() {
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

function delay(ms) {
	return new Promise((resolve) => { setTimeout(resolve, ms).unref?.(); });
}

function errorText(error) {
	return error instanceof Error ? error.message : String(error);
}
