/**
 * clam-layout —— 窗口布局（计划 §7.1）。
 *
 * node 半边只做三件事：把 `swift/` 登记给桥、声明本插件的菜单命令，以及 provide 一个空标记服务
 * `clam-layout` 让 clam-sidebar 能 inject 它（§4.3）——Cordis 的依赖解析由此保证
 * "layout 未挂好 sidebar 不挂载、layout 换代时 sidebar 级联重载"，
 * 而这正是 Swift 侧的编译拓扑序与 activate 顺序。
 *
 * 布局本身全在 Swift 半身。这里没有逻辑，也不该有。
 *
 * @module clam-layout
 */
import { createSwiftPlugin } from "../../clam-bridge/lib/plugin.js";

export default createSwiftPlugin({
	name: "clam-layout",
	provide: "clam-layout",
	swiftDir: new URL("../swift/", import.meta.url),

	// 本插件想让壳装进菜单的命令（形状见 clam-bridge/lib/plugin.js 的
	// CommandDeclaration）。**能力在谁家命令就归谁声明**：这三条的执行端全在
	// 本插件——前两条是 Swift 半边的会话展示面（LayoutPlugin 订 menuCommand），
	// 第三条在 client 半边（页面自己匹配 keydown）。
	commands: [
		{
			// ⌘,。clam-settings 也声明同一条（它在场时开原生窗口），两家谁在
			// 都有这一项；壳按 id 去重，先登记的赢，两边的文案与默认键因此必须一致。
			id: "openSettings",
			menu: "app",
			order: 10,
			label: { zh: "设置…", en: "Settings…" },
			key: "cmd+,",
			description: { zh: "打开设置窗口。", en: "Open the settings window." },
		},
		{
			id: "newSession",
			menu: "file",
			order: 10,
			label: { zh: "新建会话", en: "New Session" },
			key: "cmd+n",
			description: { zh: "新建会话。", en: "Start a new session." },
		},
		{
			// **没有 menu**：执行在 client 半边（lib/client.js 的 escStop）——原生菜单项
			// 拦不住 WebView 里的输入焦点，所以这个键从来就不是菜单项。壳只把它列进
			// ⌘/ 面板的「页面内」一节，键位仍从同一份设置里取。
			id: "stopGenerating",
			label: { zh: "停止生成", en: "Stop Generating" },
			key: "esc",
			description: {
				zh: "停止当前会话正在生成的回复（在网页内匹配，不是菜单项）。留空 = 关掉这个键。",
				en: "Stop the reply the current session is generating. Matched inside the web page "
					+ "rather than by a menu item; leave empty to turn the key off.",
			},
		},
	],
});
