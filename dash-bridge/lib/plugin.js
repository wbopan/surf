/**
 * `createSwiftPlugin` —— 带 Swift 载荷的插件的 node 半边工厂（计划 §4.2）。
 *
 * 它住在 dash-bridge 里而不是自成一包：工厂做的事本就是与桥的登记表 API 对话，
 * 契约两端（服务实现与客户端工厂）同住一包，永不漂移。
 *
 * 八成插件的 node 半边就是一段配置：
 *
 * ```js
 * import { createSwiftPlugin } from "../../dash-bridge/lib/plugin.js";
 *
 * export default createSwiftPlugin({
 *   name: "dash-sidebar",
 *   provide: "dash-sidebar",              // 空标记服务，供下游 inject（§4.3）
 *   inject: ["dash-layout"],              // cordis 依赖 = 挂载时序
 *   swiftDir: new URL("../swift/", import.meta.url),
 *   swiftDeps: ["dash-layout"],           // Swift module 依赖（import DashLayout）
 *   subscribe: ({ ctx, push }) => { ... },
 *   expose: { archive: (payload, { ctx }) => { ... } },
 * });
 * ```
 *
 * **解析方式**：dash-* 之间用相对路径 import。`healProfilesModuleFallback` 只把
 * harness 的依赖闭包镜像进 `~/.dsh/profiles/node_modules/`，不含用户插件，
 * 所以包名 import 需要额外布线（npm workspace 或手工 symlink）——两者都是
 * 机器本地状态，新克隆的仓库拿不到。相对路径在"所有 dash-* 是同一仓库里的兄弟
 * 目录"这个前提下永远成立，零配置。
 *
 * @module dash-bridge/plugin
 */
import { fileURLToPath } from "node:url";

/**
 * @param {object} options
 * @param {string} options.name 插件名，同时决定 Swift module 名（dash-sidebar → DashSidebar）。
 * @param {string} [options.provide] 要 provide 的空标记服务名（让别的插件能 inject 自己）。
 * @param {string[]} [options.inject] 额外的 cordis 依赖（`dashBridge` 会自动加上）。
 * @param {URL|string} options.swiftDir Swift 载荷目录。
 * @param {string[]} [options.swiftDeps] Swift module 依赖（必须同时出现在 inject 里）。
 * @param {number} [options.schemaVersion] 本插件与 Swift 半身之间数据形状的版本。
 * @param {object} [options.Config] schemastery 配置模式。
 * @param {(api: {ctx: object, config: object, push: (channel: string, payload: object) => void}) => void} [options.subscribe]
 *        登记完成后调用一次：在这里 `ctx.on(...)` 订宿主事件并 `push` 给 Swift 半身。
 * @param {Record<string, (payload: object, api: object) => unknown>} [options.expose]
 *        Swift 半身可经 `bridge.send(action:)` 触发的动作。
 */
export function createSwiftPlugin(options) {
	const {
		name,
		provide,
		inject = [],
		swiftDir,
		swiftDeps = [],
		schemaVersion = 1,
		Config,
		subscribe,
		expose = {},
	} = options;

	const dir = swiftDir instanceof URL ? fileURLToPath(swiftDir) : String(swiftDir);

	// swiftDeps ⊆ inject：Swift 编译拓扑序与 cordis 挂载时序必须是同一份声明
	// （计划 §4.2），否则会出现"上游还没登记、下游已经在等编译"的时序洞。
	const missing = swiftDeps.filter((dep) => !inject.includes(dep));
	const injects = ["dashBridge", ...inject, ...missing];

	return {
		name,
		inject: injects,
		Config,
		apply(ctx, config) {
			if (missing.length > 0) {
				ctx.logger(name).warn(
					`swiftDeps ${missing.join(", ")} 未出现在 inject 中，已自动补上。`);
			}

			// 空标记服务：让下游能 inject 自己，从而拿到 cordis 保证的挂载时序
			// ——layout 没挂好 sidebar 就不挂载，layout 换代时 sidebar 级联重载。
			if (provide !== undefined) ctx.provide(provide, {});

			const api = {
				ctx,
				config,
				push: (channel, payload) => handle.push(channel, payload ?? {}),
			};

			const handle = ctx.dashBridge.register({
				plugin: name,
				swiftDir: dir,
				swiftDeps,
				schemaVersion,
				expose: Object.fromEntries(Object.entries(expose)
					.map(([action, fn]) => [action, (payload) => fn(payload, api)])),
			});

			ctx.effect(() => () => handle.dispose(), `${name} Swift 载荷登记`);

			subscribe?.(api);
		},
	};
}

export default createSwiftPlugin;
