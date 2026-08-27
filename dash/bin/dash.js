#!/usr/bin/env node
/**
 * dash 的安装器与开发启动器——一条命令把 profile 备齐并跑起来。
 *
 * 两种模式，靠"伞包的兄弟目录里有没有插件源码"自动判别，不需要 flag：
 *
 *   registry 模式（发布后的用户）
 *     npx @wenbo/dash
 *     伞包躺在 npx 缓存里，没有兄弟目录 → 从 registry 装 @wenbo/dash，
 *     它的 dependencies 由 pnpm 一并装进 profile。profile 名 `dash`。
 *
 *   link 模式（本仓库开发）
 *     node dash/bin/dash.js        （或仓库根的 ./dev）
 *     兄弟目录里有 dash-app/ 等 → 把本 worktree 的各插件 + 伞包全部 link
 *     进 profile。改一行存盘即生效，不必发布任何东西。
 *
 * **为什么 link 模式要单独 link 那些插件**：pnpm 对 `link:` 依赖不会去装
 * 被 link 目标自己的 dependencies，而 cordis loader 解析插件包名时的锚点是
 * **profile 目录**——伞包自带的 node_modules 根本不在 Node 的向上查找链上。
 * 所以它们必须自己出现在 profile 的 node_modules 里。这不会造成重复挂载：
 * 各插件都已摘掉 dsh.bundle 声明，reconcile 不会把它们加进 bundles，
 * 编排权只在伞包那张表上。
 *
 * **worktree**：profile 名随 worktree 走（主 worktree = `dash`，其余 =
 * `dash-<目录名>`），端口默认 `--port 0` 让 OS 挑。于是每个 worktree 各有
 * 一套插件、一个 dsh、一个 App 实例（App 产物路径本就随 worktree 不同），
 * 互不打扰。
 *
 * @module @wenbo/dash/bin
 */
import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, existsSync, lstatSync, mkdirSync, readFileSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/** 伞包根（本文件在 bin/ 下）。 */
const UMBRELLA_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");

/** 伞包自己的包名——profile 的 bundles 里认的就是它。 */
const UMBRELLA = "@wenbo/dash";

/**
 * xcodegen 二进制在仓库里的位置（相对仓库根）。dash-app/lib/index.js 与
 * `dash-app/host/scripts/{dev,build}.sh` 都写死这条路径，改它要三处一起改。
 */
const XCODEGEN_REL = "dash-app/host/tools/xcodegen";

/** 必须在 bundles 里、且必须排在最前的三层 patch。dsh 自带的两个不用装。 */
const REQUIRED_BUNDLES = ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", UMBRELLA];

function main() {
	const opts = parseArgs(process.argv.slice(2));
	if (opts.help) return usage();

	const manifest = readJson(join(UMBRELLA_DIR, "package.json"));
	/** 被编排的插件包名，从伞包的 dependencies 取——加插件只需改那里。 */
	const pluginNames = Object.keys(manifest.dependencies ?? {});

	const repoRoot = detectRepoRoot(pluginNames);
	const profile = opts.profile ?? defaultProfile(repoRoot);

	say(repoRoot === undefined
		? `registry 模式（从 npm 装）→ profile ${profile}`
		: `link 模式（本地源码 ${repoRoot}）→ profile ${profile}`);

	if (repoRoot !== undefined) {
		ensureModuleResolution(repoRoot);
		ensureXcodegen(repoRoot);
	}
	installInto(profile, repoRoot, pluginNames);
	fixBundles(profile, pluginNames);

	if (opts.installOnly) {
		say(`装好了。启动：dsh --profile ${profile} --no-open`);
		return;
	}
	start(profile, opts);
}

// ---------------------------------------------------------------- 模式与命名

/**
 * link 模式判据：伞包的兄弟目录里有插件源码。npx 缓存里的伞包没有兄弟，
 * 于是自动落到 registry 模式——不需要用户记住任何 flag。
 * @param pluginNames - 伞包 dependencies 里的包名。
 * @returns 仓库根，或 undefined 表示 registry 模式。
 */
function detectRepoRoot(pluginNames) {
	const parent = dirname(UMBRELLA_DIR);
	const anyPlugin = pluginNames[0];
	if (anyPlugin === undefined) return undefined;
	return existsSync(join(parent, dirOf(anyPlugin), "package.json")) ? parent : undefined;
}

/** `@wenbo/dash-app` → `dash-app`：包名去掉 scope 就是仓库里的目录名。 */
function dirOf(packageName) {
	return packageName.startsWith("@") ? packageName.split("/")[1] : packageName;
}

/**
 * profile 名。主 worktree 用 `dash`，其余 worktree 用 `dash-<目录名>`——
 * 于是"一个 worktree 一行命令起一套自己的东西"不需要任何额外记忆。
 * @param repoRoot - 仓库根；undefined（registry 模式）时固定为 `dash`。
 */
function defaultProfile(repoRoot) {
	if (repoRoot === undefined) return "dash";
	try {
		const gitDir = git(repoRoot, ["rev-parse", "--absolute-git-dir"]);
		const common = git(repoRoot, ["rev-parse", "--path-format=absolute", "--git-common-dir"]);
		if (gitDir === common) return "dash";
		return `dash-${basename(repoRoot)}`;
	} catch {
		// 不是 git 仓库（或 git 不可用）：按目录名区分，仍然满足"各 worktree 各一套"。
		return `dash-${basename(repoRoot)}`;
	}
}

function git(cwd, args) {
	return execFileSync("git", args, { cwd, encoding: "utf8" }).trim();
}

// ---------------------------------------------------------------- 安装

/**
 * 把该装的装进 profile。`dsh plugin` 首次调用会自动 init profile，
 * 所以这里不必先建目录。重复跑是幂等的（pnpm 对已在位的 link 是 no-op）。
 */
function installInto(profile, repoRoot, pluginNames) {
	const specs = repoRoot === undefined
		? [UMBRELLA]
		// 顺序有讲究：先让各插件在 node_modules 里就位，再 link 伞包，
		// 这样伞包那张表指向的包名在任何时刻都解析得到。
		: [...pluginNames.map((n) => `link:${join(repoRoot, dirOf(n))}`), `link:${UMBRELLA_DIR}`];

	say(`装入 profile ${profile}：${specs.length} 个包…`);
	try {
		execFileSync("dsh", ["plugin", "--profile", profile, "add", ...specs],
			{ stdio: ["ignore", "pipe", "pipe"], encoding: "utf8" });
	} catch (error) {
		fail(`dsh plugin add 失败：\n${(error.stderr ?? error.stdout ?? error.message).trim()}`);
	}
}

/**
 * 校正 `dsh.profile.bundles`。两件事非做不可：
 *
 *  1. **补 `@deepseek-ai/dsh-web-app`**。它是 dsh 自带的 in-box bundle，
 *     `resolveBundleDir` 会从 dsh 安装目录解析，不必装；但只有 `web` 和
 *     `headless` 两个名字有 shipped template，别的 profile 初始化时只给
 *     `dsh-base`，web 那一层得自己列上。
 *  2. **踢掉被编排的那些插件**。它们本身已不是 bundle，正常不会被 reconcile
 *     加进来；这里防的是从旧结构升级上来的 profile——那时它们各自是 bundle，
 *     留在列表里会和伞包的表各 insert 一遍，同一个插件挂载两次。
 *
 * 其余条目（用户自己 add 的别家插件）原样保留在后面。
 */
function fixBundles(profile, pluginNames) {
	const manifestPath = join(profileDir(profile), "package.json");
	const manifest = readJson(manifestPath);
	const before = manifest.dsh?.profile?.bundles ?? [];
	const drop = new Set([...REQUIRED_BUNDLES, ...pluginNames]);
	const after = [...REQUIRED_BUNDLES, ...before.filter((b) => !drop.has(b))];

	if (JSON.stringify(before) === JSON.stringify(after)) return;
	manifest.dsh = { ...manifest.dsh, profile: { ...manifest.dsh?.profile, bundles: after } };
	writeFileSync(manifestPath, `${JSON.stringify(manifest, undefined, 2)}\n`);
	say(`bundles 校正为：${after.join(" + ")}`);
}

/** `$DSH_HOME`，与 dsh 的 resolveDshHome 同义。 */
function dshHome() {
	const home = process.env.DSH_HOME?.trim();
	return home !== undefined && home !== "" ? home : join(homedir(), ".dsh");
}

/** `$DSH_HOME/profiles/<name>`。 */
function profileDir(profile) {
	return join(dshHome(), "profiles", profile);
}

/**
 * 让仓库放在**任何地方**都能解析 `@deepseek-ai/*`。
 *
 * dsh 那些包平铺在 `$DSH_HOME/profiles/node_modules/`，插件靠 Node 从自己所在
 * 目录逐级向上找 `node_modules` 命中它们——所以历史上仓库必须待在
 * `$DSH_HOME/profiles/` 之下（老 CLAUDE.md 里的 §1.4 硬约束）。
 *
 * 其实只要在仓库根补一条指向那里的符号链接，向上查找第一步就命中，约束即刻解除
 * （实测：仓库搬到 /tmp 下、加上这条链接后 dsh 照常起、HTTP 200）。
 *
 * **为什么是符号链接而不是把 `@deepseek-ai/*` 真装进仓库**：cordis 的服务与
 * Schema 是按实例身份认人的，插件必须用 dsh 自己进程里的那一份。链接天然保证
 * 这一点；装一份版本号相同的副本反而会因为实例不同而出诡异的错。
 *
 * 仓库本来就在 `profiles/` 下时什么都不做——那时向上查找本来就能命中。
 */
function ensureModuleResolution(repoRoot) {
	const profilesRoot = join(dshHome(), "profiles");
	if (realpath(repoRoot).startsWith(`${realpath(profilesRoot)}/`)) return;

	const link = join(repoRoot, "node_modules");
	const target = join(profilesRoot, "node_modules");
	if (!existsSync(target)) {
		fail(`找不到 ${target}——dsh 装好了吗？（npm i -g @deepseek-ai/dsh）`);
	}

	const current = lstatSync(link, { throwIfNoEntry: false });
	if (current?.isSymbolicLink() === true) {
		if (realpath(readlinkSync(link)) === realpath(target)) return;
		rmSync(link);
	} else if (current !== undefined) {
		// 真实目录：可能是用户自己 pnpm install 出来的，不擅自删。
		say(`⚠ ${link} 是真实目录而不是符号链接，跳过；`
			+ `若 @deepseek-ai/* 解析不到，把它删掉再跑一次。`);
		return;
	}
	symlinkSync(target, link, "dir");
	say(`已补上 node_modules → ${target}（仓库在 profiles/ 之外时的解析桥）`);
}

/**
 * 保证本 worktree 有 `dash-app/host/tools/xcodegen`。
 *
 * 那个二进制**被 .gitignore 挡在库外**（二进制不该入库，规则本身是对的），
 * 于是任何新克隆 / 新 worktree 里它都不存在，而 dash-app 和两个构建脚本都直接
 * spawn 它。失败模式极不友好：dsh 照常起、HTTP 200，只是壳静默缺席
 * （`spawn …/tools/xcodegen ENOENT` 埋在构建日志里），而 CLAUDE.md 承诺的是
 * "在任意 worktree 里跑 ./dev 即可"。所以这里和上面那条 node_modules 链接一样，
 * 属于"把机器本地状态补齐"的兜底。
 *
 * 取件顺序：同仓库的其它 worktree（版本必然一致）→ PATH 上的 xcodegen。
 * 一律**拷贝**而不是链接：14MB 一次性开销换"主 worktree 被删掉也不会突然
 * 变回 ENOENT"，而且 dash-app 的 HASHED_ROOTS 明确把 `tools/` 排除在源码 hash
 * 之外，多这个文件不会触发壳的全量重建。
 *
 * 找不到时**只警告不中止**：没装 Xcode 的机器本来就该优雅缺席，
 * 为了一个可选的壳把 dsh 拦下来是本末倒置。
 */
function ensureXcodegen(repoRoot) {
	const local = join(repoRoot, XCODEGEN_REL);
	if (existsSync(local)) return;

	const source = findXcodegen(repoRoot);
	if (source === undefined) {
		say(`⚠ 缺 ${XCODEGEN_REL}——壳构建会失败，dash-app 优雅缺席（只有浏览器，没有 App）。`);
		say(`  补法（二选一，然后重跑本命令）：`);
		say(`    brew install xcodegen`);
		say(`    从 https://github.com/yonaskolb/XcodeGen/releases 下载 xcodegen.zip，`);
		say(`      把里面的 bin/xcodegen 拷到 ${local} 并 chmod +x`);
		return;
	}

	mkdirSync(dirname(local), { recursive: true });
	copyFileSync(source, local);
	chmodSync(local, 0o755);
	say(`已补上 ${XCODEGEN_REL} ← ${source}`);
}

/** 先问同仓库的其它 worktree，再问 PATH。都没有就 undefined。 */
function findXcodegen(repoRoot) {
	for (const dir of otherWorktrees(repoRoot)) {
		const candidate = join(dir, XCODEGEN_REL);
		if (existsSync(candidate)) return candidate;
	}
	return whichXcodegen();
}

/**
 * 同一个 git 仓库的其它 worktree 目录。`git worktree list` 在任何 worktree 里
 * 跑都会把主 worktree 排在第一个，所以"从主仓库拷"这件事不必单独推路径。
 */
function otherWorktrees(repoRoot) {
	try {
		const self = realpath(repoRoot);
		return git(repoRoot, ["worktree", "list", "--porcelain"])
			.split("\n")
			.filter((line) => line.startsWith("worktree "))
			.map((line) => line.slice("worktree ".length))
			.filter((dir) => realpath(dir) !== self);
	} catch {
		// 不是 git 仓库、或 git 不可用：还有 PATH 那条路。
		return [];
	}
}

function whichXcodegen() {
	const result = spawnSync("which", ["xcodegen"], { encoding: "utf8" });
	const path = result.stdout?.trim();
	return result.status === 0 && path !== undefined && path !== "" ? path : undefined;
}

function realpath(path) {
	try {
		return realpathSync(path);
	} catch {
		return path;
	}
}

// ---------------------------------------------------------------- 启动

/**
 * 前台跑 dsh，把终端整个让给它（Ctrl-C 直达 dsh）。
 *
 * 端口默认 `0`：OS 挑一个空闲的。多 worktree 并行时这是唯一不用协调的做法，
 * 而 App 那边不受影响——dash-app 把实际端口写进 endpoint 文件、也用
 * `--dash-endpoint` 直接递给它拉起的壳。
 */
function start(profile, opts) {
	const args = ["--profile", profile, "--port", String(opts.port), "--no-open", ...opts.passthrough];
	say(`启动：dsh ${args.join(" ")}\n`);
	const result = spawnSync("dsh", args, { stdio: "inherit" });
	if (result.error !== undefined) fail(`启动 dsh 失败：${result.error.message}`);
	process.exit(result.status ?? 0);
}

// ---------------------------------------------------------------- 杂项

function parseArgs(argv) {
	const opts = { profile: undefined, port: 0, installOnly: false, help: false, passthrough: [] };
	for (let i = 0; i < argv.length; i += 1) {
		const a = argv[i];
		if (a === "--") { opts.passthrough = argv.slice(i + 1); break; }
		else if (a === "--profile") { opts.profile = argv[++i]; }
		else if (a === "--port") { opts.port = Number(argv[++i]); }
		else if (a === "--install-only") { opts.installOnly = true; }
		else if (a === "-h" || a === "--help") { opts.help = true; }
		else fail(`无法识别的参数 ${a}（想传给 dsh 的话放在 -- 之后）`);
	}
	if (!Number.isInteger(opts.port) || opts.port < 0 || opts.port > 65535) fail("--port 要是 0..65535");
	return opts;
}

function usage() {
	process.stdout.write(`dash —— 安装并启动一套 dash（dsh + macOS 原生壳）

  npx @wenbo/dash                 装到 profile 'dash' 并启动
  node dash/bin/dash.js           本仓库开发：link 本 worktree 的源码

选项
  --profile <name>   覆盖 profile 名（默认：主 worktree 用 dash，
                     其他 worktree 用 dash-<目录名>）
  --port <n>         监听端口，默认 0（让 OS 挑，多 worktree 不会撞）
  --install-only     只装不启动
  -- <args...>       其余参数透传给 dsh
`);
}

function readJson(path) {
	try {
		return JSON.parse(readFileSync(path, "utf8"));
	} catch (error) {
		fail(`读不了 ${path}：${error.message}`);
	}
}

function say(message) {
	process.stderr.write(`dash: ${message}\n`);
}

function fail(message) {
	process.stderr.write(`dash: ${message}\n`);
	process.exit(1);
}

main();
