/*
 * dash-nativeify，浏览器半边（lazy-CJS 经典脚本，手写、无构建步骤）。
 *
 * **职责边界**：只做「让 dsh Web UI 摸起来像原生 macOS App」这一件事，
 * 全部实现是注入一段 CSS，零服务依赖、零跨插件契约：禁掉 document 橡皮筋、
 * UI 文本不可选中（输入框与会话消息流除外）。
 *
 * **不在这里的**：
 * - `window.__dash` 动作桥、收起 web 侧边栏、rail 轨道抵消——那些是原生分栏
 *   接管排版的一部分，住在 dash-layout 的 client 半边（协议两端同包：Swift 侧
 *   `WebViewConversationSurface` 是它们唯一的调用方）。
 * - 网页侧边栏的任何外观调整（顶部让位、背景透明化以透出原生玻璃）。这些是
 *   「网页侧边栏坐在壳的 NSGlassEffectView 上」那个旧世界的产物，已随 M6 作废：
 *   现在只有两种形态——原生侧边栏（dash-layout 占 root 槽，WebView 装在分栏右侧，
 *   够不着侧边栏那一栏）或完整网页模式（全出血逃生舱，原样展示 dsh UI，不修）。
 *   「用网页侧边栏但把它打扮成原生」这个中间态不存在，别再往回加。
 *
 * 门控只有一条：UA 含 "Dash/"（带斜杠，防普通子串误命中）。终端 `dsh web` /
 * 普通浏览器打开同一 profile 完全不受影响。
 *
 * 选择器说明：dsh Web UI 的类名是 hash 化 CSS module（如 Md3f7G_flowItem），
 * hash 随版本变化但语义后缀稳定，因此用 [class*="_flowItem"] 防御式命中。
 * 升级 dsh 后若失效，优先核对该语义名。
 */
window.__ModuleLoader__.load({
	id: "dash-nativeify",
	factory: () => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });

		const STYLE_ID = "dash-nativeify-style";

		function insideDash() {
			try {
				return navigator.userAgent.includes("Dash/");
			} catch {
				return false;
			}
		}

		/**
		 * 插件体：注入原生化样式；fiber 卸载（HMR/禁用）时移除。
		 * @param {import('@deepseek-ai/cordis').Context} ctx
		 */
		function apply(ctx) {
			if (!insideDash()) return;
			ctx.effect(() => {
				document.getElementById(STYLE_ID)?.remove();
				const style = document.createElement("style");
				style.id = STYLE_ID;
				const rules = [
					// 整页滚动 + 橡皮筋：overflow:hidden 在 WebKit 里不禁用 elastic
					// 滚动——内层滚动容器（[data-conversation-scroll] 等）滚到底后
					// 惯性仍会链到 document，把整页（conversation+details）拉走。
					// overscroll-behavior:none 禁 document 橡皮筋；内层所有元素
					// contain 切断滚动链（自身仍可滚、自身边界仍有原生回弹）。
					"html, body { overflow: hidden !important; overscroll-behavior: none !important; }",
					"body * { overscroll-behavior: contain !important; }",
					// UI 文本不可选中（壳应用观感）：全局关掉 user-select，
					// 输入类控件（composer 输入框等）恢复可选以便编辑。
					"body { -webkit-user-select: none !important; user-select: none !important; }",
					"input, textarea, [contenteditable] { -webkit-user-select: text !important; user-select: text !important; }",
					// 对话历史必须可复制：放开会话消息流与右侧 details 内容区。
					// _flowItem = ui-conversation 每条消息的容器（用户气泡/助手
					// markdown/思考/错误行全在其子树内；user-select 的 auto 随父
					// 生效，整棵子树一起放开）；_contentColumn = ui-trajectory 的
					// 工具调用详情内容列；pre/code 兜底放开所有代码块。
					'[class*="_flowItem"], [class*="_contentColumn"], pre, code { -webkit-user-select: text !important; user-select: text !important; }',

					// ===== 按钮原生化（macOS 26 / Tahoe 观感）=====
					//
					// 三条 Apple 动效常数。曲线取自 SwiftUI 全系基准（起步快、收尾极缓）；
					// 按下切到 80ms 让它跟手，松开回到 320ms 留余韵。
					":root {",
					"  --dash-ease: cubic-bezier(0.32, 0.72, 0, 1);",
					"  --dash-dur-press: 80ms;",
					"  --dash-dur-fast: 160ms;",
					"  --dash-dur: 320ms;",
					// 发丝边框与镜面高光。macOS 在 Retina 上用半像素描边，这是"原生感"
					// 的头号来源；用 inset box-shadow 而非 border，不动盒模型、不改布局。
					"  --dash-hairline: rgba(0, 0, 0, 0.10);",
					"  --dash-specular: rgba(255, 255, 255, 0.85);",
					"}",
					// dsh 的深色主题挂在 body[data-ds-dark-theme] 上（它自己的 --dsw-*
					// token 也是在那儿翻面的），高光跟着翻。
					"body[data-ds-dark-theme] {",
					"  --dash-hairline: rgba(255, 255, 255, 0.14);",
					"  --dash-specular: rgba(255, 255, 255, 0.22);",
					"}",

					// 统一过渡。dsh 给按钮写的是 transition: all，会把 scale 一起卷进它
					// 自己的时长里；这里换成逐属性声明，scale 走长曲线、配色走短线性。
					"button, [role=\"button\"] {",
					"  transition:",
					"    scale var(--dash-dur) var(--dash-ease),",
					"    background-color var(--dash-dur-fast) linear,",
					"    box-shadow var(--dash-dur-fast) var(--dash-ease),",
					"    color var(--dash-dur-fast) linear !important;",
					"}",
					"button svg, [role=\"button\"] svg {",
					"  transition: scale var(--dash-dur) var(--dash-ease), opacity var(--dash-dur) var(--dash-ease);",
					"}",

					// 按压：容器涨、图标缩。这两个方向相反的形变是 Liquid Glass 手感的
					// 全部秘密——只做其中一个都不像（实测：单独放大像网页 hover，单独
					// 缩小像 Android ripple 的前摇）。scale 是独立属性、不占布局，
					// 因此在 flex/grid 里放大不会挤动邻居。
					"button:not(:disabled):not([aria-disabled=\"true\"]):active,",
					"[role=\"button\"]:not([aria-disabled=\"true\"]):active {",
					"  scale: 1.06;",
					"  transition-duration: var(--dash-dur-press) !important;",
					"}",
					"button:not(:disabled):not([aria-disabled=\"true\"]):active svg,",
					"[role=\"button\"]:not([aria-disabled=\"true\"]):active svg {",
					"  scale: 0.88;",
					"  opacity: 0.7;",
					"  transition-duration: var(--dash-dur-press);",
					"}",

					// 悬停时浮出发丝边框 + 上缘镜面高光。只加 box-shadow、不碰
					// background-color——dsh 自己的 hover 底色（--dsw-alias-interactive-bg-hover）
					// 继续生效，深浅主题自动跟随。实心强调色按钮（发送键）叠上这层也对：
					// macOS 的 accent 按钮同样有一圈内高光。
					"button:not(:disabled):not([aria-disabled=\"true\"]):hover,",
					"[role=\"button\"]:not([aria-disabled=\"true\"]):hover {",
					"  box-shadow:",
					"    inset 0 0 0 0.5px var(--dash-hairline),",
					"    inset 0 0.5px 0 var(--dash-specular),",
					"    0 0.5px 1px rgba(0, 0, 0, 0.05);",
					"}",

					// 尊重"减少动态效果"：关掉形变，保留配色反馈。
					"@media (prefers-reduced-motion: reduce) {",
					"  button:active, [role=\"button\"]:active, button:active svg, [role=\"button\"]:active svg {",
					"    scale: 1 !important;",
					"  }",
					"}",
				];
				style.textContent = rules.join("\n");
				document.head.appendChild(style);
				return () => { style.remove(); };
			});
		}

		exports.apply = apply;
		// 顶层留空是刻意的：这段 CSS 的全部意义就是抢在首帧之前生效。挂上任何
		// 硬依赖都会把它推迟到那些服务就绪之后，且服务重载会连带本插件卸载重挂
		// （= 用户能看见的一次背景闪动）。本插件也确实不需要任何服务。
		exports.inject = [];
		return module.exports;
	}
});
