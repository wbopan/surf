/**
 * dash-sidebar —— 原生会话侧边栏（计划 §7.2）。
 *
 * node 半边只登记 Swift 载荷。`inject`/`swiftDeps` 里的 `dash-layout` 一份声明
 * 两层消费：Cordis 据此保证"layout 未挂好本插件不挂载、layout 换代时本插件级联重载"，
 * 桥据此排编译拓扑序（Swift 侧 `import DashLayout` 拿 `DashConversationSurface`）。
 *
 * **数据面暂时不在这里**：会话列表由 Swift 半身经 DSHKit 的 `SessionStore` 直接镜像
 * dsh 的 HTTP/WS API（计划 §7.2 的 M6 方案）。搬进 TS 半身是 M10 的事，
 * 收益是架构一致与 iOS 远程线地基，代价是要赌 dsh 内部服务的 preview 稳定性。
 *
 * @module dash-sidebar
 */
import { createSwiftPlugin } from "../../dash-bridge/lib/plugin.js";

export default createSwiftPlugin({
	name: "dash-sidebar",
	provide: "dash-sidebar",
	inject: ["dash-layout"],
	swiftDir: new URL("../swift/", import.meta.url),
	swiftDeps: ["dash-layout"],
	// Swift 侧 `import DSHKit`（SessionStore / DSHTransport）。本仓库里唯一的
	// DSHKit 消费者——声明出来，别的插件才不会因为 DSHKit 变动而白白全量重编。
	sharedModules: ["DSHKit"],
});
