/*
 * DSHarness 适配插件，浏览器半边（lazy-CJS 经典脚本，手写、无构建步骤）。
 *
 * v2 功能（均 UA 门控：仅当页面运行在 DSHarness 的 WKWebView 内、UA 含
 * "DSHarness" 时生效；终端 `dsh web` / 普通浏览器打开同一 profile 不受影响）：
 *
 * 1. （v1）侧边栏顶部让位 + 透出原生玻璃（topInset）。
 * 2. （v2，额外需 URL 参数 dsharness-native-sidebar=1）「隐藏侧边栏」模式：
 *    经 ui-layout 的公开服务 ctx.layout.toggleSidebar() 把侧边栏收起，
 *    再用 CSS 抵消折叠后残留的 56px rail 轨道，会话列从窗口左缘起排；
 *    此模式下停用 v1 的玻璃宽度 ResizeObserver 上报（原生侧边栏自管宽度）。
 * 3. （v2）页内动作桥 window.__dsharness：
 *    selectSession / startSession / openSettings + 当前会话反向回报
 *    （window.webkit.messageHandlers.dsharness.postMessage）。
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
		// ui-layout computeColumns：折叠（sidebar 偏好为 0）时轨道仍占 56px rail。
		const RAIL_PX = 56;

		function insideDSHarness() {
			try {
				return navigator.userAgent.includes("DSHarness");
			} catch {
				return false;
			}
		}

		/** 原生侧边栏模式：UA 门控之上再要求 URL 查询参数 dsharness-native-sidebar=1。 */
		function nativeSidebarMode() {
			try {
				return insideDSHarness() && new URLSearchParams(window.location.search).get("dsharness-native-sidebar") === "1";
			} catch {
				return false;
			}
		}

		/* ------------------------------------------------------------------ *
		 * A2：页内动作桥 window.__dsharness（仅 DSHarness UA；防御式，绝不抛）。
		 * ------------------------------------------------------------------ */

		/**
		 * 经 window.webkit.messageHandlers.dsharness 向壳应用发消息；
		 * 普通浏览器（无该 handler）静默跳过。
		 * @param {Record<string, unknown>} msg
		 */
		function postToShell(msg) {
			try {
				const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dsharness;
				if (handler && typeof handler.postMessage === "function") handler.postMessage(msg);
			} catch { /* 上报失败静默 */ }
		}

		/**
		 * 安装动作桥。三个动作全部走 web UI 自身的公开 cordis 服务：
		 *   - selectSession → ctx.sessions.open(id)（ui-workspace 会话行点击同款）
		 *   - startSession  → ctx.workspaces.startSession(workspaceId?)（ui-sidebar
		 *     New Session 按钮 / ui-workspace 同款；runtime 自行推导目标 workspace）
		 *   - openSettings  → 无公开服务（ui-settings-general 的开关是组件局部
		 *     useState），回退为点击侧边栏设置触发按钮 button[aria-haspopup="dialog"]。
		 * ctx.inject([...], cb) 在服务可用时（含已可用）启动子 fiber；服务缺席则
		 * 该能力静默缺失，ready 上报里如实反映。子 fiber 随本插件 fiber 一起卸载。
		 * @param {import('@deepseek-ai/cordis').Context} ctx
		 */
		function installBridge(ctx) {
			if (typeof window.__dsharness !== "undefined") return; // 幂等（HMR 重载）
			const bridge = {
				selectSession: null,
				startSession: null,
				openSettings: null,
			};
			// 服务迟到接线时由 fiber 回调触发补报（installBridge 末尾赋值）。
			let onWired = () => {};

			// selectSession + 当前会话反向回报（sessions.list 快照 store，
			// 与 ui-agent-preset 的订阅方式一致——同一份渲染数据源）。
			try {
				ctx.inject(["sessions"], (sctx) => {
					try {
						const sessions = sctx.sessions;
						postToShell({ type: "debug", msg: "sessions fiber fired; open=" + typeof sessions?.open + " list=" + typeof sessions?.list });
						if (sessions && typeof sessions.open === "function") {
							bridge.selectSession = (sessionId) => {
								if (typeof sessionId !== "string" || sessionId === "") return;
								try { sessions.open(sessionId); } catch { /* 无效 id 等静默 */ }
							};
							onWired();
						}
						if (sessions && sessions.list && typeof sessions.list.subscribe === "function" && typeof sessions.list.getSnapshot === "function") {
							let lastId, lastAddress;
							const report = () => {
								try {
									const snap = sessions.list.getSnapshot();
									const id = snap.current;
									const address = snap.currentAddress;
									if (id === lastId && address === lastAddress) return;
									lastId = id; lastAddress = address;
									// 会话切换（含当前会话内的子代理导航 currentAddress 变化）。
									if (id !== undefined || address !== undefined) {
										postToShell({ type: "currentSession", id, address });
									}
								} catch { /* 读取失败静默 */ }
							};
							report();
							sctx.effect(() => sessions.list.subscribe(report), "dsharness-adapter: currentSession channel");
						}
					} catch { /* 服务形状不符静默 */ }
				});
			} catch { /* ctx.inject 不可用静默 */ }

			// startSession：与 ui-sidebar / ui-workspace 的 New Session 完全同款。
			try {
				ctx.inject(["workspaces"], (wctx) => {
					try {
						const workspaces = wctx.workspaces;
						postToShell({ type: "debug", msg: "workspaces fiber fired; startSession=" + typeof workspaces?.startSession });
						if (workspaces && typeof workspaces.startSession === "function") {
							bridge.startSession = (workspaceId) => {
								try {
									if (typeof workspaceId === "string" && workspaceId !== "") workspaces.startSession(workspaceId);
									else workspaces.startSession();
								} catch { /* 启动失败静默 */ }
							};
							onWired();
						}
					} catch { /* 服务形状不符静默 */ }
				});
			} catch { /* ctx.inject 不可用静默 */ }

			// openSettings：无公开服务，回退点击 ui-settings-general 的触发按钮
			// （侧边栏 settings 座内唯一 button[aria-haspopup="dialog"]；
			// display:none 的元素仍可 dispatch click，React 合成事件照常触发）。
			try {
				bridge.openSettings = () => {
					try {
						const col = document.querySelector('[class*="_sidebarCol"]');
						const scope = col || document;
						const btn = scope.querySelector('button[aria-haspopup="dialog"]');
						if (btn) btn.click();
					} catch { /* DOM 不符静默 */ }
				};
			} catch { /* 静默 */ }

			// 对外暴露稳定委托对象：方法内部转发到 bridge 槽位（服务 provision
			// 可能晚到——实测冷启动 ~20s——晚到的接线立即可用，无需重建对象）。
			const delegate = (name) => (...args) => {
				try { bridge[name]?.(...args); } catch { /* 静默 */ }
			};
			window.__dsharness = {
				selectSession: delegate("selectSession"),
				startSession: delegate("startSession"),
				openSettings: delegate("openSettings"),
			};

			// ready 上报：caps 反映实际接通的槽位（非委托对象键），接线变化时补报。
			const diag = { inject: typeof ctx.inject };
			let lastCaps = null;
			const postReady = () => {
				try {
					const caps = Object.entries(bridge)
						.filter(([, fn]) => typeof fn === "function")
						.map(([name]) => name);
					const key = caps.join(",");
					if (key === lastCaps) return;
					lastCaps = key;
					postToShell({ type: "ready", capabilities: caps, diag });
				} catch { /* 静默 */ }
			};
			// 固定节奏补报（覆盖服务迟到窗口，最长 30s）+ 每次接线时立即补报。
			for (const delay of [500, 1500, 3000, 6000, 10000, 15000, 20000, 30000]) {
				setTimeout(postReady, delay);
			}
			onWired = postReady;
			postReady();
		}

		/* ------------------------------------------------------------------ *
		 * A1：「隐藏侧边栏」模式。
		 * ------------------------------------------------------------------ */

		/**
		 * 找到 ui-layout AppFrame 的根元素。`[class*="_frame"]` 可能命中其它
		 * css module，因此再验证它带 gridTemplateColumns 内联样式。
		 * @returns {HTMLElement | null}
		 */
		function pickAppFrame() {
			try {
				for (const el of document.querySelectorAll('[class*="_frame"]')) {
					if (el instanceof HTMLElement && el.style && el.style.gridTemplateColumns) return el;
				}
			} catch { /* 静默 */ }
			return null;
		}

		/**
		 * 经 ctx.layout.toggleSidebar()（ui-layout 的公开面板动作面）反复收起
		 * 侧边栏，直到 AppFrame 根带 data-sidebar-collapsed。用
		 * MutationObserver 监听该属性：视图/偏好把侧边栏重新展开时自动再收。
		 * @param {import('@deepseek-ai/cordis').Context} ctx
		 * @returns {() => void} 清理函数
		 */
		function forceSidebarCollapsed(ctx) {
			const disposers = [];
			try {
				ctx.inject(["layout"], (lctx) => {
					const layout = lctx.layout;
					postToShell({ type: "debug", msg: "layout fiber fired; toggle=" + typeof layout?.toggleSidebar });
					if (!layout || typeof layout.toggleSidebar !== "function") return;
					const collapseIfExpanded = () => {
						const frame = pickAppFrame();
						if (!frame) return false;
						if (frame.hasAttribute("data-sidebar-collapsed")) return true;
						try { layout.toggleSidebar(); } catch { /* root entry 未挂载时静默 */ }
						return false;
					};
					// SPA 挂载晚于插件执行：轮询到 AppFrame 首次出现并收起成功，
					// 随后交给 MutationObserver 维持收起状态。
					let observer = null;
					let timer = null;
					let attempts = 0;
					const startObserving = (frame) => {
						if (observer) return;
						observer = new MutationObserver(() => collapseIfExpanded());
						observer.observe(frame, { attributes: true, attributeFilter: ["data-sidebar-collapsed"] });
					};
					timer = setInterval(() => {
						if (collapseIfExpanded()) {
							clearInterval(timer);
							timer = null;
							startObserving(pickAppFrame());
						} else if (++attempts > 120) {
							clearInterval(timer);
							timer = null;
						}
					}, 500);
					disposers.push(() => {
						if (timer) clearInterval(timer);
						observer?.disconnect();
					});
				});
			} catch { /* ctx.inject 不可用静默 */ }
			return () => { for (const d of disposers) { try { d(); } catch { /* 静默 */ } } };
		}

		/**
		 * 测量折叠后 sidebarCol 实际占位（rail 宽），写入 CSS 变量供轨道抵消
		 * 用。默认 56px（computeColumns 的 rail 常量）。SPA 挂载晚：轮询到首挂。
		 * @returns {() => void} 清理函数
		 */
		function trackSidebarOccupancy() {
			let observer = null;
			let pollTimer = null;
			try {
				const root = document.documentElement;
				const setVar = (px) => {
					try { root.style.setProperty("--dsharness-sidebar-occupancy", Math.max(0, Math.round(px)) + "px"); } catch { /* 静默 */ }
				};
				const attach = () => {
					const col = document.querySelector('[class*="_sidebarCol"]');
					if (!col) return false;
					setVar(col.getBoundingClientRect().width);
					if (typeof ResizeObserver !== "undefined") {
						observer = new ResizeObserver(() => setVar(col.getBoundingClientRect().width));
						observer.observe(col);
					}
					return true;
				};
				if (!attach()) {
					pollTimer = setInterval(() => { if (attach()) { clearInterval(pollTimer); pollTimer = null; } }, 500);
					setTimeout(() => { if (pollTimer) { clearInterval(pollTimer); pollTimer = null; } }, 30000);
				}
			} catch { /* 静默 */ }
			return () => { if (pollTimer) clearInterval(pollTimer); observer?.disconnect(); };
		}

		/**
		 * 插件体：注入侧边栏顶部让位样式；fiber 卸载（HMR/禁用）时移除。
		 * @param {import('@deepseek-ai/cordis').Context} ctx
		 * @param {{ topInset?: number }} [config]
		 */
		function apply(ctx, config) {
			if (!insideDSHarness()) return;
			const native = nativeSidebarMode();
			const raw = config && typeof config.topInset === "number" ? config.topInset : 24;
			const topInset = Math.min(Math.max(raw, 0), 200);
			ctx.effect(() => {
				document.getElementById(STYLE_ID)?.remove();
				const style = document.createElement("style");
				style.id = STYLE_ID;
				const rules = [
					":root { --dsharness-titlebar-inset: " + topInset + "px; }",
					// 壳应用左栏是原生 NSGlassEffectView（Liquid Glass）。
					// dsh UI 有多层不透明背景会把它盖住：
					//   1. 整窗框架 _frame 画 --dsw-alias-bg-base（覆盖整窗，含侧边栏）
					//   2. sidebarCol 画 --dsw-specific-sidebar-fill
					//   3. sidebar 组件根（ui-sidebar 的 *_root，sidebarCol 直接子元素，
					//      height:100%）也画 --dsw-specific-sidebar-fill——顶部让位
					//      padding 区无子元素故透出玻璃（即左上小缺口），其余被它盖住。
					// 壳内把这些全透明，底色只保留在中间/右侧列，侧边栏露出原生玻璃。
					"html, body, #root { background: transparent !important; }",
					'[class*="_frame"] {',
					"  background: transparent !important;",
					"}",
					'[class*="_centerCol"], [class*="_detailsCol"] {',
					"  background: var(--dsw-alias-bg-base) !important;",
					"}",
					'[class*="_sidebarCol"] {',
					"  box-sizing: border-box;",
					"  padding-top: var(--dsharness-titlebar-inset);",
					"  background: transparent !important;",
					// sidebarCol 自带 border-right（--dsw-alias-border-l1），
					// 在实体背景上不显眼、贴着玻璃时成了一条突兀的黑白分隔线，去掉。
					"  border-right: none !important;",
					"}",
					// 诊断实测（harness.log DIAG 探针）：sidebarCol 之下有一层透明
					// wrapper，hHd-Xa_root 在第二级，且整栏背景 rgb(27,27,28) 由它绘制。
					// 因此用后代选择器而非直接子选择器。
					'[class*="_sidebarCol"] [class*="_root"] {',
					"  background: transparent !important;",
					"}",
					// 会话列表底部渐变遮罩（ui-workspace 的 *_fade，
					// linear-gradient → --dsw-specific-sidebar-fill 不透明黑），去掉。
					'[class*="_sidebarCol"] [class*="_fade"] {',
					"  background: none !important;",
					"}",
					// 列边界拖拽手柄（ui-layout 的 *_handle，8px 宽，
					// background: --dsw-alias-button-floating-fill）在侧边栏右缘
					// 留一条不透明竖条；拖拽功能靠 cursor，背景可安全去除。
					'[class*="_frame"] [class*="_handle"] {',
					"  background: transparent !important;",
					"}",
				];
				if (native) {
					rules.push(
						// ===== 原生侧边栏模式（dsharness-native-sidebar=1）=====
						// 折叠后 computeColumns 仍给 sidebar 轨道保留 56px rail。
						// grid 轨道宽度由 AppFrame 的内联 gridTemplate-columns 决定、
						// 无法部分覆盖，因此整体把 frame 向左平移 rail 宽（实时测量入
						// --dsharness-sidebar-occupancy，缺省 56px），侧边栏列移出视口、
						// 会话列从窗口左缘起排。frame 自带 overflow:hidden，不会外溢。
						":root { --dsharness-sidebar-occupancy: " + RAIL_PX + "px; }",
						"html[data-dsharness-native-sidebar], html[data-dsharness-native-sidebar] body { overflow: hidden !important; }",
						'html[data-dsharness-native-sidebar] [class*="_frame"] {',
						"  margin-left: calc(-1 * var(--dsharness-sidebar-occupancy)) !important;",
						"  width: calc(100% + var(--dsharness-sidebar-occupancy)) !important;",
						"}",
						// 双保险：侧边栏列内容（rail 图标等）不可交互、不绘制。
						'html[data-dsharness-native-sidebar] [class*="_sidebarCol"] {',
						"  visibility: hidden !important;",
						"  pointer-events: none !important;",
						"}",
					);
					try { document.documentElement.setAttribute("data-dsharness-native-sidebar", ""); } catch { /* 静默 */ }
				}
				style.textContent = rules.join("\n");
				document.head.appendChild(style);
				// 【临时诊断】2.5s 后扫描 sidebarCol 子树里所有「不透明背景」元素，
				// 结果写进一个 1px 文字节点——壳应用 didFinish 诊断会把 body 文本
				// 打进 harness.log（DOM(3s)），据此定位还剩哪层在挡玻璃。
				const diagTimer = setTimeout(() => {
					try {
						const col = document.querySelector('[class*="_sidebarCol"]');
						const rows = [];
						if (col) {
							rows.push("col=" + col.className + " kids=" + col.childElementCount);
							const walk = (el, depth) => {
								if (!el || depth > 6) return;
								for (const child of el.children) {
									const cs = getComputedStyle(child);
									const r = child.getBoundingClientRect();
									const opaque = cs.backgroundColor && !cs.backgroundColor.endsWith(" 0)") && cs.backgroundColor !== "rgba(0, 0, 0, 0)" && cs.backgroundColor !== "transparent";
									if (opaque && r.width > 50 && r.height > 50) {
										rows.push("D" + depth + " " + child.className + " bg=" + cs.backgroundColor + " " + Math.round(r.width) + "x" + Math.round(r.height));
									}
									walk(child, depth + 1);
								}
							};
							walk(col, 1);
						} else {
							rows.push("no sidebarCol found");
						}
						const d = document.createElement("span");
						d.style.cssText = "position:fixed;left:-9999px;top:0;font-size:1px";
						d.textContent = " DIAG: " + rows.join(" | ") + " ";
						// 诊断日志只取 body 前 400 字符，必须插到最前
						document.body.insertBefore(d, document.body.firstChild);
					} catch (e) { /* 诊断失败静默 */ }
				}, 2500);
				// 玻璃宽度跟随：ResizeObserver 监听侧边栏列宽度，经
				// window.webkit.messageHandlers.dsharnessSidebar postMessage
				// 上报壳应用，原生 NSGlassEffectView 同步改宽。
				// 仅壳内 WKWebView 存在 window.webkit.messageHandlers；普通浏览器跳过。
				// 原生侧边栏模式下停用——宽度由原生侧边栏自管。
				// 注：SPA 挂载晚于插件执行，col 可能暂不存在——轮询到首次命中。
				let observer = null;
				let pollTimer = null;
				if (!native) {
					try {
						const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dsharnessSidebar;
						if (handler && typeof ResizeObserver !== "undefined") {
							const attach = () => {
								const col = document.querySelector('[class*="_sidebarCol"]');
								if (!col) return false;
								const report = () => handler.postMessage({ width: col.getBoundingClientRect().width });
								observer = new ResizeObserver(report);
								observer.observe(col);
								report();
								return true;
							};
							if (!attach()) {
								pollTimer = setInterval(() => { if (attach()) clearInterval(pollTimer); }, 500);
								setTimeout(() => clearInterval(pollTimer), 30000);
							}
						}
					} catch (e) { /* 上报失败静默 */ }
				}
				// 原生侧边栏模式的动态部分：强制收起 + rail 占位测量。
				let cleanupCollapse = () => {};
				let cleanupOccupancy = () => {};
				if (native) {
					cleanupCollapse = forceSidebarCollapsed(ctx);
					cleanupOccupancy = trackSidebarOccupancy();
				}
				// A2：动作桥（与原生侧边栏模式无关，凡 DSHarness UA 即装）。
				installBridge(ctx);
				return () => {
					clearTimeout(diagTimer); clearInterval(pollTimer); observer?.disconnect(); style.remove();
					cleanupCollapse(); cleanupOccupancy();
					try { document.documentElement.removeAttribute("data-dsharness-native-sidebar"); } catch { /* 静默 */ }
					try { document.documentElement.style.removeProperty("--dsharness-sidebar-occupancy"); } catch { /* 静默 */ }
					try { delete window.__dsharness; } catch { try { window.__dsharness = undefined; } catch { /* 静默 */ } }
				};
			});
		}

		exports.apply = apply;
		exports.inject = [];
		return module.exports;
	}
});
