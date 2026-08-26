/**
 * dash-settings —— 原生设置窗口（计划 docs/dash-settings-plan.md）。
 *
 * M0 的 node 半边只登记 Swift 载荷。数据面（`ctx.settings.describe` 推快照、
 * `mutate` 收动作）是 M1 的事，会以 `subscribe`/`expose` 的形式长在这里。
 *
 * **`settings` 是硬 inject，有意为之**（计划 §3.1）：服务不在就整个插件不挂载，
 * 于是 Swift 半边不会去占 `settingsOwner`，⌘, 干净地回落到 dash-layout 的页内
 * modal——一个设置界面缺席时的正确姿态是"让位给还能用的那个"，不是"开出一扇空窗"。
 *
 * `llm` / `credentials` **不在这里**：它们缺席只该让「模型」那一页不出现，
 * 不该连累整扇窗口。可选依赖在 M4 用 `ctx.inject([...], cb)` 运行时嵌套
 * ——这个 cordis fork 的 `inject` 没有 `{required, optional}` 形态。
 *
 * **不 inject `dash-layout`**：设置是自己的窗口，不占任何槽，也不需要会话展示面
 * ——完整网页模式（layout 缺席的逃生舱）下 ⌘, 照样该开出原生设置窗口。
 *
 * @module dash-settings
 */
import { createSwiftPlugin } from "../../dash-bridge/lib/plugin.js";

export default createSwiftPlugin({
	name: "dash-settings",
	provide: "dash-settings",
	inject: ["settings"],
	swiftDir: new URL("../swift/", import.meta.url),
});
