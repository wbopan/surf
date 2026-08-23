/*
 * DSHarness 适配插件，浏览器半边（lazy-CJS 经典脚本，手写、无构建步骤）。
 *
 * 唯一功能：仅当页面运行在 DSHarness 的 WKWebView 内（UA 含 "DSHarness"，
 * 由壳应用 applicationNameForUserAgent 声明）时，给侧边栏列顶部加 padding，
 * 为 macOS 窗口红绿灯留位。终端 `dsh web` / 普通浏览器打开同一 profile 不受影响。
 *
 * 选择器说明：dsh Web UI 的类名是 hash 化 CSS module（如 pI_x6G_sidebarCol），
 * hash 随版本变化但语义后缀稳定，因此用 [class*="_sidebarCol"] 防御式命中
 * ui-layout AppFrame 的侧边栏列。升级 dsh 后若失效，优先核对该语义名。
 */
window.__ModuleLoader__.load({
	id: "dsharness-web-adapter",
	factory: () => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });

		const STYLE_ID = "dsharness-web-adapter-style";

		function insideDSHarness() {
			try {
				return navigator.userAgent.includes("DSHarness");
			} catch {
				return false;
			}
		}

		/**
		 * 插件体：注入侧边栏顶部让位样式；fiber 卸载（HMR/禁用）时移除。
		 * @param {import('@deepseek-ai/cordis').Context} ctx
		 * @param {{ topInset?: number }} [config]
		 */
		function apply(ctx, config) {
			if (!insideDSHarness()) return;
			const raw = config && typeof config.topInset === "number" ? config.topInset : 24;
			const topInset = Math.min(Math.max(raw, 0), 200);
			ctx.effect(() => {
				document.getElementById(STYLE_ID)?.remove();
				const style = document.createElement("style");
				style.id = STYLE_ID;
				style.textContent = [
					":root { --dsharness-titlebar-inset: " + topInset + "px; }",
					'[class*="_sidebarCol"] {',
					"  box-sizing: border-box;",
					"  padding-top: var(--dsharness-titlebar-inset);",
					"}",
				].join("\n");
				document.head.appendChild(style);
				return () => style.remove();
			});
		}

		exports.apply = apply;
		exports.inject = [];
		return module.exports;
	}
});
