/**
 * clam-app —— 壳源码与构建过程的插件化（阶段二计划 §7.5 v0）。
 *
 * 启动方向反转后 dsh 先于 app 存在，于是它就是壳天然的 bootstrapper。
 * **仓库里**本插件的载荷是 `host/` 里的整个 Xcode 工程，activate 时做三件事——
 *
 *   1. 写 endpoint 发现文件（`~/Library/Application Support/io.wenbo.surfclam/endpoints/<profile>.json`），
 *      让手动双击启动的 app 也能找到这个 dsh；fiber 卸载时删除。
 *   2. 源码 hash 变了或产物缺失 → xcodegen + xcodebuild（无 Xcode 则降级为只探测既有产物）。
 *   3. 产物存在且 app 尚未运行 → `open --args --clam-endpoint …` 拉起。
 *
 * **随 App 分发的那一份只有第 1 和第 3 件**（`host/` 不在包里，见下）。
 *
 * 起来之后还盯着壳源码（v1，§7.5）：变了就后台重建，经桥播报
 * `app-build`；壳把它变成一条"有新版，重启生效"的横幅。**重建不等于重启**——
 * 壳重启是重循环（进程退出、页面状态丢失），时机归用户，默认只提示。
 * 运行中的 app bundle 被覆盖在 macOS 上是安全的（旧进程继续跑旧映像）。
 *
 * **构建那一整套代码不在这个文件里，也不随包分发**：它住在
 * `clam-app/host-build/`（`docs/distribution-plan.md` §3.3），而本包的 `files`
 * 白名单只收 `lib/`、App 的 `ClamNode/` 载荷也只拷 `lib/` 与 `swift/`。
 * 判据因此**不是"探一下 host/ 在不在"，而是"那个模块 import 得到吗"**
 * （见下面那个模块级常量 `hostBuild`）——更诚实，也省掉一次文件系统探路。
 * 拿不到就是这份 clam-app 没有构建能力：`build` / `watch` / `restartOnRebuild`
 * 一律关掉，只剩第 1 和第 3 件事。
 *
 * 曾经的 `CLAM_RELEASE` 旋钮 2026-08-30 随 M4 一起删了
 * （`docs/distribution-plan.md` §3.3）：发布的 App 是 Developer ID 签名 + 公证过的，
 * 它自己 xcodebuild 重建自己产出的是 ad-hoc 签名，**当场把自己降级成"来路不明"**，
 * 所有热插件随之装载失败——所以正式形态根本不该有"要不要构建"这个开关，
 * 而不是有一个默认关掉的。
 *
 * 全程"优雅缺席"：构建失败、没有 Xcode、连既有产物都没有，都只在终端留一句话，
 * dsh 照常服务浏览器。首次构建失败不重试、不成环——防的是构建风暴；
 * 盯文件的重建则由"源码又变了"驱动，天然不会自己转圈。
 *
 * @module clam-app
 */
import { existsSync, mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import z from "@deepseek-ai/schemastery";
import { environmentLocale, localeFromTag } from "../../clam-bridge/lib/locale.js";
import { delay, errorText, readTextOrUndefined, resolveProfileName, run } from "./util.js";

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
 * 发现文件守护的间隔。比壳源码轮询松得多——这是自愈，不是热路径：文件只可能
 * 被"同 profile 的另一个 dsh 覆盖后退出"这一种情况带走，补晚几秒无伤。
 */
const ENDPOINT_GUARD_INTERVAL_MS = 5000;

/**
 * 桥路径的兜底值。**真相在 clam-bridge 的 config.path**——它才是挂 WS 的那一方，
 * 而且那是个用户可覆写的配置项。本插件经 `clamBridge.path` 取当前值（见 `apply`），
 * 只在桥缺席时用这个默认；写死一份自己的会让"改了桥的 path 壳就静默连不上"。
 * 与 Swift 侧 `ClamEndpoint.defaultBridgePath` 是同一个默认。
 */
const DEFAULT_BRIDGE_PATH = "/clam/bridge";

/**
 * 不挑地方的命令（`open` / `pgrep`）站在哪儿跑。
 *
 * **绝不能拿 `host/` 当 cwd**：源码不在场时那个目录不存在，而 `execFile` 的 cwd
 * 不存在会让**任何**命令都起不来。家目录必然在，且这两条命令对 cwd 没有依赖。
 * （构建那几条要站在 `HOST_DIR` 里，那是 `host-build/` 自己的事。）
 */
const NEUTRAL_CWD = homedir();

/** 装在 `/Applications` 的那个正式壳（dmg 装的那一份，也是 `build.sh` 的落点）。 */
const INSTALLED_APP = "/Applications/Surfclam.app";

/**
 * 构建那半边（`clam-app/host-build/`）——**`undefined` 就是这份 clam-app
 * 没有构建能力**。
 *
 * 判据不是"探一下 `host/project.yml` 在不在"，而是**模块本身 import 得到吗**
 * （`docs/distribution-plan.md` §3.3）。理由是它更诚实：随 App 分发的镜像与 npm
 * 包里，`host-build/` 连同 `host/` 一起**根本没被打进来**，构建这件事不是"被一个
 * 旋钮关掉了"，是压根不存在。省掉的那次文件系统探路是顺带的。
 *
 * 为什么正式形态不该有构建能力：发布的 App 是 Developer ID 签名 + 公证过的，
 * 自己 xcodebuild 重建自己产出的是 ad-hoc 签名，**当场把自己从"公证过"降级成
 * "来路不明"**，Hardened Runtime 与 entitlements 随之对不上，于是**所有热插件
 * 突然装载失败**——而症状完全不像签名问题。
 *
 * **顶层 await 是有意的**：`apply` 是同步的，而 endpoint 发现文件在 `apply` 的
 * 第一拍就要写、里面的 `appPath` 必须已经是对的（写错了壳会认不出"这是我这一套"）。
 * 顶层解析掉之后，下面全部是同步代码，不必为一次亚毫秒的本地 import 把整条链染成
 * 异步。dsh 的 loader 本来就是 `await import(entry)`，顶层 await 对它是透明的。
 *
 * **只有"模块不在"才算降级**：语法错之类如实报出来再降级，不静默
 * ——开发期真写坏了 `host-build/`，症状应当是一行响亮的日志，
 * 而不是"构建怎么不跑了"。
 */
const hostBuild = await importHostBuild();

async function importHostBuild() {
	try {
		return await import("../host-build/index.js");
	} catch (error) {
		if (error?.code === "ERR_MODULE_NOT_FOUND") return undefined;
		process.stderr.write(`clam-app: 加载 clam-app/host-build 失败，`
			+ `按"没有构建能力"降级：${errorText(error)}\n`);
		return undefined;
	}
}

/**
 * 没有构建能力时的配置覆写：**只关"要工具链才做得到的事"**，其余照 config。
 *
 * 关掉的两项都是同一个理由——`host-build/` 不在，xcodegen / xcodebuild 无从谈起，
 * 盯一棵不存在的源码树只会白读文件（`docs/distribution-plan.md` §7.10：
 * 桥那条 500ms 轮询在正式形态下是纯浪费，这条是同一个道理的 node 版）。
 * `restartOnRebuild` 跟着关，是因为它描述的是"重建成功之后"，而重建不会发生。
 *
 * **`launch` 不关**：正式形态下拉起是安全且有用的——App 早就在跑（后端正是它
 * spawn 的），`launch()` 自己会因为 `isRunning` 跳过；而用户手动
 * `dsh --profile surfclam` 时，把装好的 App 带起来正是他要的。
 * （从前 release 形态强制 `launch: false`，防的是常驻 LaunchAgent 在登录时弹窗口，
 * 那个 daemon 2026-08-30 已经退役。）
 */
function applyNoBuilderForm(config, logger) {
	if (hostBuild !== undefined) return config;
	logger.info("这份 clam-app 不带构建能力（没有 host-build/，随包分发的那一半只有 lib/）"
		+ `——不构建、不盯源码；壳用既有产物 ${INSTALLED_APP}。`);
	return { ...config, build: false, watch: false, restartOnRebuild: false };
}

/**
 * 本 dsh 期望的 App bundle 路径——**写进 endpoint 发现文件的 `appPath`，
 * 壳凭它认出"哪一份是我这一套"**（见 Swift 侧 `ClamEndpoint.isOwn`）。
 *
 * 为什么 `hostDir` 不够：装到 `/Applications` 的 Release 壳不在任何 worktree 的
 * `build/Build/Products/` 之下，`ClamPaths.ownHostDir` 推不出来，`isOwn` 于是恒假
 * ——那样它只能按 `startedAt` 倒序挑 dsh，多 worktree 并存时会安静地连上邻居。
 *
 * 没有构建能力 = 这个后端是装好的那个 App 自己 spawn 的（或者用户手动起的、
 * 冲着那个 App 去的），期望的产物只可能是 `/Applications` 里那一份。
 */
function expectedAppPath(config) {
	return hostBuild === undefined ? INSTALLED_APP : hostBuild.productPath(config.configuration);
}

/** 不构建时的产物探测。没有构建能力时只有 `preferred` 一条候选——本地 `build/` 根本不存在。 */
function locateProduct(config) {
	const preferred = expectedAppPath(config);
	if (hostBuild !== undefined) {
		return hostBuild.locateExistingProduct(config.configuration, preferred);
	}
	return existsSync(preferred)
		? { appPath: preferred, freshness: "prebuilt" }
		: { appPath: undefined, freshness: "missing" };
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
	const config = applyNoBuilderForm(rawConfig, logger);
	const httpBase = resolveHttpBase(ctx.webServer);
	const appPath = expectedAppPath(config);

	// 先登记服务名，让下游 inject 能等；产物定下来后再 set 值。
	ctx.provide("clamApp", undefined);

	// 桥的当前状态。**可变引用，不是快照**：桥可以晚于本插件挂载、也可以中途卸载，
	// 而 endpoint 文件与 `open --args` 都要用它此刻的值。
	const bridge = { path: DEFAULT_BRIDGE_PATH, announce: () => {} };

	// 发现文件先于构建落地：一个手动启动的 app 立刻就能接入，
	// 不必等分钟级的首次构建。桥若带来不同的 path，下面的 inject 回调会重写它。
	//
	// **写完还要守着**：文件名按 profile 分片、覆盖写，而 `removeEndpointFile`
	// 只认"文件里的 pid 是不是我"。于是同一个 profile 上短暂起过第二个 dsh 时，
	// 它会先覆盖掉我们这份、退出时再按 pid 校验删掉（那时 pid 确实是它自己的），
	// **把还活着的我们一起带走**——本进程只在挂载时写过一次，从此永久隐身：
	// 壳发现不了它，用户双击只看得到连接页，而托管的查重又因为"daemon 在跑"
	// 拒绝 spawn，两头堵死（实测：daemon 活着监听 54400、HTTP 200，
	// endpoints/ 目录却是空的）。所以这里常驻一条守护，缺了就补回来。
	ctx.effect(() => {
		writeEndpointFile({ httpBase, bridgePath: bridge.path, appPath, logger });
		const guard = setInterval(() => {
			// **只补缺失的**：文件在、但写着别人的 pid，说明这个 profile 上另有
			// 一个活跃实例。抢回来只会变成两边对着写，那是更糟的数据损坏——
			// 让它去，等它退出时把文件删掉，下一轮我们自然补上。
			if (readTextOrUndefined(endpointFilePath()) !== undefined) return;
			logger.info("endpoint 发现文件不见了（多半被同 profile 的另一个 dsh 覆盖后带走），补写回来。");
			writeEndpointFile({ httpBase, bridgePath: bridge.path, appPath, logger });
		}, ENDPOINT_GUARD_INTERVAL_MS);
		guard.unref?.();
		return () => {
			clearInterval(guard);
			removeEndpointFile(logger);
		};
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
	// 不构建时**先认 expectedAppPath 那一份**：源码不在场时期望的是 /Applications
	// 那个安装产物，不指名道姓就会挑中本地 build/ 里可能躺着的同名产物，
	// 于是 endpoint 文件里的 appPath 与本插件自己认的产物分了家。
	const built = config.build
		? await hostBuild.ensureBuilt({ configuration, logger, isDisposed })
		: locateProduct(config);

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
		hostBuild.watchSources({
			ctx, config, logger, bridge, isDisposed, configuration,
			failedHash: built.failedHash,
		});
	}
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
			"--clam-bridge-path", bridgePath], NEUTRAL_CWD);
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
		hostDir: hostBuild?.HOST_DIR.replace(/\/$/, ""),
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

// ---------------------------------------------------------------- 子进程

/** 按可执行文件路径认进程（同 dev.sh），Debug/Release 名字不同不会互相误伤。 */
async function isRunning(appPath) {
	try {
		await run("pgrep", ["-f", `${appPath}/Contents/MacOS/`], NEUTRAL_CWD);
		return true;
	} catch {
		return false;
	}
}
