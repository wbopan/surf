/*
 * dash-settings，浏览器半边（lazy-CJS 经典脚本，手写、无构建步骤）。
 *
 * **职责**：URL 带 `?dash-settings=1` 时，把这一页变成「只有设置面板」的一页——
 * 它是要装进原生设置窗口的那块内容，所以不该有主界面、遮罩、圆角和关闭按钮。
 *
 * ## 为什么是「改造官方面板」而不是「自己渲染 sections」
 *
 * 试过更正当的路并且证伪了：注册进 `root` 槽（压低 priority 就能 shadow 掉
 * AppFrame）、由我们重新声明 `settings.*` 让各 section 在我们的容器里重新注册。
 * **槽声明是 load-time 的，绑在 entry 的注册上，与它是否胜出无关**——官方
 * SettingsRoot 注册在 `sidebar.settings` 上，哪怕整条祖先链都不渲染，它 declare
 * 的六个 `settings.*` 依然占着名字，我们再声明就是
 * `slot "settings.header" is already declared`。反过来抢先声明只会让
 * ui-settings-general 整个加载失败。详见 README「已证伪」一节，别再走一遍。
 *
 * 所以：**渲染树只能由官方那条链产出，我们只改它的呈现形态。**
 *
 * ## 三条依赖，按脆弱程度排序
 *
 * 1. `[class*="_overlay"]` —— 找到面板的唯一锚点。hash 化 CSS module 的语义
 *    后缀稳定（与仓库其它插件同一套防御式写法）。
 * 2. 面板导航行的**顺序** = ledger 的 order 顺序。原生导航点第 n 行，我们就点
 *    面板里第 n 个导航按钮（label 再对一次，对不上就退回按序号）。
 * 3. 面板由点击 `button[aria-haspopup="dialog"]` 打开——官方的开关是组件局部
 *    state，没有公开服务（dash-layout 的 openSettings 也是这么做的）。
 *
 * 刻意**不依赖**类名的地方：藏页面靠运行时给 overlay 的祖先链打标记，
 * 兄弟一律 display:none。这样布局怎么改都不用跟——只要 overlay 还在。
 *
 * ## 与壳的分工
 *
 * 导航目录走 slot ledger（`entries`/`subscribe`/`getVersion`/`resolveSlotLabel`
 * 都是公开只读 API，不从 DOM 刮文字），经
 * `window.webkit.messageHandlers.dashSettings` 上报；壳用原生列表渲染它，
 * 切页调 `window.__dashSettings.show(id)`。壳不在场（普通浏览器直接开这个 URL）
 * 时，面板自带的那列导航照常可见可用——那就是退路。
 */
window.__ModuleLoader__.load({
	id: "dash-settings",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });

		const slots = require("@deepseek-ai/dsh-client-ui-slots");

		const STYLE_ID = "dash-settings-style";
		/** 打在 overlay 祖先链上的标记：`keep` 是链上的元素，`chain` 是它们的父。 */
		const KEEP = "dashSettingsKeep";
		const CHAIN = "dashSettingsChain";
		/** 打在面板各部位上的标记（`data-dash-settings="panel"` 等）。 */
		const PART = "dashSettings";

		/** 本页是不是「设置页」形态。普通 `dsh web` 标签页一律 false，整个插件静默。 */
		function settingsMode() {
			try {
				return new URLSearchParams(window.location.search).get("dash-settings") === "1";
			} catch {
				return false;
			}
		}

		/** 运行在 dash 壳内（UA 含 "Dash/"，带斜杠防普通子串误命中）。 */
		function insideDash() {
			try {
				return navigator.userAgent.includes("Dash/");
			} catch {
				return false;
			}
		}

		/**
		 * 经 `window.webkit.messageHandlers.dashSettings` 向壳发消息；
		 * 普通浏览器（无该 handler）静默跳过。
		 * @param {Record<string, unknown>} msg
		 */
		function postToShell(msg) {
			try {
				const handler = window.webkit
					&& window.webkit.messageHandlers
					&& window.webkit.messageHandlers.dashSettings;
				if (handler && typeof handler.postMessage === "function") handler.postMessage(msg);
			} catch { /* 页面卸载等，静默 */ }
		}

		/**
		 * 类名以某后缀结尾。
		 *
		 * **不能用 `[class*="_overlay"]`**：dsh 里 `_overlayAnchor`、`_overlayLayer`
		 * 也含这个子串，第一次实现就命中了 composer 的锚点，于是"面板已经开着"，
		 * 页面被藏成一片黑。hash 化 CSS module 的类名形如 `VOzbGW_overlay`，
		 * 语义后缀是整词，按结尾匹配才不会误伤。
		 */
		function classEndsWith(el, suffix) {
			for (const name of el.classList) if (name.endsWith(suffix)) return true;
			return false;
		}

		/** 后代里第一个类名以 suffix 结尾的元素。 */
		function findBySuffix(root, suffix) {
			const marker = suffix.slice(1); // "_panel" → "panel"，给 [class*=] 用
			for (const el of root.querySelectorAll('[class*="' + marker + '"]')) {
				if (classEndsWith(el, suffix)) return el;
			}
			return null;
		}

		const panel = {
			/**
			 * 面板根（`_overlay`），未打开时 null。
			 * 认准"里面有 `_panel`"再算数——同名后缀的锚点元素不会满足这一条。
			 */
			overlay() {
				for (const el of document.querySelectorAll('[class*="overlay"]')) {
					if (classEndsWith(el, "_overlay") && findBySuffix(el, "_panel") !== null) return el;
				}
				return null;
			},
			/** 面板自带导航的按钮，按面板里的先后顺序。 */
			navCells() {
				const ov = this.overlay();
				if (ov === null) return [];
				const list = findBySuffix(ov, "_navList");
				return list === null ? [] : Array.prototype.filter.call(list.children,
					(el) => el.tagName === "BUTTON");
			},
			/**
			 * 给面板的几个部位打上我们自己的标记，**CSS 只认这些标记，一个 dsh 类名
			 * 都不写**：识别逻辑集中在这一处（要改也只改这里），样式表就不会散着一堆
			 * 随时可能过期的选择器。
			 */
			mark(ov) {
				const mask = findBySuffix(ov, "_mask");
				const body = findBySuffix(ov, "_panel");
				const nav = body === null ? null : findBySuffix(body, "_nav");
				const close = body === null ? null : findBySuffix(body, "_close");
				ov.dataset[PART] = "overlay";
				if (mask !== null) mask.dataset[PART] = "mask";
				if (body !== null) body.dataset[PART] = "panel";
				if (nav !== null) nav.dataset[PART] = "nav";
				if (close !== null) close.dataset[PART] = "close";
			},
		};

		/**
		 * 只留通往面板的那条链，其余兄弟一律收掉。
		 *
		 * **不靠类名找"要藏的东西"**，而是从 overlay 往上走到 body，沿途打
		 * `data-dash-settings-keep`、给它们的父打 `data-dash-settings-chain`，
		 * 剩下的交给一条 CSS 规则。dsh 的布局怎么重排都不用跟——只要 overlay 还在。
		 * @returns {boolean} 是否找到了面板
		 */
		function markChain() {
			for (const el of document.querySelectorAll("[data-" + kebab(KEEP) + "]")) {
				delete el.dataset[KEEP];
			}
			for (const el of document.querySelectorAll("[data-" + kebab(CHAIN) + "]")) {
				delete el.dataset[CHAIN];
			}
			const overlay = panel.overlay();
			if (overlay === null) return false;
			panel.mark(overlay);
			let el = overlay;
			while (el !== null && el !== document.documentElement) {
				el.dataset[KEEP] = "1";
				if (el.parentElement !== null) el.parentElement.dataset[CHAIN] = "1";
				el = el.parentElement;
			}
			return true;
		}

		/** dataset 驼峰键 → data-* 属性名（querySelector 要属性名）。 */
		function kebab(key) {
			return key.replace(/[A-Z]/g, (c) => "-" + c.toLowerCase());
		}

		/**
		 * 让面板**保持**打开。
		 *
		 * 开关是官方组件的局部 state，没有公开服务，所以只能点侧边栏底部那个
		 * `aria-haspopup="dialog"` 的按钮（dash-layout 的 openSettings 也是这么做的）。
		 * 它被我们的 CSS 藏着也照样能 dispatch click——React 合成事件走 document
		 * 上的委托，不看可见性。
		 *
		 * 为什么是"保持"而不是"打开一次"：用户在设置窗口里按 Esc，官方 dialog 会
		 * 自己关掉。这时壳要收到消息去关窗，**页面也得把面板重新开起来**——否则
		 * 下次 ⌘, 打开的是一个空白窗口。
		 *
		 * @param {() => void} onClosed 面板从"开着"变成"没了"时调一次
		 * @returns {() => void} 停止守护
		 */
		function keepPanelOpen(onClosed) {
			let had = false;
			const ensure = () => {
				if (markChain()) { had = true; return; }
				if (had) { had = false; onClosed(); }
				const trigger = document.querySelector('button[aria-haspopup="dialog"]');
				if (trigger !== null) trigger.click();
			};
			const observer = new MutationObserver(ensure);
			observer.observe(document.body, { childList: true, subtree: true });
			// 兜底：首屏 React 还没挂载时 body 可能一直没有变化（observer 不响），
			// 点击被吞掉时也需要再试一次。频率低到不值一提。
			const timer = setInterval(ensure, 500);
			ensure();
			return () => {
				observer.disconnect();
				clearInterval(timer);
			};
		}

		/**
		 * `settings.section` 的 ledger → 导航行。
		 *
		 * 与官方 Plugins 段投影 tab 的做法同构（entries + resolveSlotLabel + 按
		 * order 排）：label 可能是跟随 locale 的 thunk，所以 locale 版本变了也要
		 * 重算——locale 服务缺席时退化为只跟 ledger 版本，标签仍是注册时那份。
		 * @param {import('@deepseek-ai/cordis').Context} ctx
		 */
		function makeSectionsSource(ctx) {
			let ledgerVersion = -1;
			let localeRevision = -1;
			let rows = [];
			const locale = typeof ctx.get === "function" ? ctx.get("locale") : undefined;
			return {
				get: () => {
					const version = ctx.slots.getVersion("settings.section");
					const revision = locale ? locale.getSnapshot().revision : -1;
					if (version !== ledgerVersion || revision !== localeRevision) {
						ledgerVersion = version;
						localeRevision = revision;
						rows = ctx.slots.entries("settings.section").map((entry) => ({
							id: entry.options.id ?? "",
							order: entry.options.order ?? 0,
							label: slots.resolveSlotLabel(entry.options.label) ?? "",
						})).sort((a, b) => a.order - b.order);
					}
					return rows;
				},
				subscribe: (listener) => {
					const offLedger = ctx.slots.subscribe("settings.section", listener);
					const offLocale = locale ? locale.subscribe(listener) : () => {};
					return () => {
						offLedger();
						offLocale();
					};
				},
			};
		}

		/**
		 * 切到某一页：面板的选中态是组件局部 state，没有公开服务，只能点它自己的
		 * 导航行。先按 label 对，对不上再按 ledger 里的序号——两份数据同源
		 * （都来自 `settings.section` 的 ledger），所以序号兜底是可信的。
		 * @param {{id:string,label:string}[]} rows
		 * @param {string} id
		 * @returns {boolean} 是否点到了
		 */
		function showSection(rows, id) {
			const index = rows.findIndex((row) => row.id === id);
			if (index < 0) return false;
			const cells = panel.navCells();
			if (cells.length === 0) return false;
			const byLabel = cells.find((cell) => cell.textContent.trim() === rows[index].label.trim());
			const target = byLabel ?? cells[index];
			if (target === undefined) return false;
			target.click();
			return true;
		}

		/**
		 * 页面骨架的遮蔽。
		 *
		 * `!important` 是必须的：这些规则要压过官方 CSS module 里带 hash 的选择器，
		 * 而我们的规则特异度低得多。
		 */
		const CSS = `
/* 链外的兄弟整个不渲染 */
[data-dash-settings-chain] > *:not([data-dash-settings-keep]) { display: none !important; }
/*
 * 链上的祖先只是"路径"，本身一点都不该看见：面板是 position:fixed 的，
 * 布局上不依赖它们，但它们的背景和边框会从面板底下透出来——网页侧边栏那条
 * 56px rail 的右边界就是这么在原生窗口里留下一道竖线的。visibility 关掉整棵
 * 祖先树、再由面板自己打开，比逐个清 background/border 干净得多。
 */
[data-dash-settings-keep] { visibility: hidden !important; }
[data-dash-settings="overlay"] { visibility: visible !important; }
/* 遮罩没有意义——窗口本身就是这块内容的边界 */
[data-dash-settings="mask"] { display: none !important; }
[data-dash-settings="panel"] {
	width: 100% !important;
	max-width: none !important;
	height: 100% !important;
	max-height: none !important;
	border-radius: 0 !important;
	box-shadow: none !important;
}
html, body { background: var(--dsw-alias-bg-layer-2) !important; }
`;

		/** 壳内追加的一段：导航与关闭归 AppKit，网页这两样收起来。 */
		const CSS_IN_SHELL = `
[data-dash-settings="nav"] { display: none !important; }
[data-dash-settings="close"] { display: none !important; }
`;

		/**
		 * 插件体。
		 * @param {import('@deepseek-ai/cordis').Context} ctx
		 */
		function apply(ctx) {
			if (!settingsMode()) return;

			ctx.effect(() => {
				document.getElementById(STYLE_ID)?.remove();
				const style = document.createElement("style");
				style.id = STYLE_ID;
				style.textContent = insideDash() ? CSS + CSS_IN_SHELL : CSS;
				document.head.appendChild(style);
				return () => style.remove();
			}, "dash-settings: 样式");

			const sections = makeSectionsSource(ctx);

			// 目录变了就报给壳一次（原生导航是这份数据的唯一渲染者）。
			ctx.effect(() => {
				const report = () => postToShell({ type: "sections", rows: sections.get() });
				const off = sections.subscribe(report);
				report();
				return off;
			}, "dash-settings: 上报目录");

			ctx.effect(() => keepPanelOpen(() => postToShell({ type: "closed" })),
				"dash-settings: 面板形态");

			ctx.effect(() => {
				window.__dashSettings = {
					show: (id) => showSection(sections.get(), id),
					sections: () => sections.get(),
				};
				return () => { delete window.__dashSettings; };
			}, "dash-settings: 页内动作桥");
		}

		const inject = ["slots"];

		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	},
});
