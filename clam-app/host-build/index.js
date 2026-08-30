/**
 * clam-app 的**构建那半边**：算源码 hash、xcodegen + xcodebuild、盯源码后台重建。
 *
 * **这个目录整个不随包分发**（`docs/archive/distribution-plan.md` §3.3）——
 * `clam-app/package.json` 的 `files` 白名单只收 `lib/`，App 的 `ClamNode/` 载荷
 * 也只拷 `lib/` 与 `swift/`。判据因此不是"运行时探一下路径"，而是
 * **"这个模块在不在"**：`lib/index.js` 用 `await import(…).catch(…)` 拿它，
 * 拿不到就是这份 clam-app 没有构建能力，`build` / `watch` / `restartOnRebuild`
 * 一律关掉、xcodebuild 一次都不会跑。
 *
 * 为什么正式形态不该有构建能力（不只是"默认关掉"）：发布的 App 是
 * Developer ID 签名 + 公证过的，自己 xcodebuild 重建自己产出的是 ad-hoc 签名，
 * **当场把自己从"公证过"降级成"来路不明"**，Hardened Runtime 与 entitlements
 * 随之对不上，于是**所有热插件突然装载失败**——而症状完全不像签名问题。
 *
 * **`app-build` 那条播报通道不在这儿**：它长在 clam-bridge 上，本模块只是**触发源**。
 * 触发源缺席时通道空转，正是 §8 M6（Sparkle 自动更新）要复用的形状。
 *
 * @module clam-app/host-build
 */
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { errorText, readTextOrUndefined, resolveProfileName, run as runIn } from "../lib/util.js";
import { HOST_DIR, hashMarkerPath, hashSources, signatureSources } from "./source-hash.js";

export { HOST_DIR };

/**
 * xcodegen 二进制。**被 .gitignore 挡在库外**（`/clam-app/host/tools/`），
 * 所以新克隆 / 新 worktree 里它不存在——`surfclam/bin/surfclam.js` 的 ensureXcodegen
 * 会在 `./dev` 时从别的 worktree 或 PATH 拷一份补上。这里做一次显式存在性检查，
 * 是因为不做的话失败长成 `spawn …/tools/xcodegen ENOENT`：一句既不说明原因
 * 也不说明补法的话，还埋在构建日志里。
 */
const XCODEGEN = join(HOST_DIR, "tools", "xcodegen");

/** 壳的 Application Support 根目录，与 `lib/index.js` 的同名常量、Swift 侧 `ClamPaths.appSupport` 必须一致。 */
const APP_SUPPORT = join(homedir(), "Library", "Application Support", "io.wenbo.surfclam");

/** 产物落点由 xcodebuild 的 `-derivedDataPath build` 固定（见仓库 CLAUDE.md 硬约束）。 */
export const productPath = (configuration) =>
	join(HOST_DIR, "build", "Build", "Products", configuration,
		`${configuration === "Debug" ? "Surfclam Dev" : "Surfclam"}.app`);

/** 构建那几条命令**必须站在 `HOST_DIR` 里**（xcodegen 认工作目录，xcodebuild 的相对 derivedDataPath 也认）。 */
const run = (file, args, options) => runIn(file, args, HOST_DIR, options);

/**
 * 保证 `configuration` 的产物是新的：hash 没变且产物在 → 直接用；
 * 否则跑一遍 xcodegen + xcodebuild。没有 Xcode 时退化为只探测既有产物。
 *
 * **只有带构建能力的那一份 clam-app 到得了这里**（`lib/index.js` 拿不到本模块就把
 * `config.build` 关掉了）
 * ——所以这里可以放心地把构建落点当成使用落点：`-derivedDataPath build` 是硬约束，
 * 产物就在 `host/build/Build/Products/<配置>/` 下，没有第二个落点。
 * （2026-08-30 M4 之前还有一条"构建完拷进 `/Applications`"的支路，服务于那个
 * 常驻 daemon 形态；壳不再自己构建自己之后，装进 `/Applications` 只剩
 * `host/scripts/build.sh` 一条路。）
 *
 * 返回值多一个 `failedHash`：构建真的跑了并且失败时才有值，调用方据此决定
 * "要不要继续盯源码"（见 bootstrap）与"哪个 hash 不必重试"（见 watchSources）。
 */
export async function ensureBuilt({ configuration, logger, isDisposed }) {
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
		logger.error(`构建 ${configuration} 失败（改了源码才重试）。完整日志：${result.logPath}\n${tail(result.log, 20)}`);
		return { ...locateExistingProduct(configuration), failedHash: hash };
	}
	if (!existsSync(product)) {
		logger.error(`xcodebuild 报成功但产物不在 ${product}，放弃（改了源码才重试）。`);
		return { ...locateExistingProduct(configuration), failedHash: hash };
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

/**
 * 盯壳源码（§7.5 v1）。与桥盯 `swift/` 同款的廉价轮询：先比 mtime/size 签名，
 * 签名变了才读内容算 hash——hash 才是"要不要重建"的判据（换 git 分支不算改过）。
 *
 * 播报走 `apply` 里那一处 `ctx.inject` 攒下的 `bridge.announce`：clam-bridge 在
 * 就播，不在就只写终端。壳没连上来时重建照做。
 */
export function watchSources({ ctx, config, logger, bridge, isDisposed, configuration, failedHash }) {
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
		const result = await runBuild({ configuration, logger, isDisposed });
		building = false;
		if (isDisposed()) return;

		if (result.ok) {
			builtHash = hash;
			lastFailedHash = undefined;
			writeFileSync(hashMarkerPath(configuration), hash);
			const seconds = ((Date.now() - startedAt) / 1000).toFixed(1);
			logger.info(`壳已重建（${seconds}s）。`
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
 * 不构建时的产物探测：先调用方指名的那一份（有的话），再本地 `build/`。
 *
 * **没有第三跳**（2026-08-30 M4 删掉的那条 `/Applications/Surfclam.app` 兜底）。
 * 从前它服务于"dsh 先起、去找一个可能存在的 App"那个旧模型，如今两种形态都不需要
 * 而且它会**安静地连错**：
 *
 *  - 没有构建能力时压根到不了这个函数（`lib/index.js` 自己单跳看 `preferred`），
 *    第一跳已经覆盖，兜底是重复的；
 *  - 源码在场时（`./dev`、worktree），本地 `build/` 里没有产物就该**优雅缺席**。
 *    退到装好的那个正式壳等于让 `surfclam-dev` 的后端去拉起属于 profile
 *    `surfclam` 的 App——两套 profile 的内容本来就不同（一个 link 仓库源码、
 *    一个 link 自举镜像，`docs/archive/distribution-plan.md` §3.6），凑到一起正是分片要
 *    消掉的那种混线。
 *
 * @param preferred 期望的产物路径（见 {@link expectedAppPath}）；省略则只看本地 `build/`。
 */
export function locateExistingProduct(configuration, preferred) {
	if (preferred !== undefined && existsSync(preferred)) {
		return { appPath: preferred, freshness: "prebuilt" };
	}
	const product = productPath(configuration);
	if (existsSync(product)) return { appPath: product, freshness: "prebuilt" };
	return { appPath: undefined, freshness: "missing" };
}

/** 完整 Xcode 才有 xcodebuild；Command Line Tools 单独装是不够的。 */
async function hasXcode() {
	try {
		await run("xcodebuild", ["-version"]);
		return true;
	} catch {
		return false;
	}
}


function tail(text, lines) {
	return text.trimEnd().split("\n").slice(-lines).join("\n");
}
