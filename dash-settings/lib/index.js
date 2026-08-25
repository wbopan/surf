/**
 * dash-settings —— 原生设置窗口。
 *
 * node 半边只登记 Swift 载荷；窗口、导航、WebView 都在 `swift/`，
 * 面板改造与目录上报在 `lib/client.js`。
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
	swiftDir: new URL("../swift/", import.meta.url),
});
