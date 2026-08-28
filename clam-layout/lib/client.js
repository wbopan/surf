/*
 * clam-layout，浏览器半边（lazy-CJS 经典脚本，手写、无构建步骤）。
 *
 * **为什么住在 clam-layout**：这里的两件事都是「原生分栏接管排版」的网页对端，
 * 而它们唯一的 Swift 调用方就是本包的 `WebViewConversationSurface`
 * （swift/ConversationSurface.swift）。协议两端同包 = 改一边必然看见另一边，
 * 与 `ClamConversationSurface` 协议「住在消费者侧」是同一条 1×N 规则。
 *
 * 1. **页内动作桥 `window.__clam`**：selectSession / startSession / openSettings
 *    + 当前会话反向回报（window.webkit.messageHandlers.clam.postMessage）。
 * 2. **收起 web 侧边栏**：经 ui-layout 的公开服务 ctx.layout.toggleSidebar()
 *    把侧边栏收起，再用 CSS 抵消折叠后残留的 56px rail 轨道，会话列从窗口
 *    左缘起排——原生侧边栏（clam-sidebar）占的就是那块地方。
 *
 * 纯样式的原生化（透出玻璃、红绿灯让位、禁橡皮筋/禁选中）不在这里，
 * 那是 clam-nativeify 的事，它零服务依赖、要抢首帧。
 *
 * 门控：UA 含 "Clam/"（动作桥）之上，收起侧边栏再要求 URL 参数
 * clam-native-sidebar=1。终端 `dsh web` / 普通浏览器不受影响。
 *
 * 选择器说明：dsh Web UI 的类名是 hash 化 CSS module（如 pI_x6G_sidebarCol），
 * hash 随版本变化但语义后缀稳定，因此用 [class*="_sidebarCol"] 防御式命中。
 */
window.__ModuleLoader__.load({
	id: "@wenbo/clam-layout",
	factory: () => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });

		const STYLE_ID = "clam-layout-style";
		const NATIVE_ATTR = "data-clam-native-sidebar";
		const OCCUPANCY_VAR = "--clam-sidebar-occupancy";
		// ui-layout computeColumns：折叠（sidebar 偏好为 0）时轨道仍占 56px rail。
		const RAIL_PX = 56;

		/**
		 * 每次 effect 启动生成的实例 token，写进全局状态当所有权标记。
		 * client 半边 HMR 的重载顺序是「新实例先启、旧实例后清」，无条件
		 * 清理会让后跑的旧 cleanup 砍掉新实例刚装好的东西（属性一摘，
		 * 隐藏 web 侧边栏的整套 CSS 就地失效，rail 或整条侧边栏露出来）。
		 * @returns {string}
		 */
		function makeToken() {
			try { return "dl" + Math.random().toString(36).slice(2, 10); } catch { return "dl0"; }
		}

		function insideClam() {
			try {
				return navigator.userAgent.includes("Clam/");
			} catch {
				return false;
			}
		}

		/** 原生侧边栏模式：UA 门控之上再要求 URL 查询参数 clam-native-sidebar=1。 */
		function nativeSidebarMode() {
			try {
				return insideClam() && new URLSearchParams(window.location.search).get("clam-native-sidebar") === "1";
			} catch {
				return false;
			}
		}

		/**
		 * 经 window.webkit.messageHandlers.clam 向壳应用发消息；
		 * 普通浏览器（无该 handler）静默跳过。
		 * @param {Record<string, unknown>} msg
		 */
		function postToShell(msg) {
			try {
				const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.clam;
				if (handler && typeof handler.postMessage === "function") handler.postMessage(msg);
			} catch { /* 上报失败静默 */ }
		}

		/* ------------------------------------------------------------------ *
		 * 页内动作桥 window.__clam（仅 clam UA；防御式，绝不抛）。
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
		 * 每次启动都重装：新实例的服务接线才是活的，沿用上一代的 window.__clam
		 * 等于留一个 fiber 已卸载的僵尸桥（点原生侧边栏没反应）。
		 * @param {import('@deepseek-ai/cordis').Context} ctx
		 * @param {string} token 实例所有权标记
		 * @returns {() => void} 清理函数
		 */
		function installBridge(ctx, token) {
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
							sctx.effect(() => sessions.list.subscribe(report), "clam-layout: currentSession channel");
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
			window.__clam = {
				selectSession: delegate("selectSession"),
				startSession: delegate("startSession"),
				openSettings: delegate("openSettings"),
				__clamToken: token,
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
			const timers = [];
			for (const delay of [500, 1500, 3000, 6000, 10000, 15000, 20000, 30000]) {
				timers.push(setTimeout(postReady, delay));
			}
			onWired = postReady;
			postReady();

			return () => {
				for (const t of timers) clearTimeout(t); // 卸载后别再补报，否则壳收到过期 caps
				try {
					// 只收回自己装的那份（见 makeToken）。
					if (window.__clam && window.__clam.__clamToken === token) delete window.__clam;
				} catch {
					try { window.__clam = undefined; } catch { /* 静默 */ }
				}
			};
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
		 * 经 ctx.layout.toggleSidebar()（ui-layout 的公开面板动作面）把侧边栏
		 * 维持在收起态。两条互补的触发：MutationObserver 盯
		 * data-sidebar-collapsed（偏好被改时即刻回收），加一条常驻低频巡检。
		 *
		 * **巡检不能在首次收起成功后停**：AppFrame 是 React 组件，root entry
		 * 重注册（client HMR 等）会把它整个重建成新的 DOM 节点，observer 却
		 * 还盯着脱离文档的旧节点——守护就此永久失效，而新的 layout store 从
		 * 默认 sidebar:280 起步 = 侧边栏完整展开，与原生侧边栏并排出现。
		 * 巡检每轮比对 frame 身份，换了就把 observer 迁过去。
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
					let observer = null;
					let observed = null; // observer 当前绑定的 frame 节点
					let lastToggle = 0;
					const sync = () => {
						const frame = pickAppFrame();
						if (!frame) return;
						if (frame !== observed) {
							observer?.disconnect();
							observer = new MutationObserver(sync);
							observer.observe(frame, { attributes: true, attributeFilter: ["data-sidebar-collapsed"] });
							observed = frame;
						}
						if (frame.hasAttribute("data-sidebar-collapsed")) return;
						// toggleSidebar 是开关不是「收起」，但两种模式下（宽视口翻
						// sidebar 偏好、窄视口翻 narrowExpanded）一次翻转都收敛到
						// 收起，不会震荡。节流只防病态情形（展开态被外力按住）空转。
						const now = Date.now();
						if (now - lastToggle < 250) return;
						lastToggle = now;
						try { layout.toggleSidebar(); } catch { /* root entry 未挂载时静默 */ }
					};
					const timer = setInterval(sync, 500);
					sync();
					disposers.push(() => {
						clearInterval(timer);
						observer?.disconnect();
					});
				});
			} catch { /* ctx.inject 不可用静默 */ }
			return () => { for (const d of disposers) { try { d(); } catch { /* 静默 */ } } };
		}

		/**
		 * 测量折叠后 sidebarCol 实际占位（rail 宽），写入 CSS 变量供轨道抵消
		 * 用。默认 56px（computeColumns 的 rail 常量）。
		 *
		 * 巡检常驻、且比对 col 身份，理由同 forceSidebarCollapsed：AppFrame
		 * 重建后 ResizeObserver 会绑在脱离文档的旧列上，变量停在过期值。
		 * @returns {() => void} 清理函数
		 */
		function trackSidebarOccupancy() {
			let observer = null;
			let observed = null; // observer 当前绑定的 sidebarCol 节点
			let timer = null;
			try {
				const root = document.documentElement;
				const setVar = (px) => {
					try { root.style.setProperty(OCCUPANCY_VAR, Math.max(0, Math.round(px)) + "px"); } catch { /* 静默 */ }
				};
				const sync = () => {
					const col = document.querySelector('[class*="_sidebarCol"]');
					if (!col) return;
					if (col !== observed) {
						observer?.disconnect();
						observed = col;
						if (typeof ResizeObserver !== "undefined") {
							observer = new ResizeObserver(() => setVar(col.getBoundingClientRect().width));
							observer.observe(col);
						}
					}
					setVar(col.getBoundingClientRect().width);
				};
				timer = setInterval(sync, 500);
				sync();
			} catch { /* 静默 */ }
			return () => { if (timer) clearInterval(timer); observer?.disconnect(); };
		}

		/**
		 * 插件体：装动作桥（凡 Clam/ UA）+ 收起 web 侧边栏（再要 native 模式）。
		 * @param {import('@deepseek-ai/cordis').Context} ctx
		 */
		function apply(ctx) {
			if (!insideClam()) return;
			const native = nativeSidebarMode();
			ctx.effect(() => {
				const token = makeToken();
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
						// --clam-sidebar-occupancy，缺省 56px），侧边栏列移出视口、
						// 会话列从窗口左缘起排。frame 自带 overflow:hidden，不会外溢。
						":root { " + OCCUPANCY_VAR + ": " + RAIL_PX + "px; }",
						"html[" + NATIVE_ATTR + '] [class*="_frame"] {',
						"  margin-left: calc(-1 * var(" + OCCUPANCY_VAR + ")) !important;",
						"  width: calc(100% + var(" + OCCUPANCY_VAR + ")) !important;",
						"}",
						// 双保险：侧边栏列内容（rail 图标等）不可交互、不绘制。
						"html[" + NATIVE_ATTR + '] [class*="_sidebarCol"] {',
						"  visibility: hidden !important;",
						"  pointer-events: none !important;",
						"}",
						// **例外：设置 modal**。dsh 把它渲染在侧边栏列**内部**
						// （_sidebarCol > … > _settingsArea > _overlay > _panel），
						// 不是 portal 到 body，所以整列隐形会把它一起带走——点得中、
						// 挂载成功、就是看不见，且不报任何错。这是 ⌘, 在 clam-settings
						// 缺席时唯一的逃生舱（原生窗口不在场时 layout 会回落到它），
						// 死了就等于没有设置入口。overlay 是 position:fixed，
						// 不受上面那条 frame 平移影响，所以只需把可见性与命中还回去。
						"html[" + NATIVE_ATTR + '] [class*="_sidebarCol"] [class*="_overlay"] {',
						"  visibility: visible !important;",
						"  pointer-events: auto !important;",
						"}",
					].join("\n");
					document.head.appendChild(style);
					// 属性值 = 实例 token：cleanup 据此判断这份全局状态还是不是自己的。
					try { document.documentElement.setAttribute(NATIVE_ATTR, token); } catch { /* 静默 */ }
					cleanupCollapse = forceSidebarCollapsed(ctx);
					cleanupOccupancy = trackSidebarOccupancy();
				}
				const cleanupBridge = installBridge(ctx, token);
				return () => {
					style?.remove();
					cleanupCollapse(); cleanupOccupancy(); cleanupBridge();
					// 所有权检查（见 makeToken）：HMR 下新实例可能已经接管全局状态，
					// 这里无条件清理就等于替它把自己的 CSS 开关摘掉——症状是 web
					// 侧边栏（或其 56px rail）与原生侧边栏并排出现，⌘R 才恢复。
					try {
						const root = document.documentElement;
						if (root.getAttribute(NATIVE_ATTR) === token) {
							root.removeAttribute(NATIVE_ATTR);
							root.style.removeProperty(OCCUPANCY_VAR);
						}
					} catch { /* 静默 */ }
				};
			});
		}

		exports.apply = apply;
		// 三个服务（sessions / workspaces / layout）全部走作用域 ctx.inject：
		// 服务缺席时该能力静默缺失，插件本身照常挂载——顶层硬依赖会让任一服务
		// 重载连带本插件卸载重挂，白白抖掉已装好的 window.__clam。
		exports.inject = [];
		return module.exports;
	}
});
