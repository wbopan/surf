/**
 * 构建期把各插件的 Swift 半边**真的编一遍**，产物随 bundle 分发
 * （分发计划 M3，docs/distribution-plan.md §3.2）。
 *
 *   Contents/Resources/ClamPlugins/<Module>/prebuilt/<hash12>/lib<Module>_h<hash12>.dylib
 *   Contents/Resources/ClamPrebuilt.json                      清单（给人看的）
 *
 * **正式用户不该需要任何 Swift 工具链。** 内容寻址缓存的机制本来就在，只要
 * bundle 里那份 dylib 的 contentHash 与壳在用户机器上算出来的一致，壳就直接
 * dlopen，一次 swiftc 都不跑。所以整件事的成败只有一条：**两边算出的 hash
 * 必须逐字相同**。为此这里一处都不重算：
 *
 * - **桥那半边的 hash**（源码 + 依赖 + 共享 module 声明）→ 调
 *   `clam-bridge/lib/swift-payload.js` 的 `swiftContentHash`，与桥同一份代码；
 * - **壳那半边的 hash**（工具链基线 + ClamSDK 接口摘要）与全部 swiftc 参数 →
 *   交给 `scripts/prebuild/` 那个工具，它把壳的 `Native/CompilerService.swift`
 *   原样编进去；
 * - **`swiftDeps` / `sharedModules` / `schemaVersion`** → `import` 各插件的
 *   node 半边，读 `createSwiftPlugin` 挂上去的 `clamSwift`。**静态解析源码是不行的**：
 *   猜错了不报错，只是 hash 对不上、预编译永远命中不了，静默退回现场编译。
 * - **源码** → 读**打包进 bundle 的那一份**（`Resources/ClamNode/<pkg>/swift/`），
 *   不读仓库。"编的就是发的"因此是结构性的，不靠"这两份应该一样"这种默契。
 *
 * `import` 插件模块需要 `@deepseek-ai/*` 解析得到（clam-notify / clam-nativeify
 * 顶层 import 了 schemastery）。仓库根那条 `node_modules` 符号链接由 `./dev` 补，
 * 缺了就 fails loud 并给出补法——**不优雅缺席**：Release 包缺了预编译产物是个
 * 坏包，装到用户机器上表现为"插件全部缺席"，而 dsh 照常起、没人会去看构建日志。
 *
 * 用法：`node prebuild-plugins.mjs <预编译工具的路径>`（由 prebuild-plugins.sh 调）。
 *
 * @module clam-app/host/scripts/prebuild-plugins
 */
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";

import { scanSwiftDir, swiftContentHash } from "../../../clam-bridge/lib/swift-payload.js";

const SCRIPTS_DIR = dirname(fileURLToPath(import.meta.url));
/** 仓库根：<repo>/clam-app/host/scripts → <repo>。 */
const REPO = resolve(SCRIPTS_DIR, "../../..");

function fail(message, hint) {
	process.stderr.write(`prebuild-plugins: error: ${message}\n`);
	if (hint !== undefined) process.stderr.write(`  ${hint}\n`);
	process.exit(1);
}

const env = (key) => {
	const value = process.env[key];
	if (value === undefined || value === "") {
		fail(`缺环境变量 ${key}（本脚本只供 Xcode 的 build phase 调用）`);
	}
	return value;
};

const tool = process.argv[2];
if (tool === undefined || !existsSync(tool)) fail(`预编译工具不在：${tool}`);

const version = env("MARKETING_VERSION");
const contents = join(env("BUILT_PRODUCTS_DIR"), env("CONTENTS_FOLDER_PATH"));
const resources = join(contents, "Resources");
const payloadPath = join(resources, "ClamPayload.json");
if (!existsSync(payloadPath)) {
	fail(`没有 ${payloadPath}`, "pack-payload 应当排在本步骤之前（见 project.yml）。");
}
const payload = JSON.parse(readFileSync(payloadPath, "utf8"));

// ------------------------------------------------------------ 各插件的声明

/** 插件名 → {module, files, swiftDeps, sharedModules, schemaVersion}。 */
const records = new Map();

for (const { module, plugin } of payload.modules ?? []) {
	const entry = join(REPO, plugin, "lib", "index.js");
	let mod;
	try {
		mod = await import(pathToFileURL(entry).href);
	} catch (error) {
		fail(`import ${entry} 失败：${error.message}`,
			"插件的 node 半边顶层 import 了 @deepseek-ai/*；在仓库根跑一次 ./dev "
			+ "会补上解析它们的 node_modules 符号链接。");
	}
	const declared = mod.default?.clamSwift;
	if (declared === undefined) {
		fail(`${plugin} 的默认导出上没有 clamSwift`,
			"它应当由 clam-bridge/lib/plugin.js 的 createSwiftPlugin 挂上——"
			+ "这个插件是不是没走那个工厂？");
	}
	if (declared.name !== plugin) {
		fail(`${plugin} 声明的 name 是 ${JSON.stringify(declared.name)}`,
			"包目录名与 createSwiftPlugin({ name }) 必须一致，module 名由后者推出。");
	}
	// **读打包进 bundle 的那一份源码**，不读仓库（见顶注）。
	const swiftDir = join(resources, "ClamNode", plugin, "swift");
	const { files } = scanSwiftDir(swiftDir);
	if (Object.keys(files).length === 0) fail(`${swiftDir} 里一个 .swift 都没有`);
	records.set(plugin, {
		module,
		files,
		swiftDeps: declared.swiftDeps,
		sharedModules: declared.sharedModules,
		schemaVersion: declared.schemaVersion,
	});
}

if (records.size === 0) fail("ClamPayload.json 里一个 Swift module 都没有");

// ------------------------------------------------------------ 拓扑序 + contentHash

/** 依赖在前。与桥的 `topological()` 同款（环就地报，不静默）。 */
function topological() {
	const out = [];
	const state = new Map();
	const visit = (name) => {
		if (!records.has(name)) fail(`插件 ${name} 声明了依赖它的人，但它自己不在打包清单里`);
		const mark = state.get(name);
		if (mark === "done") return;
		if (mark === "visiting") fail(`Swift 依赖成环，涉及 ${name}`);
		state.set(name, "visiting");
		for (const dep of records.get(name).swiftDeps) visit(dep);
		state.set(name, "done");
		out.push(name);
	};
	for (const name of records.keys()) visit(name);
	return out;
}

const order = topological();
const hashes = new Map();
const plugins = order.map((name) => {
	const record = records.get(name);
	const bridgeHash = swiftContentHash(record, (dep) => hashes.get(dep));
	hashes.set(name, bridgeHash);
	return {
		name,
		module: record.module,
		files: record.files,
		deps: record.swiftDeps,
		sharedModules: record.sharedModules,
		bridgeHash,
		schemaVersion: record.schemaVersion,
	};
});

// ------------------------------------------------------------ 交给编译工具

const spec = {
	version,
	modulesDir: join(resources, "ClamModules"),
	frameworksDir: join(contents, "Frameworks"),
	outputRoot: join(resources, "ClamPlugins"),
	manifestPath: join(resources, "ClamPrebuilt.json"),
	plugins,
};
const specPath = join(mkdtempSync(join(tmpdir(), "clam-prebuild-")), "spec.json");
writeFileSync(specPath, JSON.stringify(spec));

const result = spawnSync(tool, [specPath], { stdio: "inherit" });
if (result.error !== undefined && result.error !== null) {
	fail(`跑不起预编译工具：${result.error.message}`);
}
if (result.status !== 0) process.exit(result.status ?? 1);
