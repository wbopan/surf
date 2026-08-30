/**
 * 插件名 → Swift module 名。**这个映射的唯一真相。**
 *
 * 单独成模块，只为一件事：`clam-app/host/scripts/pack-payload.mjs` 也要用它
 * （把各插件的 `swift/` 打进 app bundle 的 `Resources/ClamPlugins/<Module>/sources/`，
 * 目录名必须与桥登记时算出来的 module 名逐字一致，否则壳按 module 名去 bundle 里
 * 找预编译产物就永远落空——而且是**静默**落空，退回现场编译，用户机器上可能根本
 * 没有 swiftc）。抄成两份的话，抄错了不报错。
 *
 * **零依赖**（连 node 内置都不用）：`lib/index.js` 里 `import` 了
 * `@deepseek-ai/schemastery` 与 `ws`，构建脚本跑在 Xcode 的 build phase 里、
 * 未必解析得到它们。
 *
 * @module clam-bridge/module-name
 */

/** `clam-sidebar` → `ClamSidebar`。结果必须是一个合法的 Swift 标识符。 */
export function moduleName(plugin) {
	return plugin.split(/[-_]/).filter(Boolean)
		.map((part) => part[0].toUpperCase() + part.slice(1))
		.join("");
}

export default moduleName;
