#!/usr/bin/env node
/**
 * surfclam 的安装器与开发启动器——一条命令把 profile 备齐并跑起来。
 *
 * 两种模式，靠"伞包的兄弟目录里有没有插件源码"自动判别，不需要 flag：
 *
 *   registry 模式（发布后的用户）
 *     npx @wenbo/surfclam
 *     伞包躺在 npx 缓存里，没有兄弟目录 → 从 registry 装 @wenbo/surfclam，
 *     它的 dependencies 由 pnpm 一并装进 profile。profile 名 `surfclam`。
 *
 *   link 模式（本仓库开发）
 *     node surfclam/bin/surfclam.js    （或仓库根的 ./dev）
 *     兄弟目录里有 clam-app/ 等 → 把本 worktree 的各插件 + 伞包全部 link
 *     进 profile。改一行存盘即生效，不必发布任何东西。
 *
 * **为什么 link 模式要单独 link 那些插件**：pnpm 对 `link:` 依赖不会去装
 * 被 link 目标自己的 dependencies，而 cordis loader 解析插件包名时的锚点是
 * **profile 目录**——伞包自带的 node_modules 根本不在 Node 的向上查找链上。
 * 所以它们必须自己出现在 profile 的 node_modules 里。这不会造成重复挂载：
 * 各插件都已摘掉 dsh.bundle 声明，reconcile 不会把它们加进 bundles，
 * 编排权只在伞包那张表上。
 *
 * **worktree**：profile 名随 worktree 走（主 worktree = `surfclam`，其余 =
 * `surfclam-<目录名>`），端口默认 `--port 0` 让 OS 挑。于是每个 worktree 各有
 * 一套插件、一个 dsh、一个 App 实例（App 产物路径本就随 worktree 不同），
 * 互不打扰。
 *
 * **第三条路径 `--release`**（仓库根的 `./release`，计划见
 * `docs/release-install-plan.md`）：把这台机器装成正式形态——**只装 App**，
 * Release 壳进 `/Applications`，之后双击就能用，不必开着终端。它与上面两种
 * 模式共用全部安装函数，只是**不前台跑 dsh**，也**不再装任何常驻服务**：
 * 后端归壳自己托管（连接偏好默认 `managed`，打开即有、⌘Q 即退）。
 * profile 仍然只有 `surfclam` 一个（不设第二张编排表，形态差别由环境变量
 * `CLAM_RELEASE=1` 表达，clam-app 读它，壳 spawn 后端时带上）。
 *
 * 2026-08-30 之前这条路径还会装一个 LaunchAgent 常驻跑 dsh，那一层整个退役了
 * ——多一层 launchd 常驻就多一整类互斥死锁（它与托管抢同一个 profile、互抹
 * endpoint 发现文件），而壳对它只有观测权没有控制权。装过旧版的机器跑一次
 * `./release` 会自动把它清掉（`removeLegacyDaemon`）。
 *
 * @module @wenbo/surfclam/bin
 */
import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, existsSync, lstatSync, mkdirSync, readFileSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/** 伞包根（本文件在 bin/ 下）。 */
const UMBRELLA_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");

/** 伞包自己的包名——profile 的 bundles 里认的就是它。 */
const UMBRELLA = "@wenbo/surfclam";

/**
 * xcodegen 二进制在 **clam-app 包内**的位置。clam-app/lib/index.js 与
 * `clam-app/host/scripts/{dev,build}.sh` 都写死这条路径，改它要三处一起改。
 *
 * 分成两个常量是因为两种模式的落点不同、而包内那一段是同一段：link 模式下
 * clam-app 是仓库里的一个目录，registry 模式下它是装进 profile 的一个 npm 包。
 */
const XCODEGEN_IN_PACKAGE = "host/tools/xcodegen";

/** link 模式的落点（相对仓库根）。 */
const XCODEGEN_REL = `clam-app/${XCODEGEN_IN_PACKAGE}`;

/** 必须在 bundles 里、且必须排在最前的三层 patch。dsh 自带的两个不用装。 */
const REQUIRED_BUNDLES = ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", UMBRELLA];

function main() {
	const opts = parseArgs(process.argv.slice(2));
	if (opts.help) return usage();

	const manifest = readJson(join(UMBRELLA_DIR, "package.json"));
	/** 被编排的插件包名，从伞包的 dependencies 取——加插件只需改那里。 */
	const pluginNames = Object.keys(manifest.dependencies ?? {});

	const repoRoot = detectRepoRoot(pluginNames);

	if (opts.release) return release(opts, repoRoot, pluginNames);

	const profile = opts.profile ?? defaultProfile(repoRoot);

	say(repoRoot === undefined
		? `registry 模式（从 npm 装）→ profile ${profile}`
		: `link 模式（本地源码 ${repoRoot}）→ profile ${profile}`);

	provision(profile, repoRoot, pluginNames);

	if (opts.installOnly) {
		say(`装好了。启动：dsh --profile ${profile} --no-open`);
		return;
	}
	start(profile, opts);
}

/**
 * 把 profile 备齐（安装那几步的全部内容）。dev 与 release 两条路径共用它——
 * **本机安装不是另一套安装**，只是安装完之后把 dsh 交给 launchd 而不是终端。
 */
function provision(profile, repoRoot, pluginNames) {
	if (repoRoot !== undefined) {
		ensureModuleResolution(repoRoot);
		ensureXcodegen(join(repoRoot, XCODEGEN_REL), repoRoot);
	}
	installInto(profile, repoRoot, pluginNames);
	// registry 模式的落点**要等装完才存在**：那时 clam-app 才是 profile 里的一个
	// 真实目录。缺了它的症状和 link 模式一模一样（dsh 起、HTTP 200、壳静默缺席），
	// 所以两种模式都得补——只是取件处少一条（npx 缓存里没有兄弟 worktree）。
	if (repoRoot === undefined) {
		const target = installedXcodegenPath(profile, pluginNames);
		if (target !== undefined) ensureXcodegen(target, undefined);
	}
	fixBundles(profile, pluginNames);
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

/** `@wenbo/clam-app` → `clam-app`：包名去掉 scope 就是仓库里的目录名。 */
function dirOf(packageName) {
	return packageName.startsWith("@") ? packageName.split("/")[1] : packageName;
}

/**
 * profile 名。主 worktree 用 `surfclam`，其余 worktree 用 `surfclam-<目录名>`——
 * 于是"一个 worktree 一行命令起一套自己的东西"不需要任何额外记忆。
 * @param repoRoot - 仓库根；undefined（registry 模式）时固定为 `surfclam`。
 */
function defaultProfile(repoRoot) {
	if (repoRoot === undefined) return "surfclam";
	try {
		const gitDir = git(repoRoot, ["rev-parse", "--absolute-git-dir"]);
		const common = git(repoRoot, ["rev-parse", "--path-format=absolute", "--git-common-dir"]);
		if (gitDir === common) return "surfclam";
		return `surfclam-${basename(repoRoot)}`;
	} catch {
		// 不是 git 仓库（或 git 不可用）：按目录名区分，仍然满足"各 worktree 各一套"。
		return `surfclam-${basename(repoRoot)}`;
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
 * 保证 clam-app 边上有 `host/tools/xcodegen`。
 *
 * 那个二进制**被 .gitignore 挡在库外**（二进制不该入库，规则本身是对的），
 * 也**不在 npm 包里**（`files` 白名单收的是源码），于是任何新克隆 / 新 worktree /
 * 新装的 profile 里它都不存在，而 clam-app 和两个构建脚本都直接 spawn 它。
 * 失败模式极不友好：dsh 照常起、HTTP 200，只是壳静默缺席
 * （`spawn …/tools/xcodegen ENOENT` 埋在构建日志里），而 CLAUDE.md 承诺的是
 * "在任意 worktree 里跑 ./dev 即可"。所以这里和上面那条 node_modules 链接一样，
 * 属于"把机器本地状态补齐"的兜底。
 *
 * 取件顺序：同仓库的其它 worktree（版本必然一致）→ PATH 上的 xcodegen。
 * 一律**拷贝**而不是链接：14MB 一次性开销换"主 worktree 被删掉也不会突然
 * 变回 ENOENT"，而且 clam-app 的 HASHED_ROOTS 明确把 `tools/` 排除在源码 hash
 * 之外，多这个文件不会触发壳的全量重建。
 *
 * 找不到时**只警告不中止**：没装 Xcode 的机器本来就该优雅缺席，
 * 为了一个可选的壳把 dsh 拦下来是本末倒置。
 *
 * @param local - 落点全路径（link 模式在仓库里，registry 模式在 profile 的包目录里）。
 * @param repoRoot - 仓库根；undefined（registry 模式）时只问 PATH。
 */
function ensureXcodegen(local, repoRoot) {
	if (existsSync(local)) return;

	const source = findXcodegen(repoRoot);
	if (source === undefined) {
		say(`⚠ 缺 ${local}——壳构建会失败，clam-app 优雅缺席（只有浏览器，没有 App）。`);
		say(`  补法（二选一，然后重跑本命令）：`);
		say(`    brew install xcodegen`);
		say(`    从 https://github.com/yonaskolb/XcodeGen/releases 下载 xcodegen.zip，`);
		say(`      把里面的 bin/xcodegen 拷到 ${local} 并 chmod +x`);
		return;
	}

	mkdirSync(dirname(local), { recursive: true });
	copyFileSync(source, local);
	chmodSync(local, 0o755);
	say(`已补上 ${local} ← ${source}`);
}

/**
 * registry 模式下 xcodegen 该落在哪：装进 profile 的那个 clam-app 包目录里。
 *
 * **不写死包名**——伞包的 dependencies 就是编排表的成员名单，从那里找
 * 目录名为 `clam-app` 的那个。编排表里没有 clam-app（有人只要 Web 那半边）
 * 或者它没装成，就返回 undefined：没有壳的话本来就不需要 xcodegen。
 */
function installedXcodegenPath(profile, pluginNames) {
	const appPackage = pluginNames.find((name) => dirOf(name) === "clam-app");
	if (appPackage === undefined) return undefined;
	const packageDir = join(profileDir(profile), "node_modules", appPackage);
	if (!existsSync(packageDir)) return undefined;
	return join(packageDir, XCODEGEN_IN_PACKAGE);
}

/**
 * 先问同仓库的其它 worktree，再问 PATH。都没有就 undefined。
 * `repoRoot` 缺席（registry 模式）时只有 PATH 那一条路——npx 缓存里的伞包
 * 既不是 git 仓库、也没有兄弟 worktree 可抄。
 */
function findXcodegen(repoRoot) {
	if (repoRoot === undefined) return whichXcodegen();
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
 * 而 App 那边不受影响——clam-app 把实际端口写进 endpoint 文件、也用
 * `--clam-endpoint` 直接递给它拉起的壳。
 */
function start(profile, opts) {
	const args = ["--profile", profile, "--port", String(opts.port), "--no-open", ...opts.passthrough];
	say(`启动：dsh ${args.join(" ")}\n`);
	const result = spawnSync("dsh", args, { stdio: "inherit" });
	if (result.error !== undefined) fail(`启动 dsh 失败：${result.error.message}`);
	process.exit(result.status ?? 0);
}

// ---------------------------------------------------------------- 本机安装（release）

/**
 * 常驻形态的 profile 名——**钉死主 worktree 那一个**。
 *
 * 不设第二个 profile 是有意的（计划 §2.1）：会话与设置本来就是全局的
 * （`~/.dsh/sessions`、`~/.dsh/settings.yaml`，不随 profile 分片），
 * 多一个 profile 只会多一份要同步的编排表。release 与 dev 的差别改用
 * "每次运行的环境变量"表达——见 clam-app 的 `CLAM_RELEASE`。
 */
const RELEASE_PROFILE = "surfclam";

/** Release 壳的 bundle id——也是它 `NSUserDefaults` 的域名。 */
const APP_BUNDLE_ID = "io.wenbo.surfclam";

/**
 * 旧版那个 LaunchAgent 的 Label。**只用来清掉它**（`removeLegacyDaemon`），
 * 本文件不再写 plist。`.dsh` 后缀把 daemon 和 App 的 bundle id 区分开——
 * 两者是两个东西，共用一个标识迟早出事。
 */
const DAEMON_LABEL = "io.wenbo.surfclam.dsh";

/** 壳的 Application Support 根，与 clam-app 的 `APP_SUPPORT`、Swift 的 `ClamPaths.appSupport` 同一个。 */
const APP_SUPPORT = join(homedir(), "Library", "Application Support", APP_BUNDLE_ID);

/** 旧版那个 LaunchAgent plist 的落点。同上，只用来删它。 */
const DAEMON_PLIST = join(homedir(), "Library", "LaunchAgents", `${DAEMON_LABEL}.plist`);

/** 这套的 endpoint 发现文件（clam-app 按 profile 名分片写）。 */
const ENDPOINT_FILE = join(APP_SUPPORT, "endpoints", `${RELEASE_PROFILE}.json`);

/** Release 壳的安装位置，与 build.sh 的 `INSTALL_DIR` 和 clam-app 的 `INSTALLED_RELEASE` 一致。 */
const INSTALLED_APP = "/Applications/Surfclam.app";

/** Release 壳的构建 + 安装脚本（相对仓库根）。 */
const BUILD_SCRIPT_REL = "clam-app/host/scripts/build.sh";

/** `./release` 的入口：先分派四个子命令，都不是才走安装流程。 */
function release(opts, repoRoot, pluginNames) {
	if (opts.releaseCommand === "status") return releaseStatus();
	if (opts.releaseCommand === "uninstall") return releaseUninstall();
	releaseInstall(repoRoot, pluginNames);
}

/**
 * 把这台机器装成正式形态：**只装 App，不装后端**。
 *
 * 后端的生命周期归壳自己管（连接偏好默认 `managed`，见
 * `docs/clam-connection-plan.md` 的 2026-08-30 执行日志）——双击 App，它自己
 * 就会 spawn 一个 dsh、监护它、⌘Q 时收走。**所以这里不再写 LaunchAgent**：
 * 多一层 launchd 常驻，就多一整类互斥死锁（那个 daemon 与托管抢同一个 profile，
 * 会互抹 endpoint 发现文件），而壳对它只有观测权没有控制权。
 */
function releaseInstall(repoRoot, pluginNames) {
	// 1. 只许主 worktree。release 安装是"这台机器上那一套"，必须有唯一的真相源；
	//    registry 模式（npx 缓存）同样拒绝——本机安装是开发者动作，要有源码。
	if (repoRoot === undefined) {
		fail("release 安装要本地源码（link 模式）。在 surfclam 仓库里跑 ./release。");
	}
	const profile = defaultProfile(repoRoot);
	if (profile !== RELEASE_PROFILE) {
		fail(`release 安装以主 worktree 为真相源（profile ${RELEASE_PROFILE}），`
			+ `这里是 ${profile}。去主 worktree 跑 ./release。`);
	}
	say(`本机安装：${repoRoot} → profile ${RELEASE_PROFILE}`);

	// 2. 清掉旧版本装的那个常驻 daemon。**迁移逻辑，不是可选项**：它和壳自托管
	//    抢同一个 profile，留着就是互抹 endpoint 发现文件。
	removeLegacyDaemon();

	// 3. 备 profile（与 ./dev 同一套函数，同一份真相）。
	provision(RELEASE_PROFILE, repoRoot, pluginNames);

	// 4. 装壳。stdio 直通——xcodebuild 是分钟级的，进度要给人看见。
	buildRelease(repoRoot);

	// 5. 打开它。后端由壳自己拉起来，这里不等 endpoint——那是壳的事。
	if (existsSync(INSTALLED_APP)) spawnSync("open", [INSTALLED_APP], { stdio: "inherit" });

	say("");
	say(`装好了。App：${INSTALLED_APP}`);
	say(`  后端由 App 自己托管：打开即有，⌘Q 即退。`);
	say(`  常用：./release --status | --uninstall`);
	say(`  改 Swift 插件：存盘即热替换，什么都不用做。`);
	say(`  改 node 半边 / 编排表：⌘Q 再打开一次（壳会按新代码重新拉起后端）。`);
}

/**
 * 跑 `clam-app/host/scripts/build.sh`：xcodegen → xcodebuild Release →
 * 退出正在跑的 Release 实例 → ditto 进 /Applications。
 *
 * **复用而不是重写**：那个脚本里有一堆实测出来的琐碎正确性（等旧实例真的死透
 * 再删 bundle、清历次改名留下的旧安装、时间戳资源要在 generate 之前落地）。
 */
function buildRelease(repoRoot) {
	const script = join(repoRoot, BUILD_SCRIPT_REL);
	if (!existsSync(script)) fail(`找不到 ${script}`);
	say(`构建并安装 Release 壳（${BUILD_SCRIPT_REL}，首次约需分钟级）…`);
	const result = spawnSync(script, [], { cwd: repoRoot, stdio: "inherit" });
	if (result.error !== undefined) fail(`跑 ${script} 失败：${result.error.message}`);
	if (result.status !== 0) {
		fail(`壳构建失败（退出码 ${result.status}）。修好再跑一次 ./release。`);
	}
	if (!existsSync(INSTALLED_APP)) {
		fail(`build.sh 报成功，但 ${INSTALLED_APP} 不在。先查上面的输出。`);
	}
}

/**
 * 如实报告两件事：endpoint 文件、App。（外加一句旧 daemon 的残留提醒。）
 *
 * **endpoint 文件那一格必须区分"在"和"活"**：后端被 SIGTERM 时 clam-app 的清理
 * 未必来得及跑，会留下一份 pid 已死的文件。壳靠连接失败自然跳过它，不需要额外
 * 清理逻辑——但读状态的人得看得出来。
 */
function releaseStatus() {
	const legacy = daemonStatus();
	if (legacy.loaded || existsSync(DAEMON_PLIST)) {
		say(`⚠ 旧版的常驻 daemon 还有残留（${DAEMON_LABEL}`
			+ `${legacy.loaded ? `，已登记 pid=${legacy.pid ?? "?"}` : "，只剩 plist"}）。`
			+ ` 它会和 App 自托管的后端抢同一个 profile——跑一次 ./release 清掉它。`);
	}

	const endpoint = readJsonOrUndefined(ENDPOINT_FILE);
	if (endpoint === undefined) {
		say(`endpoint ${ENDPOINT_FILE}：不在`);
	} else {
		const alive = typeof endpoint.pid === "number" && isAlive(endpoint.pid);
		say(`endpoint ${ENDPOINT_FILE}：${endpoint.httpBase ?? "?"}`
			+ ` （pid ${endpoint.pid ?? "?"} ${alive ? "活着" : "已死——陈旧文件，无害"}`
			+ `, appPath ${endpoint.appPath ?? "(旧版本没有这个字段)"}）`);
	}

	say(`App ${INSTALLED_APP}：${existsSync(INSTALLED_APP)
		? (isAppRunning() ? "在，且正在运行" : "在，未运行") : "不在"}`);
	say(`后端日志（App 托管的那个）：${join(APP_SUPPORT, "logs", "managed-dsh.log")}`);
}

function releaseUninstall() {
	removeLegacyDaemon();
	try {
		rmSync(INSTALLED_APP, { recursive: true, force: true });
		say(`已删 ${INSTALLED_APP}`);
	} catch (error) {
		say(`⚠ 删不掉 ${INSTALLED_APP}：${error.message}（App 还开着？先退出它）`);
	}
	say(`profile ${RELEASE_PROFILE} 与 ~/.dsh 下的会话/设置**原样留着**——`
		+ `它们不是本命令装的，也不该由它删。`);
}

// ------------------------------------------------------------ launchctl
//
// **这一段只剩"清掉旧安装"一个用途。** 早先的 release 形态是"Release 壳进
// /Applications + 一个 LaunchAgent 常驻跑 dsh"；2026-08-30 那一层整个退役了
// ——后端归壳自托管（连接偏好默认 `managed`）。留着这几个函数是为了让装过旧版
// 的机器跑一次 `./release` 就自动迁移，而不是留一个孤儿 plist 在那儿和壳抢
// profile。**不再有任何地方写 plist。**

/**
 * 清掉旧版本装的那个常驻 daemon（如果有）。**幂等**：没装过就一句话都不说。
 *
 * 为什么非清不可：它和壳自托管的后端抢同一个 profile，而同 profile 的两个 dsh
 * 会互抹 endpoint 发现文件——那正是 2026-08-30 那次「双击 App 连不上、点开启
 * 托管什么也没发生」的一半原因（另一半见 clam-app 的发现文件守护）。
 */
function removeLegacyDaemon() {
	const status = daemonStatus();
	const hasPlist = existsSync(DAEMON_PLIST);
	if (!status.loaded && !hasPlist) return;
	if (status.loaded) {
		bootoutDaemon();
		say(`已停掉旧版的常驻 dsh（${DAEMON_LABEL}）。`);
	}
	if (hasPlist) {
		rmSync(DAEMON_PLIST, { force: true });
		say(`已删 ${DAEMON_PLIST}——后端改由 App 自己托管。`);
	}
}

/** 当前用户的 launchd 域。LaunchAgent 一律在 `gui/<uid>` 里。 */
function domain() {
	return `gui/${process.getuid()}`;
}

/**
 * daemon 此刻的状态。`launchctl print` 没登记时非零退出（stderr 写
 * "Could not find service"），登记了则吐一大块，其中 `pid` 只在真跑着时才有。
 */
function daemonStatus() {
	const result = spawnSync("launchctl", ["print", `${domain()}/${DAEMON_LABEL}`], { encoding: "utf8" });
	if (result.status !== 0) return { loaded: false, pid: undefined, state: undefined };
	const out = result.stdout ?? "";
	const pid = /^\s*pid = (\d+)$/m.exec(out)?.[1];
	return {
		loaded: true,
		pid: pid === undefined ? undefined : Number(pid),
		state: /^\s*state = (\S+)$/m.exec(out)?.[1],
	};
}

/** 卸载 daemon。没登记时 launchctl 非零退出，这里当成"本来就没有"。 */
function bootoutDaemon() {
	spawnSync("launchctl", ["bootout", `${domain()}/${DAEMON_LABEL}`], { stdio: ["ignore", "ignore", "ignore"] });
}

/** 进程还在不在。EPERM = 在（只是不归我管）。 */
function isAlive(pid) {
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		return error.code === "EPERM";
	}
}

/** 装好的那个 Release 壳在不在跑（按可执行文件路径认，不误伤 Debug 版）。 */
function isAppRunning() {
	return spawnSync("pgrep", ["-f", `${INSTALLED_APP}/Contents/MacOS/`],
		{ stdio: ["ignore", "ignore", "ignore"] }).status === 0;
}

// ---------------------------------------------------------------- 杂项

/**
 * 同步 sleep。这条路径全程是同步的（spawnSync 一串），为了几百毫秒的退避
 * 把它改成异步不值当；`Atomics.wait` 比 spawn 一个 `sleep` 干净。
 */
function sleepMs(ms) {
	Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

/** PATH 上找一个可执行文件，找不到就带补法退出。 */
function whichOrFail(command, hint) {
	const result = spawnSync("which", [command], { encoding: "utf8" });
	const path = result.stdout?.trim();
	if (result.status !== 0 || path === undefined || path === "") fail(`PATH 上找不到 ${command}——${hint}`);
	return path;
}

/** release 的两个子命令。`--release` 由仓库根的 `./release` 薄封装加在最前。 */
const RELEASE_COMMANDS = new Set(["status", "uninstall"]);

function parseArgs(argv) {
	const opts = {
		profile: undefined, port: 0, portGiven: false, installOnly: false, help: false,
		passthrough: [], release: false, releaseCommand: undefined,
	};
	for (let i = 0; i < argv.length; i += 1) {
		const a = argv[i];
		if (a === "--") { opts.passthrough = argv.slice(i + 1); break; }
		else if (a === "--profile") { opts.profile = argv[++i]; }
		else if (a === "--port") { opts.port = Number(argv[++i]); opts.portGiven = true; }
		else if (a === "--install-only") { opts.installOnly = true; }
		else if (a === "--release") { opts.release = true; }
		else if (RELEASE_COMMANDS.has(a.replace(/^--/, "")) && a.startsWith("--")) {
			if (opts.releaseCommand !== undefined) fail(`${a} 与 --${opts.releaseCommand} 只能挑一个`);
			opts.releaseCommand = a.slice(2);
		}
		else if (a === "-h" || a === "--help") { opts.help = true; }
		else fail(`无法识别的参数 ${a}（想传给 dsh 的话放在 -- 之后）`);
	}
	if (!Number.isInteger(opts.port) || opts.port < 0 || opts.port > 65535) fail("--port 要是 0..65535");
	// 子命令只在 release 路径上有意义——`./dev --stop` 该报错而不是静默无视。
	if (opts.releaseCommand !== undefined && !opts.release) {
		fail(`--${opts.releaseCommand} 是 ./release 的子命令（本机安装），不是 ./dev 的`);
	}
	// release 形态的 profile 与端口都写死在 plist 里（profile 钉 `surfclam`、
	// 端口交给 OS）。收下一个不会生效的旋钮比拒绝它更坏——那是安静的骗人。
	if (opts.release && opts.profile !== undefined) {
		fail(`./release 的 profile 钉死在 ${RELEASE_PROFILE}（本机安装只有一套），--profile 用不上`);
	}
	if (opts.release && opts.portGiven) {
		fail("./release 的端口交给 OS 挑（App 从 endpoint 发现文件读），--port 用不上");
	}
	return opts;
}

function usage() {
	process.stdout.write(`surfclam —— 安装并启动一套 surfclam（dsh + macOS 原生壳）

  npx @wenbo/surfclam             装到 profile 'surfclam' 并启动
  node surfclam/bin/surfclam.js   本仓库开发：link 本 worktree 的源码

选项
  --profile <name>   覆盖 profile 名（默认：主 worktree 用 surfclam，
                     其他 worktree 用 surfclam-<目录名>）
  --port <n>         监听端口，默认 0（让 OS 挑，多 worktree 不会撞）
  --install-only     只装不启动
  -- <args...>       其余参数透传给 dsh

本机安装（--release，仓库根的 ./release，只在主 worktree 可用）
  ./release          Release 壳装进 /Applications，之后双击就能用，
                     不必开着终端。后端由 App 自己托管：打开即有、⌘Q 即退
                     （装过旧版的机器会顺手清掉那个常驻 LaunchAgent）
  ./release --status     endpoint / App 各在什么状态
  ./release --uninstall  删 /Applications/Surfclam.app
                     （profile 与 ~/.dsh 下的会话、设置不动）
`);
}

function readJson(path) {
	try {
		return JSON.parse(readFileSync(path, "utf8"));
	} catch (error) {
		fail(`读不了 ${path}：${error.message}`);
	}
}

/** 读得到就返回，读不到 / 不成 JSON 一律当"没有"——状态查询不该因为一份坏文件而崩。 */
function readJsonOrUndefined(path) {
	try {
		return JSON.parse(readFileSync(path, "utf8"));
	} catch {
		return undefined;
	}
}

function say(message) {
	process.stderr.write(`surfclam: ${message}\n`);
}

function fail(message) {
	process.stderr.write(`surfclam: ${message}\n`);
	process.exit(1);
}

main();
