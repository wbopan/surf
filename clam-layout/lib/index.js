/**
 * clam-layout —— 窗口布局（计划 §7.1）。
 *
 * node 半边只做两件事：把 `swift/` 登记给桥，以及 provide 一个空标记服务
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
});
