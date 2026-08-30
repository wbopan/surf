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
 * **两种形态，一张编排表**：环境变量 `CLAM_RELEASE=1`（`./release` 装出来的
 * LaunchAgent 在 plist 里设它）改的是**配置与落点**，不是"做不做"——照样盯源码、
 * 照样重建，只是配置用 `Release`、构建完多一步**安装**到
 * `/Applications/Surfclam.app`，而且从不自动拉起（登录时不弹窗口）。
 * 计划见 `docs/release-install-plan.md` §2.1 与 §2.5，实现见 {@link applyReleaseForm}。
 *
 * 全程"优雅缺席"：构建失败、没有 Xcode、连既有产物都没有，都只在终端留一句话，
 * dsh 照常服务浏览器。首次构建失败不重试、不成环——防的是构建风暴；
 * 盯文件的重建则由"源码又变了"驱动，天然不会自己转圈。
 *
 * @module clam-app
 */
import { execFile } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import z from "@deepseek-ai/schemastery";
import { environmentLocale, localeFromTag } from "../../clam-bridge/lib/locale.js";
import { HOST_DIR, hashMarkerPath, hashSources, signatureSources } from "./source-hash.js";

export const name = "clam-app";

/** webServer 决定了 endpoint 里的 host/port，没有它这个插件无事可做。 */
export const inject = ["webServer"];

/**
 * `Config` 那几条 description 用哪门语言（计划 §7）。
 *
 * **只到得了环境推导那一级**：`Config` 是模块级常量，cordis 实例化插件时就要读它，
 * 那一刻没有任何 ctx，`ctx.settings.get("locale")` 无从谈起。下面的
 * `clam-shortcuts` ns 在 `apply` 里注册，够得着 ctx，所以它走完整的决议链
 * （`resolveLocale`）。两者在绝大多数机器上是同一个答案——只有"系统语言与 dsh 的
 * locale 设置不一致"时才会差一门语言，而这两张表长在页内设置对话框的不同卡片上。
 */
const CONFIG_LOCALE = environmentLocale();

export const Config = z.object({
	configuration: z.union([z.const("Debug"), z.const("Release")]).default("Debug")
		.description(CONFIG_LOCALE === "zh"
			? "xcodebuild 配置。Debug 产物是 “Surfclam Dev.app”，Release 是 “Surfclam.app”。"
			: "The xcodebuild configuration. Debug produces “Surfclam Dev.app”, Release produces “Surfclam.app”."),
	build: z.boolean().default(true)
		.description(CONFIG_LOCALE === "zh"
			? "源码 hash 变化或产物缺失时自动 xcodebuild；关掉则只探测既有产物。"
			: "Run xcodebuild whenever the source hash changes or the app is missing. When off, only look for an existing build."),
	launch: z.boolean().default(true)
		.description(CONFIG_LOCALE === "zh"
			? "产物就绪且 app 尚未运行时自动拉起。"
			: "Launch the app once the build is ready, unless it is already running."),
	watch: z.boolean().default(true)
		.description(CONFIG_LOCALE === "zh"
			? "dsh 运行期间盯着壳源码，变了就后台重建并经桥提示「有新版」。需要 build 也开着。"
			: "Watch the shell sources while dsh runs: rebuild in the background on any change and offer the new build through the bridge. Requires Build."),
	watchIntervalMs: z.number().step(1).min(300).default(2000)
		.description(CONFIG_LOCALE === "zh"
			? "盯壳源码的轮询间隔。先比 mtime/size 签名，签名变了才读内容算 hash。"
			: "How often to poll the shell sources. Modification time and size are compared first; contents are hashed only when that signature changes."),
	restartOnRebuild: z.boolean().default(false)
		.description(CONFIG_LOCALE === "zh"
			? "重建成功后不等用户点，直接让壳退出并重拉（开发期方便，会丢页面状态）。"
			: "After a successful rebuild, quit and relaunch the shell instead of waiting for you to click. Handy while developing, but the page state is lost."),
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

/**
 * xcodegen 二进制。**被 .gitignore 挡在库外**（`/clam-app/host/tools/`），
 * 所以新克隆 / 新 worktree 里它不存在——`surfclam/bin/surfclam.js` 的 ensureXcodegen
 * 会在 `./dev` 时从别的 worktree 或 PATH 拷一份补上。这里做一次显式存在性检查，
 * 是因为不做的话失败长成 `spawn …/tools/xcodegen ENOENT`：一句既不说明原因
 * 也不说明补法的话，还埋在构建日志里。
 */
const XCODEGEN = join(HOST_DIR, "tools", "xcodegen");

/** 产物落点由 xcodebuild 的 `-derivedDataPath build` 固定（见仓库 CLAUDE.md 硬约束）。 */
const productPath = (configuration) =>
	join(HOST_DIR, "build", "Build", "Products", configuration,
		`${configuration === "Debug" ? "Surfclam Dev" : "Surfclam"}.app`);

/** 没有 Xcode 时的兜底产物：上次装到 /Applications 的 Release。 */
const INSTALLED_RELEASE = "/Applications/Surfclam.app";

/**
 * 「本机安装形态」的开关（`docs/release-install-plan.md` §2.1）。
 *
 * `./release` 装出来的 LaunchAgent 在 plist 的 EnvironmentVariables 里设它，
 * 于是**同一张编排表**（`surfclam/cordis.patch.yml`）服务两种形态，差别只在
 * 每次运行的环境——不设第二个 profile、不复制第二份配置。
 *
 * 值的判定刻意宽松（非空且不是 `0` 即算开），因为它是人手写进 plist 的。
 */
const RELEASE_ENV = "CLAM_RELEASE";

/** 本进程是不是 release 形态。**读环境而不是读 config**：config 是两种形态共用的那一张。 */
function isReleaseForm() {
	const raw = process.env[RELEASE_ENV]?.trim();
	return raw !== undefined && raw !== "" && raw !== "0";
}

/**
 * release 形态的**整体覆写**（计划 §2.5，2026-08-30 用户裁决推翻了 §2.1 的
 * "不构建不盯源码"）。常驻 daemon 的四条要求：
 *
 *  - `configuration: "Release"`——它伺候的是 `/Applications/Surfclam.app`；
 *  - `build` + `watch` **照开**（前提是壳源码在，见下）：壳二进制落后是**静默的**，
 *    而且症状出在别处——桥会把新插件热替换进旧壳，新插件 emit 的东西旧壳没人订阅，
 *    看上去像"按钮坏了"。所以哈希一致就跳过、不一致就重建，和 dev 形态同一套机制，
 *    只是配置与落点不同（构建仍发生在 worktree 的 `build/` 里，成功后**安装**到
 *    `/Applications`，见 {@link installBuiltProduct}）；
 *  - `launch: false`——**daemon 是安静的**：登录时不弹窗口，App 由用户双击
 *    （或 `./release` 收尾那一下 `open`）拉起。**壳自请重启后的重拉是另一条路径**
 *    （`app-restart` → {@link restartApp}），不受这一项管；
 *  - `restartOnRebuild: false`——**强制**。daemon 不替用户杀正在用的 App；
 *    换代由壳右上角那条「壳有新版本 · 重启」提示条驱动，用户点了才换。
 *
 * **门控**：壳源码目录不在（npm 装出来的 registry 形态可以只带 lib/）就退回
 * "不构建不盯源码"的老行为——最终用户机器上什么都不会发生。
 * 没有完整 Xcode 那一层门控在下游（{@link ensureBuilt} 里的 `hasXcode`，它是异步的，
 * 而这里必须同步给出配置）：那时构建这一步降级成"只探测既有产物"，
 * 于是 `freshness` 是 `prebuilt`，盯源码也就不会启动。
 */
function applyReleaseForm(config, logger) {
	if (!isReleaseForm()) return config;
	const overrides = { configuration: "Release", launch: false, restartOnRebuild: false };
	if (!existsSync(join(HOST_DIR, "project.yml"))) {
		logger.info(`${RELEASE_ENV}=1：release 形态——壳源码不在（${HOST_DIR}），`
			+ `不构建、不盯源码、不自动拉起（壳用 ${INSTALLED_RELEASE}）。`);
		return { ...config, ...overrides, build: false, watch: false };
	}
	logger.info(`${RELEASE_ENV}=1：release 形态——盯壳源码、按需重建 Release 并安装到`
		+ ` ${INSTALLED_RELEASE}；不自动拉起（登录时不弹窗口），换代由壳里的提示条驱动。`);
	return { ...config, ...overrides, build: true, watch: true };
}

/**
 * 本 dsh 期望的 App bundle 路径——**写进 endpoint 发现文件的 `appPath`，
 * 壳凭它认出"哪一份是我这一套"**（见 Swift 侧 `ClamEndpoint.isOwn`）。
 *
 * 为什么 `hostDir` 不够：装到 `/Applications` 的 Release 壳不在任何 worktree 的
 * `build/Build/Products/` 之下，`ClamPaths.ownHostDir` 推不出来，`isOwn` 于是恒假
 * ——那样它只能按 `startedAt` 倒序挑 dsh，多 worktree 并存时会安静地连上邻居。
 */
function expectedAppPath(config) {
	return isReleaseForm() ? INSTALLED_RELEASE : productPath(config.configuration);
}

/**
 * 壳快捷键的设置命名空间（计划：docs/clam-shortcuts-settings-plan.md）。
 *
 * 名字里没有 `clam-app`，因为它描述的是**壳的菜单**而不是本插件的构建行为；
 * 登记权在这儿只是因为 clam-app 就是壳的 node 半身。ns 名进了 wire——
 * client 半边 `clam-layout` 用同一个字符串 bind scope，改名要两边一起改。
 */
const SHORTCUTS_NAMESPACE = "clam-shortcuts";

/**
 * 键位表 schema：**按桥的登记表现拼**（`clamBridge.commands.list()`）。
 *
 * 从前这里是一张手抄的常量表，而壳里另有一张默认键位表——两处必须逐字一致
 * 且**没有任何校验**，分家了不报错，症状是"设置界面写着 ⌘N、按下去却不是"。
 * 现在两张表的上游都是插件自己的 `commands` 声明（形状见
 * `clam-bridge/lib/plugin.js` 的 CommandDeclaration），漂移在结构上就不可能了。
 *
 * 语言在**注册那一刻**定下来（计划 §7；`.description()` 没有翻译钩子，
 * 运行中切语言不追改，重启 dsh 后对齐）。
 *
 * 键位 spec 格式：小写、`+` 连接（`cmd+shift+]`、`cmd+alt+a`、`esc`）；
 * 修饰符 `cmd` / `shift` / `alt`（`option`）/ `ctrl`；键名支持单字符与
 * `backspace` / `esc` / `space` / `left`…。**空串 = 禁用**（菜单项还在，
 * 只是没有快捷键）。解析失败 = 壳退回默认并在日志记一行，配置错降级、不失能。
 *
 * 只收插件标了 `configurable !== false` 的那些。系统惯例（⌘W/⌘Q/⌘H/⌘M、
 * 编辑菜单、⌘R、⌥⌘S、⌘±0、⌥⌘D、⌘⇧R、⌘/）压根不走这张表——它们由壳硬编码，
 * 能改只会更难用。
 *
 * @param {"zh"|"en"} locale
 * @param {object[]} commands 命令声明（已按登记顺序铺平、按 id 去重）。
 */
const shortcutsSettings = (locale, commands) => {
	const fields = {};
	for (const command of commands) {
		if (command.configurable === false) continue;
		const text = pickText(command.description ?? command.label, locale) ?? command.id;
		const fallback = typeof command.key === "string" ? command.key : "";
		// 值域封闭的（sessionDigits 那种"只有三个取值"）画成下拉而不是文本框：
		// 一个自由文本框里写 `cmd+7` 是合法 spec 却不是这条命令认得的东西。
		const field = Array.isArray(command.keyChoices) && command.keyChoices.length > 0
			? z.union(command.keyChoices.map((choice) => z.const(choice)))
			: z.string();
		fields[command.id] = field.default(fallback).description(text);
	}
	return z.object(fields);
};

/** 从 `{zh, en}` 里取当前语言那句；缺了就退英文，再缺就 undefined。 */
function pickText(bilingual, locale) {
	if (bilingual === null || typeof bilingual !== "object") return undefined;
	const value = bilingual[locale] ?? bilingual.en ?? bilingual.zh;
	return typeof value === "string" ? value : undefined;
}

/**
 * 命令声明按 id 去重（同一条由多家声明时先登记的赢，与壳的规则一致）。
 * 壳那边同样去重——两边算出来的表必须是同一份，否则设置里有的键壳不认得。
 */
function dedupeCommands(commands) {
	const seen = new Set();
	return commands.filter((command) => {
		if (typeof command?.id !== "string" || seen.has(command.id)) return false;
		seen.add(command.id);
		return true;
	});
}

/**
 * 命令声明里**影响 schema 的那部分**的指纹。登记表一变就重算，指纹没变就不动
 * ——重注册会让设置界面上正开着的那张表原地换掉，没必要为一次无关的登记付这个代价。
 */
function shortcutsFingerprint(commands, locale) {
	return JSON.stringify([locale, commands.map((command) => [
		command.id, command.key ?? null, command.keyChoices ?? null,
		command.configurable ?? true, command.description ?? command.label ?? null,
	])]);
}

/**
 * 登记表安静多久之后才注册 schema。
 *
 * **必须去抖**：clam-app 多半比别的插件先挂载，那一刻登记表是空的——照它注册出来的
 * 就是一张空表。插件是一个接一个挂上来的，等它不再动了再注册一次最省事
 * （照 clam-sidebar 的去抖模式）。真的再变（运行时装/卸插件）也接得住，
 * 见 `installShortcutsSettings` 的重注册那一段。
 */
const SHORTCUTS_QUIET_MS = 300;

/**
 * 注册 / 重注册 `clam-shortcuts` 设置 ns。
 *
 * **重注册的机制**：`settings.register` 重复注册同一个 ns 会 fails loud，但它把
 * 注册挂成**调用方 fiber 上的一个 effect**（dsh-settings 源码 `register()` 里那句
 * `this.ctx.effect(...)`，注释也写了"disposing that fiber removes the namespace"）。
 * 所以每份注册单开一个 `ctx.inject` 子 fiber，要换表就 dispose 它再开一个。
 * **dispose 是异步的**，两次安装叠在一起会撞"already registered"，所以串一条队。
 *
 * 用户存过的键位覆盖值不受影响：它们躺在设置文档里，schema 只决定怎么解析与显示。
 */
function installShortcutsSettings(scoped, logger) {
	/** @type {{dispose: () => Promise<void>}|undefined} */
	let fiber;
	let queue = Promise.resolve();
	let fingerprint;
	let timer;
	let disposed = false;

	const install = () => {
		if (disposed) return;
		const commands = dedupeCommands(scoped.clamBridge.commands.list());
		const locale = resolveLocale(scoped);
		const next = shortcutsFingerprint(commands, locale);
		if (next === fingerprint) return;
		fingerprint = next;

		queue = queue.then(async () => {
			if (disposed) return;
			if (fiber !== undefined) {
				await fiber.dispose();
				fiber = undefined;
			}
			if (disposed) return;
			// 一条可配置的命令都没有 = 没有插件在场，那就别开一张空卡片。
			const configurable = commands.filter((command) => command.configurable !== false);
			if (configurable.length === 0) {
				logger.info("没有插件声明可配置的快捷键，clam-shortcuts 设置面不注册。");
				return;
			}
			fiber = scoped.inject(["settings"], (inner) => {
				// 注册一个 ns 就同时点亮了两扇界面，两边都不用改一行：clam-settings
				// 那扇原生窗口（「插件 → 插件配置」把 describe() 里的每个 ns 一视同仁
				// 地列出来），以及 dsh 自己的页内设置对话框。
				inner.settings.register(SHORTCUTS_NAMESPACE, shortcutsSettings(locale, commands), {
					// 改完立刻生效，不需要重启：client 半边订着这个 ns，值一变就重推给壳，
					// 壳原地重建整条主菜单。界面据此标注"立即生效"。
					applies: "live",
				});
			});
			logger.info(`快捷键设置面已注册：${configurable.length} 项`
				+ `（${configurable.map((command) => command.id).join(", ")}）`);
		}).catch((error) => {
			// 注册失败绝不能赔掉整个 clam-app（它的正事是构建并拉起壳）。
			// 最坏情况是设置页少一张卡片，壳仍用插件声明里的默认键位。
			logger.warn(`快捷键设置面注册失败：${errorText(error)}`);
			fingerprint = undefined; // 下次登记表变动时再试
		});
	};

	const schedule = () => {
		clearTimeout(timer);
		timer = setTimeout(install, SHORTCUTS_QUIET_MS);
		timer.unref?.();
	};

	const off = scoped.clamBridge.commands.subscribe(schedule);
	schedule();

	scoped.effect(() => () => {
		disposed = true;
		off();
		clearTimeout(timer);
		// 子 fiber 由 scoped 自己带走，这里不再手动 dispose（重复 dispose 无益）。
	}, "clam-app 快捷键设置面");
}

export function apply(ctx, rawConfig) {
	const logger = reporter(ctx.logger("clam-app"));
	// 形态覆写要在**一切之前**：下面每一步（发现文件写什么 appPath、要不要构建、
	// 要不要拉起）都读它的结果，晚一步就会有半拉子按 dev 形态跑过。
	const config = applyReleaseForm(rawConfig, logger);
	const httpBase = resolveHttpBase(ctx.webServer);
	const appPath = expectedAppPath(config);

	// 先登记服务名，让下游 inject 能等；产物定下来后再 set 值。
	ctx.provide("clamApp", undefined);

	// 桥的当前状态。**可变引用，不是快照**：桥可以晚于本插件挂载、也可以中途卸载，
	// 而 endpoint 文件与 `open --args` 都要用它此刻的值。
	const bridge = { path: DEFAULT_BRIDGE_PATH, announce: () => {} };

	// 发现文件先于构建落地：一个手动启动的 app 立刻就能接入，
	// 不必等分钟级的首次构建。桥若带来不同的 path，下面的 inject 回调会重写它。
	ctx.effect(() => {
		writeEndpointFile({ httpBase, bridgePath: bridge.path, appPath, logger });
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
				writeEndpointFile({ httpBase, bridgePath: path, appPath, logger });
			}
			bridge.announce = (status, detail) => app.announce(status, detail);
			// 壳自己要重启：它发完帧就退出，我们等它死透再按新产物拉起来。
			const off = app.onRestartRequest(() =>
				restartApp({ appPath, httpBase, bridge, logger }));
			return () => {
				off();
				bridge.announce = () => {};
				// 桥卸载了，发现文件里的 path 也就不再有依据——退回默认。
				if (bridge.path !== DEFAULT_BRIDGE_PATH) {
					bridge.path = DEFAULT_BRIDGE_PATH;
					writeEndpointFile({ httpBase, bridgePath: DEFAULT_BRIDGE_PATH, appPath, logger });
				}
			};
		}, "clam-app ↔ clam-bridge");
	});

	// 快捷键设置面。schema 由**插件自己的命令声明**拼出来（见 shortcutsSettings），
	// 所以要同时有桥（登记表）和 settings 才做得成。值由 clam-layout 的 client 半边经
	// `ctx.settingsScope` 自己读、投影给壳，这半边从不碰它，也不 push 给谁。
	//
	// 两个服务都走**运行时嵌套 inject**，不是顶层 `export const inject`。
	// 顶层的语义是"服务不在就整个插件不挂载"，而本插件的核心职责是构建并拉起壳
	// ——绝不能因为一个可选的设置项就让整个 App 消失（headless profile 里
	// settings 确实可能缺席）。缺席时壳一直用插件声明里的默认键位，其余一切照旧。
	// （这个 cordis fork 的 `inject` 没有 `{required, optional}` 形态，
	// 嵌套是它表达可选依赖的唯一方式。）
	ctx.inject(["clamBridge", "settings"], (scoped) => {
		installShortcutsSettings(scoped, logger);
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
 * 此刻是哪门界面语言（计划 §3 末段那条 node 侧决议链）。
 *
 * `locale` ns 是 dsh-client-locale 单占的，**只读不注册**（重复 register 会
 * fails loud）；`preference` 缺省是**有语义的**——那时 dsh 自己也走环境推导，
 * 所以这里跟着退到 `environmentLocale()`。规则那一半是共用的
 * （`clam-bridge/lib/locale.js`），接线这一半各家自己写：这里只要一个瞬时值，
 * clam-notify 要的是一个活的读取口。
 *
 * @param {{settings: {get: (ns: string) => unknown}}} scoped 已经注入了 settings 的 ctx。
 */
function resolveLocale(scoped) {
	try {
		const section = scoped.settings.get("locale");
		const preference = section && typeof section === "object"
			? /** @type {{preference?: unknown}} */ (section).preference
			: undefined;
		return localeFromTag(preference) ?? environmentLocale();
	} catch {
		// ns 还没注册就读不到——退环境推导，绝不因为一句 description 赔掉注册。
		return environmentLocale();
	}
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
	// **构建落点与使用落点在 release 形态下是两个地方**：编译永远发生在 worktree 的
	// `build/Build/Products/Release/`（`-derivedDataPath build` 是硬约束），
	// 用的却是 /Applications 里那一份。`install` 非空就是"构建成功后还要拷过去"。
	const install = isReleaseForm() ? INSTALLED_RELEASE : undefined;
	// 不构建时**先认这一份**：release 形态下期望的是 /Applications 那个安装产物，
	// 而本地 build/ 里多半也躺着一份同名的 Release——不指名道姓就会挑中后者，
	// 于是 endpoint 文件里的 appPath 与本插件自己认的产物分了家。
	const built = config.build
		? await ensureBuilt({ configuration, logger, isDisposed, install })
		: locateExistingProduct(configuration, expectedAppPath(config));

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

	// v1：起来之后继续盯着壳源码。只在"这台机器构建得出来"时才盯——没有 Xcode、
	// 缺 xcodegen、或 build 关掉时，重建无从谈起，盯了也只会白读文件。
	// **首次构建失败也要盯**（`failedHash` 非空即是）：那时产物是旧的，而用户接下来
	// 多半就是去改那个编译错误——不盯的话得等到下次重启 dsh 才认得出他改好了。
	// 空转的防线在 watchSources 里（记住失败那次的 hash，hash 再变才重试）。
	const buildable = built.freshness !== "prebuilt" || built.failedHash !== undefined;
	if (config.build && config.watch && buildable) {
		watchSources({
			ctx, config, logger, bridge, isDisposed, configuration, install,
			failedHash: built.failedHash,
		});
	}
}

/**
 * 盯壳源码（§7.5 v1）。与桥盯 `swift/` 同款的廉价轮询：先比 mtime/size 签名，
 * 签名变了才读内容算 hash——hash 才是"要不要重建"的判据（换 git 分支不算改过）。
 *
 * 播报走 `apply` 里那一处 `ctx.inject` 攒下的 `bridge.announce`：clam-bridge 在
 * 就播，不在就只写终端。壳没连上来时重建照做。
 */
function watchSources({ ctx, config, logger, bridge, isDisposed, configuration, install, failedHash }) {
	let building = false;
	let pending = false;
	let signature = signatureSources();
	let builtHash = readTextOrUndefined(hashMarkerPath(configuration));
	// **失败那次的 hash 也要记住**（计划 §2.5 的"不空转"）。签名比对本来就拦得住
	// "文件一个字没动"的情况，但只要有人 touch 一下（或换分支再换回来），签名就变了
	// 而内容没变——那时不认失败 hash 的话，每一次都是一轮几十秒的 xcodebuild 白跑。
	let lastFailedHash = failedHash;

	const tick = async () => {
		if (isDisposed() || building) { if (building) pending = true; return; }
		const next = signatureSources();
		if (next === signature) return;
		signature = next;
		const hash = hashSources();
		if (hash === undefined || hash === builtHash || hash === lastFailedHash) return;

		building = true;
		logger.info("壳源码有变动，后台重建中…");
		bridge.announce("building", {});
		const startedAt = Date.now();
		let result = await runBuild({ configuration, logger, isDisposed });
		// 安装是构建的一部分：装不进去就等于没重建，绝不能报 ready
		// ——壳会挂出"有新版本"，用户点了重启，回来还是旧的。
		if (result.ok && install !== undefined) {
			result = await installBuiltProduct({ configuration, install, logger, logPath: result.logPath });
		}
		building = false;
		if (isDisposed()) return;

		if (result.ok) {
			builtHash = hash;
			lastFailedHash = undefined;
			writeFileSync(hashMarkerPath(configuration), hash);
			const seconds = ((Date.now() - startedAt) / 1000).toFixed(1);
			logger.info(`壳已重建（${seconds}s）${install === undefined ? "" : `并安装到 ${install}`}。`
				+ `${config.restartOnRebuild ? "按配置立即重启壳。" : "重启 surfclam 生效——窗口里有提示。"}`);
			bridge.announce("ready", {
				hash: hash.slice(0, 12),
				durationMs: Date.now() - startedAt,
				autoRestart: config.restartOnRebuild,
			});
		} else {
			// 失败不回滚 builtHash（旧产物仍在役），但记下这个 hash：源码**再变一次**
			// 才重试，改对了自然就好，改不对也不会 2s 一轮空转 xcodebuild。
			lastFailedHash = hash;
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
async function restartApp({ appPath, httpBase, bridge, logger }) {
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
 *
 * `install` 非空（release 形态）时多两件事：产物构建成功后拷进 `install`，
 * 并且**返回的 appPath 是 `install` 而不是构建落点**——那才是用户双击的那一份，
 * 也是发现文件里 `appPath` 写的那一个（两者分家的话，壳会认不出"这套是我的"）。
 *
 * 返回值多一个 `failedHash`：构建真的跑了并且失败时才有值，调用方据此决定
 * "要不要继续盯源码"（见 bootstrap）与"哪个 hash 不必重试"（见 watchSources）。
 */
async function ensureBuilt({ configuration, logger, isDisposed, install }) {
	const product = productPath(configuration);
	const hash = hashSources();
	const marker = hashMarkerPath(configuration);
	// 构建落点与使用落点：dev 形态是同一个，release 形态是 /Applications 那一份。
	const target = install ?? product;

	if (hash !== undefined && existsSync(product) && readTextOrUndefined(marker) === hash) {
		// marker 与源码对得上，但 /Applications 里那份被删了（或从没装过）
		// ——那是一次拷贝的事，不必重编。
		if (install !== undefined && !existsSync(install)) {
			logger.info(`${configuration} 产物已是最新，但 ${install} 不在——直接安装既有产物。`);
			const copied = await installBuiltProduct({ configuration, install, logger, logPath: undefined });
			if (!copied.ok) return { appPath: undefined, freshness: "missing" };
			return { appPath: install, freshness: "fresh" };
		}
		logger.info(`${configuration} 产物已是最新（源码 hash ${hash.slice(0, 12)}），跳过构建。`);
		return { appPath: target, freshness: "cached" };
	}

	if (!(await hasXcode())) {
		logger.warn("未检测到完整 Xcode（xcodebuild 不可用，Command Line Tools 不够），跳过构建，只找既有产物。");
		return locateExistingProduct(configuration, install);
	}

	if (!existsSync(XCODEGEN)) {
		logger.error(`缺 ${XCODEGEN}（该二进制不入库，新克隆 / 新 worktree 里没有），跳过构建。`
			+ ` 补法：在仓库根跑一次 ./dev（会自动从同仓库的其它 worktree 或 PATH 拷一份），`
			+ ` 或 brew install xcodegen 后把它拷到上面那个路径。`);
		return locateExistingProduct(configuration, install);
	}

	logger.info(`壳源码有变动，开始构建 ${configuration}（首次约需分钟级）…`);
	const startedAt = Date.now();
	const result = await runBuild({ configuration, logger, isDisposed });
	if (isDisposed()) return { appPath: undefined, freshness: "missing" };
	if (!result.ok) {
		logger.error(`构建 ${configuration} 失败（改了源码才重试）。完整日志：${result.logPath}\n${tail(result.log, 20)}`);
		return { ...locateExistingProduct(configuration, install), failedHash: hash };
	}
	if (!existsSync(product)) {
		logger.error(`xcodebuild 报成功但产物不在 ${product}，放弃（改了源码才重试）。`);
		return { ...locateExistingProduct(configuration, install), failedHash: hash };
	}
	if (install !== undefined) {
		const copied = await installBuiltProduct({ configuration, install, logger, logPath: result.logPath });
		if (!copied.ok) {
			return { ...locateExistingProduct(configuration, install), failedHash: hash };
		}
	}
	if (hash !== undefined) writeFileSync(marker, hash);
	logger.info(`${configuration} 构建完成，用时 ${((Date.now() - startedAt) / 1000).toFixed(1)}s：${target}`);
	return { appPath: target, freshness: "fresh" };
}

/** `lsregister` 的绝对路径（LaunchServices 不在 PATH 上，只能写死）。 */
const LSREGISTER =
	"/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework" +
	"/Versions/A/Support/lsregister";

/**
 * 让系统重读刚装好的 bundle——**不做这一步，换了图标也还是旧图标**。
 *
 * `ditto` 连同源目录的 mtime 一起拷，而 `build/` 里那个 bundle 目录的 mtime 停在它
 * 第一次被创建的那一刻（后续增量构建只改内部文件），于是装到 `/Applications` 的这份
 * mtime 也是旧的。LaunchServices 按 **bundle 目录的 mtime** 判断"要不要重读图标"，
 * 看到没变就继续画缓存里那张旧图。
 *
 * 症状彻底静默：bundle 内容、`Info.plist`、`Assets.car` 全是新的，`NSWorkspace`
 * 查出来也是新的，只有 Dock / Finder 顽固地画旧的（2026-08-30 实测踩过，旧鲸鱼图标）。
 * 所以 `touch` 一下再强制重注册。失败无害——只是图标可能晚一点才刷新。
 */
async function refreshIconCache(install, logger) {
	try {
		const now = new Date();
		utimesSync(install, now, now);
		if (existsSync(LSREGISTER)) await run(LSREGISTER, ["-f", install], HOST_DIR);
	} catch (error) {
		logger.warn(`刷新图标缓存失败（无害，Dock 里可能还是旧图标）：${errorText(error)}`);
	}
}

/**
 * 把刚构建出来的产物装进 `install`（release 形态才走这条）。
 *
 * **绝不 quit 正在跑的 App**——这是与 `host/scripts/build.sh` 的关键分别：
 * 那个脚本是用户亲手跑的一条命令（闪断一次可以接受），而这里是常驻 daemon
 * 在后台发现源码变了，用户正对着窗口干活。换代由壳右上角的提示条驱动。
 *
 * 于是拷贝方式也不同：**先拷到同目录下的暂存名，再换名就位**，不做
 * `rm -rf 目标 && ditto`。两个理由——
 *
 *  1. 正在跑的 Mach-O 不能被原地覆写（`ETXTBSY`），链接器一族的标准做法都是
 *     "写新的、换名字"；
 *  2. `rm -rf` 到 `ditto` 完成之间有个几秒的窗口，那期间 `/Applications/Surfclam.app`
 *     根本不存在——用户这时候双击 Dock 图标就是一句"找不到应用程序"。
 *
 * 旧的那份换名到暂存后直接删：正在跑的进程早就把可执行文件映射进了内存，
 * unlink 不会伤到它（Unix 语义），而它之后按 bundle 路径读到的都是新的那一份
 * ——和 dev 形态下 xcodebuild 原地覆写 Debug 产物是同一种"新旧混用"，
 * 提示条存在的意义就是让这段混用尽快结束。
 */
async function installBuiltProduct({ configuration, install, logger, logPath }) {
	const product = productPath(configuration);
	const staging = join(dirname(install), `.${basename(install)}.clam-staging`);
	const previous = join(dirname(install), `.${basename(install)}.clam-previous`);
	try {
		rmSync(staging, { recursive: true, force: true });
		rmSync(previous, { recursive: true, force: true });
		await run("ditto", [product, staging], HOST_DIR);
		if (existsSync(install)) renameSync(install, previous);
		renameSync(staging, install);
		await refreshIconCache(install, logger);
		logger.info(`已安装到 ${install}（没有退出正在跑的实例——换代由窗口里的提示条驱动）。`);
	} catch (error) {
		const log = `安装到 ${install} 失败：${errorText(error)}`;
		logger.error(log);
		// 换名之间炸掉的话目标可能不在了，尽力把旧的那份放回去。
		try {
			if (!existsSync(install) && existsSync(previous)) renameSync(previous, install);
		} catch { /* 尽力而为，下面那句日志已经足够定位 */ }
		return { ok: false, log, logPath };
	} finally {
		try {
			rmSync(staging, { recursive: true, force: true });
			rmSync(previous, { recursive: true, force: true });
		} catch (error) {
			logger.warn(`清理安装暂存目录失败（无害，下次安装会再清一次）：${errorText(error)}`);
		}
	}
	return { ok: true, log: "", logPath };
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

/**
 * 不构建时的产物探测：先调用方指名的那一份（有的话），再本地 build/，
 * 最后 /Applications 的 Release 安装。
 *
 * @param preferred 期望的产物路径（见 {@link expectedAppPath}）；省略则只走后两级。
 */
function locateExistingProduct(configuration, preferred) {
	if (preferred !== undefined && existsSync(preferred)) {
		return { appPath: preferred, freshness: "prebuilt" };
	}
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
function writeEndpointFile({ httpBase, bridgePath, appPath, logger }) {
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
		// 同一个问题的第二条判据，**专为装到 /Applications 的 Release 壳**：
		// 那份产物不在任何 worktree 的 build/ 之下，hostDir 那条路推不出来。
		// 壳拿它跟自己的 Bundle.main.bundlePath 比（见 ClamEndpoint.isOwn）。
		appPath,
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
