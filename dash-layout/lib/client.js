/*
 * dash-layout，浏览器半边（lazy-CJS 经典脚本，手写、无构建步骤）。
 *
 * **为什么住在 dash-layout**：这里的两件事都是「原生分栏接管排版」的网页对端，
 * 而它们唯一的 Swift 调用方就是本包的 `WebViewConversationSurface`
 * （swift/ConversationSurface.swift）。协议两端同包 = 改一边必然看见另一边，
 * 与 `DashConversationSurface` 协议「住在消费者侧」是同一条 1×N 规则。
 *
 * 1. **页内动作桥 `window.__dash`**：selectSession / startSession / openSettings
 *    + 当前会话反向回报（window.webkit.messageHandlers.dash.postMessage）。
 * 2. **收起 web 侧边栏**：经 ui-layout 的公开服务 ctx.layout.toggleSidebar()
 *    把侧边栏收起，再用 CSS 抵消折叠后残留的 56px rail 轨道，会话列从窗口
 *    左缘起排——原生侧边栏（dash-sidebar）占的就是那块地方。
 *
 * 纯样式的原生化（透出玻璃、红绿灯让位、禁橡皮筋/禁选中）不在这里，
 * 那是 dash-nativeify 的事，它零服务依赖、要抢首帧。
 *
 * 门控：UA 含 "Dash/"（动作桥）之上，收起侧边栏再要求 URL 参数
 * dash-native-sidebar=1。终端 `dsh web` / 普通浏览器不受影响。
 *
 * 选择器说明：dsh Web UI 的类名是 hash 化 CSS module（如 pI_x6G_sidebarCol），
 * hash 随版本变化但语义后缀稳定，因此用 [class*="_sidebarCol"] 防御式命中。
 */
window.__ModuleLoader__.load({
	id: "dash-layout",
	factory: () => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });

		const STYLE_ID = "dash-layout-style";
		// ui-layout computeColumns：折叠（sidebar 偏好为 0）时轨道仍占 56px rail。
		const RAIL_PX = 56;

		function insideDash() {
			try {
				return navigator.userAgent.includes("Dash/");
			} catch {
				return false;
			}
		}

		/** 原生侧边栏模式：UA 门控之上再要求 URL 查询参数 dash-native-sidebar=1。 */
		function nativeSidebarMode() {
			try {
				return insideDash() && new URLSearchParams(window.location.search).get("dash-native-sidebar") === "1";
			} catch {
				return false;
			}
		}

		/**
		 * 经 window.webkit.messageHandlers.dash 向壳应用发消息；
		 * 普通浏览器（无该 handler）静默跳过。
		 * @param {Record<string, unknown>} msg
		 */
		function postToShell(msg) {
			try {
				const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dash;
				if (handler && typeof handler.postMessage === "function") handler.postMessage(msg);
			} catch { /* 上报失败静默 */ }
		}

		/* ------------------------------------------------------------------ *
		 * 页内动作桥 window.__dash（仅 dash UA；防御式，绝不抛）。
		 * ------------------------------------------------------------------ */

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
			if (typeof window.__dash !== "undefined") return; // 幂等（HMR 重载）
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
							sctx.effect(() => sessions.list.subscribe(report), "dash-layout: currentSession channel");
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
			window.__dash = {
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
		 * 「隐藏 web 侧边栏」模式。
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
					try { root.style.setProperty("--dash-sidebar-occupancy", Math.max(0, Math.round(px)) + "px"); } catch { /* 静默 */ }
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
		 * 插件体：装动作桥（凡 Dash/ UA）+ 收起 web 侧边栏（再要 native 模式）。
		 * @param {import('@deepseek-ai/cordis').Context} ctx
		 */
		function apply(ctx) {
			if (!insideDash()) return;
			const native = nativeSidebarMode();
			ctx.effect(() => {
				let style = null;
				let cleanupCollapse = () => {};
				let cleanupOccupancy = () => {};
				if (native) {
					document.getElementById(STYLE_ID)?.remove();
					style = document.createElement("style");
					style.id = STYLE_ID;
					style.textContent = [
						// 折叠后 computeColumns 仍给 sidebar 轨道保留 56px rail。
						// grid 轨道宽度由 AppFrame 的内联 gridTemplate-columns 决定、
						// 无法部分覆盖，因此整体把 frame 向左平移 rail 宽（实时测量入
						// --dash-sidebar-occupancy，缺省 56px），侧边栏列移出视口、
						// 会话列从窗口左缘起排。frame 自带 overflow:hidden，不会外溢。
						":root { --dash-sidebar-occupancy: " + RAIL_PX + "px; }",
						'html[data-dash-native-sidebar] [class*="_frame"] {',
						"  margin-left: calc(-1 * var(--dash-sidebar-occupancy)) !important;",
						"  width: calc(100% + var(--dash-sidebar-occupancy)) !important;",
						"}",
						// 双保险：侧边栏列内容（rail 图标等）不可交互、不绘制。
						'html[data-dash-native-sidebar] [class*="_sidebarCol"] {',
						"  visibility: hidden !important;",
						"  pointer-events: none !important;",
						"}",
					].join("\n");
					document.head.appendChild(style);
					try { document.documentElement.setAttribute("data-dash-native-sidebar", ""); } catch { /* 静默 */ }
					cleanupCollapse = forceSidebarCollapsed(ctx);
					cleanupOccupancy = trackSidebarOccupancy();
				}
				installBridge(ctx);
				return () => {
					style?.remove();
					cleanupCollapse(); cleanupOccupancy();
					try { document.documentElement.removeAttribute("data-dash-native-sidebar"); } catch { /* 静默 */ }
					try { document.documentElement.style.removeProperty("--dash-sidebar-occupancy"); } catch { /* 静默 */ }
					try { delete window.__dash; } catch { try { window.__dash = undefined; } catch { /* 静默 */ } }
				};
			});
		}

		exports.apply = apply;
		// 三个服务（sessions / workspaces / layout）全部走作用域 ctx.inject：
		// 服务缺席时该能力静默缺失，插件本身照常挂载——顶层硬依赖会让任一服务
		// 重载连带本插件卸载重挂，白白抖掉已装好的 window.__dash。
		exports.inject = [];
		return module.exports;
	}
});
