/**
 * `createSwiftPlugin` —— 带 Swift 载荷的插件的 node 半边工厂（计划 §4.2）。
 *
 * 它住在 clam-bridge 里而不是自成一包：工厂做的事本就是与桥的登记表 API 对话，
 * 契约两端（服务实现与客户端工厂）同住一包，永不漂移。
 *
 * 八成插件的 node 半边就是一段配置：
 *
 * ```js
 * import { createSwiftPlugin } from "../../clam-bridge/lib/plugin.js";
 *
 * export default createSwiftPlugin({
 *   name: "clam-sidebar",
 *   provide: "clam-sidebar",              // 空标记服务，供下游 inject（§4.3）
 *   inject: ["clam-layout"],              // cordis 依赖 = 挂载时序
 *   swiftDir: new URL("../swift/", import.meta.url),
 *   swiftDeps: ["clam-layout"],           // Swift module 依赖（import ClamLayout）
 *   sharedModules: [],                    // 随 bundle 分发的共享 module（ClamSDK 无需声明）
 *   subscribe: ({ ctx, push }) => { ... },
 *   expose: { archive: (payload, { ctx }) => { ... } },
 * });
 * ```
 *
 * **解析方式**：clam-* 之间用相对路径 import。`healProfilesModuleFallback` 只把
 * harness 的依赖闭包镜像进 `~/.dsh/profiles/node_modules/`，不含用户插件，
 * 所以包名 import 需要额外布线（npm workspace 或手工 symlink）——两者都是
 * 机器本地状态，新克隆的仓库拿不到。相对路径在"所有 clam-* 是同一仓库里的兄弟
 * 目录"这个前提下永远成立，零配置。
 *
 * @module clam-bridge/plugin
 */
import { fileURLToPath } from "node:url";

/**
 * 一条命令声明（`createSwiftPlugin({ commands: [...] })` 里的一项）。
 *
 * **这张表是"壳该在菜单里摆什么"的唯一真相。** 从前它在壳里硬编码了四份
 * （菜单结构、默认键位、双语文案、设置 schema），四份必须逐字一致而没有任何校验
 * ——分家了不报错，症状是"设置界面写着 ⌘N、按下去却不是"，或者"改了文案菜单没变"。
 * 现在声明的一方只有插件自己，壳与 clam-app 都是读者。
 *
 * 消费方两个，各取所需：
 *
 * - 壳（经桥 snapshot 的 `commands` 字段）：建菜单项、装默认键位、⌘/ 面板；
 *   按下去只 `emit(menuCommand, {command: id, …})`，本插件的 Swift 半边接。
 * - clam-app：把 `configurable` 的那些拼成 `clam-shortcuts` 设置 ns 的 schema。
 *
 * **壳不认得任何一个 id**，所以插件缺席时那些菜单项干脆不出现（而不是灰着或报错）。
 *
 * @typedef {object} CommandDeclaration
 * @property {string} id 命令名 = `menuCommand` 载荷里的 `command`，同时是设置项的键名。
 *        全局唯一：两家声明同一个 id 时先登记的那家赢（`openSettings` 就是 layout 与
 *        settings 各声明一次，谁在场都能用）。
 * @property {string} [menu] 落在哪个菜单：`app` / `file` / `edit` / `view` / `window` /
 *        `help` 是壳自带的系统菜单，其余 id 会造一个新的顶级菜单（标题取首个声明者的
 *        `menuLabel`）。**省略 = 不进菜单**——执行在页面里的键（Esc 停止生成）就是这样，
 *        壳不装菜单项，只在 ⌘/ 面板的「页面内」一节列出来。
 * @property {{zh: string, en: string}} [menuLabel] 自定义菜单的标题。
 * @property {number} [menuOrder] 自定义菜单在菜单栏里的位置（越小越靠左，都夹在
 *        「显示」与「窗口」之间）。
 * @property {{zh: string, en: string}} label 菜单项文案。digits 形态里可用 `{n}` 占位。
 * @property {number} [order] 同一个菜单内的排序（越小越靠上）。
 * @property {boolean} [separatorBefore] 本项之前插一条分隔线（菜单当时为空则不插）。
 * @property {string} [key] 默认键位，语法见壳的 `KeymapSpec`（`cmd+shift+]`、`cmd+alt+a`、
 *        `esc`；空串 = 不挂键）。**省略 = 没有默认键**。
 * @property {string[]} [keyChoices] 键位只允许这几个值（设置页画成下拉而不是文本框）。
 * @property {boolean} [configurable] 进不进 `clam-shortcuts` 设置页。默认 true；
 *        系统惯例那些键（⌘W/⌘Q/⌘R/⌘/…）根本不该走这张表，所以这里没有对应的概念。
 * @property {{zh: string, en: string}} [description] 设置页上的说明；省略则用 `label`。
 * @property {boolean} [hidden] 菜单项藏起来但快捷键照常生效（⌘1-9 那九项）。
 * @property {{count: number, command: string, argKey: string}} [digits] **一族**命令：
 *        一个设置键装 `count` 个数字键菜单项，第 N 项 emit `command` 并带
 *        `{[argKey]: N}`。这时 `key` 只写修饰键（`cmd` / `cmd+alt` / `off`）。
 *        逐条声明九个键既啰嗦又留下"第 3 个和第 7 个撞车"这类无人校验的坑。
 */

/**
 * @param {object} options
 * @param {string} options.name 插件名，同时决定 Swift module 名（clam-sidebar → ClamSidebar）。
 * @param {string} [options.provide] 要 provide 的空标记服务名（让别的插件能 inject 自己）。
 * @param {string[]} [options.inject] 额外的 cordis 依赖（`clamBridge` 会自动加上）。
 * @param {URL|string} options.swiftDir Swift 载荷目录。
 * @param {string[]} [options.swiftDeps] Swift module 依赖（必须同时出现在 inject 里）。
 * @param {string[]} [options.sharedModules] 用到的共享 module（随 app bundle 分发的那些；
 *        DSHKit 退役后暂无住户，机制保留）。**`ClamSDK` 不用写**——它是壳↔插件的 ABI，无条件链接。
 *        没声明的 module 既不 `-l` 也不进本插件的内容 hash，所以它变动时本插件不会
 *        白白全量重编；反过来，声明了就意味着"它变了我必须重编"。
 * @param {number} [options.schemaVersion] 本插件与 Swift 半身之间数据形状的版本。
 * @param {CommandDeclaration[]} [options.commands] 本插件想让壳装进菜单/快捷键的命令。
 *        **声明在这里是一处真相**：壳建菜单、拼默认键位、画 ⌘/ 面板，clam-app 拼
 *        `clam-shortcuts` 设置 schema，全读同一份（形状见下面的 typedef）。
 *        Swift 半边照旧订 `ClamEventBus.Topic.menuCommand` 应答，一行都不用改。
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
		sharedModules = [],
		schemaVersion = 1,
		commands = [],
		Config,
		subscribe,
		expose = {},
	} = options;

	const dir = swiftDir instanceof URL ? fileURLToPath(swiftDir) : String(swiftDir);

	// swiftDeps ⊆ inject：Swift 编译拓扑序与 cordis 挂载时序必须是同一份声明
	// （计划 §4.2），否则会出现"上游还没登记、下游已经在等编译"的时序洞。
	const missing = swiftDeps.filter((dep) => !inject.includes(dep));
	const injects = ["clamBridge", ...inject, ...missing];

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

			const handle = ctx.clamBridge.register({
				plugin: name,
				swiftDir: dir,
				swiftDeps,
				sharedModules,
				schemaVersion,
				commands,
				expose: Object.fromEntries(Object.entries(expose)
					.map(([action, fn]) => [action, (payload) => fn(payload, api)])),
			});

			ctx.effect(() => () => handle.dispose(), `${name} Swift 载荷登记`);

			subscribe?.(api);
		},
	};
}

export default createSwiftPlugin;
