/**
 * 把分发所需的**载荷**打进 app bundle（分发计划 M1，docs/archive/distribution-plan.md §2.1）。
 *
 *   Contents/Resources/SurfNode/<pkg>/          各插件的 node 半边（package.json + lib/ + swift/）
 *   Contents/Resources/SurfPayload.json         这一次打包的清单 + 跳过判据
 *
 * （`Contents/Resources/SurfPlugins/` 不归本脚本——那是 M3 的预编译产物，
 * 由 `prebuild-plugins.mjs` 写，本脚本一个字节都不碰。）
 *
 * 四条不变量：
 *
 * 1. **装哪些包以 `surf/cordis.patch.yml` 为准**（编排表是唯一真相）。
 *    注释掉的行不算——停用的插件不该进 bundle。
 * 2. **`SurfNode/` 的目录结构与仓库根一一对应**：surf-* 之间用相对路径 import
 *    （`../../surf-bridge/lib/plugin.js`），兄弟关系一破那些 import 全部落空。
 *    **`surf-app/host/` 不进包**——那是壳自己的源码，进 bundle 就是自我嵌套。
 * 3. **`swift/` 也进 `SurfNode/<pkg>/`，与 `lib/` 平级**（M3，分发计划 §3.2a）。
 *    各插件的 node 半边写着 `swiftDir: new URL("../swift/", import.meta.url)`，
 *    只要保持这层兄弟关系，那条相对路径在镜像里天然成立——node 半边不需要知道
 *    App bundle 在哪（它本来也不知道）。**源码在 bundle 里只有这一份**：
 *    预编译流水线也读它，"编的就是发的"因此是结构性的，不是巧合。
 * 4. **module 名不自己算**，用 `surf-bridge/lib/module-name.js`。桥登记时算出来的
 *    module 名与预编译产物的目录名必须逐字一致，否则壳按 module 名去 bundle 里找
 *    预编译产物永远落空，而且是静默落空（退回现场编译，用户机器上未必有 swiftc）。
 *
 * 版本对齐（§3.4）：打进 bundle 的 `package.json` 里 `version` 一律改写成 Xcode 的
 * `MARKETING_VERSION`。**只改 bundle 里那份拷贝**，仓库里的源文件一个字节都不动。
 *
 * 跳过判据（学 `build-modules.sh` 的教训：判据里必须含**真正的输入**，
 * 不只是源码内容）：hash 折进了①每一个将要写入的文件的**目标相对路径 + 变换后的
 * 内容**（版本改写因此天然进 hash）、②本脚本与 `pack-payload.sh` 自身的内容、
 * ③包与 module 清单。任一项变了都会重打。
 *
 * @module surf-app/host/scripts/pack-payload
 */
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync }
	from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { moduleName } from "../../../surf-bridge/lib/module-name.js";
import { STATIC_MARKER } from "../../../surf-bridge/lib/swift-payload.js";

const SCRIPTS_DIR = dirname(fileURLToPath(import.meta.url));
/** 仓库根：<repo>/surf-app/host/scripts → <repo>。 */
const REPO = resolve(SCRIPTS_DIR, "../../..");

const env = (key) => {
	const value = process.env[key];
	if (value === undefined || value === "") {
		fail(`缺环境变量 ${key}（本脚本只供 Xcode 的 build phase 调用）`);
	}
	return value;
};

function fail(message) {
	process.stderr.write(`pack-payload: error: ${message}\n`);
	process.exit(1);
}

const version = env("MARKETING_VERSION");
const contents = join(env("BUILT_PRODUCTS_DIR"), env("CONTENTS_FOLDER_PATH"));
const resources = join(contents, "Resources");
if (!existsSync(contents)) fail(`bundle 不在：${contents}`);

// ------------------------------------------------------------ 编排表

/**
 * 编排表里在册的插件包名。
 *
 * 只认**没被注释掉**的 `name: "@wenbo/…"` 行：`^\s*name:` 要求 `name:` 紧跟缩进，
 * 而注释行是 `#   name: …`（`#` 抢在前面），天然滤掉。
 */
function orchestratedPackages() {
	const table = join(REPO, "surf", "cordis.patch.yml");
	const text = readFileSync(table, "utf8");
	const names = [];
	for (const line of text.split("\n")) {
		const match = /^\s*name:\s*["']?@wenbo\/([A-Za-z0-9._-]+)["']?\s*$/.exec(line);
		if (match !== null && !names.includes(match[1])) names.push(match[1]);
	}
	if (names.length === 0) fail(`编排表里一个 @wenbo/* 插件都没解析出来：${table}`);
	return names;
}

// 包目录名 = 包名去掉 scope，也就是 `createSwiftPlugin({ name })` 里那个名字
// （全部五个 Swift 插件都逐字如此，2026-08-30 核对）。伞包自己不在表里列自己，
// 但它是 profile 解析 bundle 的锚（`resolveBundleDir` 只认 node 解析得到的真包），
// 所以补在最后。
const packages = [...orchestratedPackages(), "surf"];

// ------------------------------------------------------------ 收集要写的文件

/** 目标相对路径（相对 Resources/）→ Buffer。确定序：最后统一排序。 */
const payload = new Map();

function walk(dir) {
	const out = [];
	let entries;
	try {
		entries = readdirSync(dir, { withFileTypes: true });
	} catch {
		return out;
	}
	for (const entry of entries.sort((a, b) => (a.name < b.name ? -1 : 1))) {
		if (entry.name === ".DS_Store") continue;
		const path = join(dir, entry.name);
		if (entry.isDirectory()) out.push(...walk(path));
		else if (entry.isFile()) out.push(path);
	}
	return out;
}

/**
 * 打进 bundle 的 `package.json` 要改两处：`version` 对齐（§3.4），`bin` 删掉。
 *
 * **默认走就地文本改写**，其余字节一字不动——各包缩进风格不一，re-stringify 会
 * 把整份文件重排，diff 里全是噪音。只有真的带 `bin` 的包（眼下只有伞包
 * `@wenbo/surf`）才退回 parse→stringify，缩进从原文现测。
 *
 * **为什么必须删 `bin`**：那是开发者的安装器入口（`bin/surf.js`），
 * 不随分发走，所以载荷里没有 `bin/`。留着这个字段而文件不在，pnpm 会去建一条
 * 指向不存在文件的 `.bin` 垫片——2026-08-30 实测（pnpm 11.22.0）**不阻断、只 WARN**：
 *
 *     WARN Failed to create bin at …/node_modules/.bin/surf.
 *          ENOENT: no such file or directory, chmod '…/@wenbo/surf/bin/surf.js'
 *
 * 代价是每次 pnpm 跑都刷这一行（用户会以为装坏了），外加一条断掉的
 * `.bin/surf` 符号链接常驻。自举本身不调 pnpm（计划 §7.2），
 * 所以这只在用户跑 `dsh plugin add` 时才发作——但那正是最不该出现噪音的时刻。
 */
function rewriteManifest(text, pkg) {
	let next = text.replace(/^(\s*"version"\s*:\s*)"[^"]*"/m, `$1"${version}"`);
	let parsed;
	try {
		parsed = JSON.parse(next);
	} catch (error) {
		fail(`${pkg}/package.json 改写版本后不是合法 JSON：${error.message}`);
	}
	if (parsed.version !== version) {
		fail(`${pkg}/package.json 的 version 没能对齐到 ${version}（得到 ${parsed.version}）`);
	}
	if (parsed.bin !== undefined) {
		delete parsed.bin;
		// 原文第一个缩进过的键，就是这份文件的缩进风格。
		const indent = /\n(\t+| +)"/.exec(text)?.[1] ?? "\t";
		next = `${JSON.stringify(parsed, null, indent)}\n`;
	}
	return next;
}

const modules = [];

for (const pkg of packages) {
	const dir = join(REPO, pkg);
	const manifest = join(dir, "package.json");
	if (!existsSync(manifest)) fail(`编排表点名了 ${pkg}，但 ${manifest} 不在`);

	payload.set(join("SurfNode", pkg, "package.json"),
		Buffer.from(rewriteManifest(readFileSync(manifest, "utf8"), pkg), "utf8"));

	// 只收 lib/ 与 swift/：test/ README.md tools/ node_modules/ 一律不收，
	// **surf-app/host/ 尤其不收**。
	for (const file of walk(join(dir, "lib"))) {
		payload.set(join("SurfNode", pkg, "lib", relative(join(dir, "lib"), file)),
			readFileSync(file));
	}

	// 伞包没有 lib/，它的载荷就是那张编排表（package.json 的 dsh.bundle.patch 指着它）。
	const patch = join(dir, "cordis.patch.yml");
	if (existsSync(patch)) {
		payload.set(join("SurfNode", pkg, "cordis.patch.yml"), readFileSync(patch));
	}

	// Swift 载荷：有 swift/ 且里面有 .swift 才算（判据与桥的 register() 一致）。
	// 落点是 `SurfNode/<pkg>/swift/`——与 `lib/` 平级，因为 node 半边的
	// `new URL("../swift/", import.meta.url)` 就是这么算的（不变量 3）。
	const swiftDir = join(dir, "swift");
	const swiftFiles = statSync(swiftDir, { throwIfNoEntry: false })?.isDirectory() === true
		? walk(swiftDir)
		: [];
	if (swiftFiles.some((file) => file.endsWith(".swift"))) {
		const module = moduleName(pkg);
		modules.push({ module, plugin: pkg, files: swiftFiles.length });
		for (const file of swiftFiles) {
			payload.set(join("SurfNode", pkg, "swift", relative(swiftDir, file)),
				readFileSync(file));
		}
		// 「这份源码是分发载荷，不会变」的标记：桥据此关掉 500ms 轮询
		// （分发计划 §7.10；判据的定义在 surf-bridge/lib/swift-payload.js）。
		// 它不是 `.swift`，所以既不进桥的扫描结果也不进任何 contentHash。
		payload.set(join("SurfNode", pkg, "swift", STATIC_MARKER), Buffer.from(
			"随 Surf.app 分发的 Swift 载荷。App 自举时整份重拷，dsh 跑起来之后不会变。\n"
			+ "surf-bridge 见到这个文件就不轮询这个目录（surf-bridge/lib/swift-payload.js）。\n",
			"utf8"));
	}
}

if (payload.size === 0) fail("没有任何载荷可打包");

// ------------------------------------------------------------ 跳过判据

const digest = createHash("sha256");
for (const path of [...payload.keys()].sort()) {
	digest.update(path);
	digest.update("\0");
	digest.update(payload.get(path));
	digest.update("\0");
}
// 本脚本自身也是输入：改了打包逻辑而源码没变时，增量构建的 bundle 里躺着的
// 还是上一轮的产物——build-modules.sh 那条教训（判据里要含真正的输入）。
for (const self of ["pack-payload.mjs", "pack-payload.sh"]) {
	digest.update(readFileSync(join(SCRIPTS_DIR, self)));
	digest.update("\0");
}
digest.update(JSON.stringify({ version, packages, modules }));
const hash = digest.digest("hex");

const stampPath = join(resources, "SurfPayload.json");
const nodeRoot = join(resources, "SurfNode");

if (existsSync(stampPath) && existsSync(nodeRoot)) {
	try {
		if (JSON.parse(readFileSync(stampPath, "utf8")).hash === hash) {
			process.stdout.write(`pack-payload: 未变动，跳过（${hash.slice(0, 12)}）\n`);
			process.exit(0);
		}
	} catch {
		// 清单读不动就当没有，重打一次。
	}
}

// ------------------------------------------------------------ 写盘

// 整体重建而不是增量覆盖：上一轮打进去、这一轮不再在册的包（编排表里被注释掉或
// 整个删掉的那些）必须消失，否则 bundle 里会留一份没人加载的陈尸。
// **`SurfPlugins/` 不归这里**：它是 prebuild-plugins.mjs 的地盘，那边自己收拾。
rmSync(nodeRoot, { recursive: true, force: true });
rmSync(stampPath, { force: true });

for (const path of [...payload.keys()].sort()) {
	const dest = join(resources, path);
	mkdirSync(dirname(dest), { recursive: true });
	writeFileSync(dest, payload.get(path));
}

writeFileSync(stampPath, `${JSON.stringify({
	version,
	hash,
	packedAt: new Date().toISOString(),
	packages,
	modules,
}, undefined, 2)}\n`);

const bytes = [...payload.values()].reduce((sum, buffer) => sum + buffer.length, 0);
process.stdout.write(`pack-payload: ${packages.length} 个包 / ${modules.length} 个 Swift module`
	+ ` / ${payload.size} 个文件 / ${(bytes / 1024).toFixed(0)} KB`
	+ ` → v${version}（${hash.slice(0, 12)}）\n`);
