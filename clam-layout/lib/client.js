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
 * 3. **键位表投影**：订 settings 的 `clam-shortcuts` 命名空间（schema 由 clam-app
 *    的 node 半边注册），值一变就经同一条页内桥推给壳，壳据此重建主菜单。
 *    住这儿是因为页 → 壳的上报通道（ready / currentSession）本来就归它。
 *    计划：docs/clam-shortcuts-settings-plan.md。
 * 4. **语言投影**：订 `ctx.locale`（dsh 解析后的 active，不是设置里的原始
 *    preference），经同一条页内桥推给壳，壳转成粘性总线主题 `clam.locale`
 *    供原生插件消费。计划：docs/clam-i18n-plan.md。
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

		/* ------------------------------------------------------------------ *
		 * 快捷键设置（ns `clam-shortcuts`，schema 由 clam-app 的 node 半边注册）。
		 * ------------------------------------------------------------------ */

		/** 设置命名空间。与 clam-app/lib/index.js 的 SHORTCUTS_NAMESPACE 逐字一致。 */
		const SHORTCUTS_NS = "clam-shortcuts";

		/**
		 * `stopGenerating` 的兜底 spec。**其余键位的默认值不在这儿**——那些归壳，
		 * 页面从不解析它们，只是把整份 values 原样转交（见 installBridge 的 keymap
		 * 投影）。这一条例外只因为它是**页面自己**匹配的：原生菜单项拦不住焦点在
		 * WebView 里的按键，所以停止生成必须在这边做。
		 */
		const STOP_DEFAULT = "esc";

		/** spec 里的修饰符别名 → 规范名。 */
		const SPEC_MODIFIERS = {
			cmd: "cmd", command: "cmd", meta: "cmd",
			shift: "shift",
			alt: "alt", option: "alt", opt: "alt",
			ctrl: "ctrl", control: "ctrl",
		};

		/**
		 * spec 里的具名键 → `KeyboardEvent.key` 的值。表外的 token 必须是**单字符**
		 * （`a`、`,`、`]`），否则视为写错、整条 spec 解析失败——宁可退回默认，也不要
		 * 留一个"装上了但永远匹配不到"的死键位。
		 */
		const SPEC_KEYS = {
			esc: "Escape", escape: "Escape",
			backspace: "Backspace",
			space: " ",
			tab: "Tab",
			enter: "Enter", return: "Enter",
			left: "ArrowLeft", right: "ArrowRight", up: "ArrowUp", down: "ArrowDown",
			plus: "+",
		};

		/**
		 * 解析一条键位 spec（小写、`+` 连接，如 `cmd+alt+.`）。
		 * @param {unknown} spec
		 * @returns {{key: string, cmd: boolean, shift: boolean, alt: boolean, ctrl: boolean} | null}
		 *   null = 空串（明确禁用）或解析失败，两者由调用方 readKeySpec 区分。
		 */
		function parseKeySpec(spec) {
			try {
				if (typeof spec !== "string") return null;
				// `cmd++`（键本身就是加号）split 出来是两个空片段，先换成具名 token。
				const text = spec.trim().toLowerCase().replace(/\+\+$/, "+plus");
				if (text === "") return null;
				const out = { key: "", cmd: false, shift: false, alt: false, ctrl: false };
				for (const part of text.split("+")) {
					const modifier = SPEC_MODIFIERS[part];
					if (modifier) { out[modifier] = true; continue; }
					if (out.key !== "") return null; // 两个非修饰符 = 写错了
					const named = Object.prototype.hasOwnProperty.call(SPEC_KEYS, part) ? SPEC_KEYS[part] : null;
					if (named === null && part.length !== 1) return null;
					out.key = named === null ? part : named;
				}
				return out.key === "" ? null : out;
			} catch {
				return null;
			}
		}

		/**
		 * 按"空串 = 禁用、解析失败 = 退默认"的语义读一条 spec。
		 * @param {unknown} value 设置里的值
		 * @param {string} fallback 解析失败时的默认 spec
		 * @returns {ReturnType<typeof parseKeySpec>} null = 不匹配任何键
		 */
		function readKeySpec(value, fallback) {
			// **空串是用户的明确意愿，不是坏值**：不能退回默认，否则关不掉。
			if (typeof value === "string" && value.trim() === "") return null;
			return parseKeySpec(value) || parseKeySpec(fallback);
		}

		/**
		 * 事件是否命中 spec。四个修饰符**逐项相等**（不是"包含"）：`esc` 只该在
		 * 光秃秃的 Esc 上生效，⌘Esc 不算。
		 *
		 * 注意 shift 的老问题：按住 shift 时浏览器报的 `event.key` 是上档字符
		 * （`]` → `}`），所以页面侧的 spec 别带 shift 加符号键。壳那半边解析的是
		 * 菜单快捷键，走 AppKit 自己的键位等价物，没有这个坑。
		 * @param {KeyboardEvent} event
		 * @param {ReturnType<typeof parseKeySpec>} spec
		 * @returns {boolean}
		 */
		function matchesKeySpec(event, spec) {
			if (!spec) return false;
			if (event.metaKey !== spec.cmd) return false;
			if (event.shiftKey !== spec.shift) return false;
			if (event.altKey !== spec.alt) return false;
			if (event.ctrlKey !== spec.ctrl) return false;
			const key = typeof event.key === "string" ? event.key : "";
			// 单字符大小写不敏感（`a` 与 shift 无关时 event.key 就是 "a"）；
			// 具名键（"Escape"）本来就是固定拼写，原样比。
			if (key.length === 1 && spec.key.length === 1) return key.toLowerCase() === spec.key;
			return key === spec.key;
		}

		/**
		 * 平坦对象的浅比较——键位表就是一层 string，够用。
		 * @param {Record<string, unknown> | null | undefined} a
		 * @param {Record<string, unknown> | null | undefined} b
		 * @returns {boolean}
		 */
		function sameKeymap(a, b) {
			if (a === b) return true;
			if (!a || !b) return false;
			const keys = Object.keys(a);
			if (keys.length !== Object.keys(b).length) return false;
			for (const key of keys) { if (a[key] !== b[key]) return false; }
			return true;
		}

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

			// 「停止生成」当前生效的键位。设置缺席就一直是默认的 Esc。
			let stopSpec = parseKeySpec(STOP_DEFAULT);

			// 键位表投影：settings（dsh 权威）→ 壳的主菜单。
			//
			// 走页内桥而不是桥的 app 通道：`announce` 明确"不为后来者留底"（那是构建
			// 事件的语义），而键位表是**状态**。页面的生命周期天然解决补发——壳重启 =
			// WebView 重载 = 本文件重跑 = 重新投影，一个 sticky 机制都不用加。
			// 桥协议也一个字不加：页内桥不设白名单，壳把任意 type 广播成
			// `clam.page.<type>`，这里发的 `keymap` 到那边就是 `clam.page.keymap`。
			//
			// **原样转交，不在这儿解析**：除 stopGenerating 外的每一条都归壳解析
			// （菜单是壳的），页面认识的键位越少，两边分家的机会越少。
			//
			// settingsScope 缺席（远程浏览器的设置 RPC 只走 loopback，那边永远缺席）
			// = 永远不推，壳一直用自带的默认键位表——**退化，不是故障**。
			try {
				ctx.inject(["settingsScope"], (kctx) => {
					try {
						const scope = kctx.settingsScope.bind({ namespace: SHORTCUTS_NS });
						let lastValues = null;
						const sync = () => {
							try {
								const snap = scope.getSnapshot();
								// `loading` / `unavailable` 时 value 还没有意义，什么都不做——
								// 推一份半成品比不推糟：壳会拿它盖掉正确的默认表。
								if (!snap || snap.status !== "ready") return;
								const values = snap.value;
								if (!values || typeof values !== "object") return;
								if (sameKeymap(values, lastValues)) return;
								lastValues = values;
								// Esc 那条自己留下，其余整份交给壳。
								stopSpec = readKeySpec(values.stopGenerating, STOP_DEFAULT);
								postToShell({ type: "keymap", values });
							} catch { /* 读取失败静默 */ }
						};
						kctx.effect(() => scope.subscribe(sync), "clam-layout: keymap 投影");
						sync();
					} catch { /* 服务形状不符静默 */ }
				});
			} catch { /* ctx.inject 不可用静默 */ }

			// 语言投影：dsh 的 locale（**页面解析后的 active**）→ 壳与原生插件。
			//
			// **订 `locale` 而不是 settings 里那个 `preference`**：`preference`
			// 缺省时的取值是浏览器推导（navigator.languages 的 primary subtag），
			// 只有页面侧算得准。不变量是"原生 UI 的语言 == 页面显示的语言"，
			// 所以两半必须读同一个解析结果，而不是各自解析同一份原始设置。
			//
			// 通道与补发同 keymap：走页内桥（壳把任意 type 广播成
			// `clam.page.<type>`），页面生命周期天然解决补发——壳重启 = WebView
			// 重载 = 本文件重跑 = 重新投影。壳那边再转成粘性总线主题，
			// 因为插件比页面装载得晚（见 ClamEventBus.emitSticky）。
			//
			// locale 服务缺席 = 永远不推，壳一直用自己那条决议链（缓存 → 系统语言
			// → en）——**退化，不是故障**。
			try {
				ctx.inject(["locale"], (lctx) => {
					try {
						const locale = lctx.locale;
						if (!locale || typeof locale.getSnapshot !== "function") return;
						let lastActive = null;
						const syncLocale = () => {
							try {
								const active = locale.getSnapshot()?.active;
								// 词典注册也会 bump revision 叫一遍订阅者，绝大多数
								// 通知里语言根本没变——同值不重推，省掉壳那边一轮
								// 缓存写入与广播。
								if (typeof active !== "string" || active === "" || active === lastActive) return;
								lastActive = active;
								postToShell({ type: "locale", locale: active });
							} catch { /* 读取失败静默 */ }
						};
						if (typeof locale.subscribe === "function") {
							lctx.effect(() => locale.subscribe(syncLocale), "clam-layout: locale 投影");
						}
						syncLocale();
					} catch { /* 服务形状不符静默 */ }
				});
			} catch { /* ctx.inject 不可用静默 */ }

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
						// Esc → 停止当前会话正在生成的回复（语义对齐 Claude Code 桌面版）。
						// 键位可改（设置 `clam-shortcuts.stopGenerating`，上面那段投影
						// 顺手把它解析进 stopSpec）；**空串 = 关掉**，那时 stopSpec 是
						// null，监听照常装着但一个键都不拦——比按条件装卸监听简单，
						// 也就不会在设置来回改时漏掉一次卸载。
						// dsh 页面自己没绑这条：全量查过它的 keydown，Escape 只用来关
						// 浮层/对话框，没有一处碰 stop。走停止按钮同款的服务路径
						// （scoped conversation.cancel，见 ui-conversation InputBar 的
						// stop 回调），不去点 DOM 按钮——按钮的类名 `_primary` 发送/停止
						// 共用，靠 aria-label 认按钮会跟着语言设置断。
						// 三道闸：生成中才拦（byId[current].running；对 idle 会话 cancel
						// 会 reject 并落进 promptError，等于凭空报错）；有浮层开着时 Esc
						// 归它们（关闭优先）；别人已 preventDefault 的不碰。
						// capture 相 + 不 preventDefault：焦点在 composer 里时它自己的
						// Escape（dismissPopup）照常走，两边各干各的。
						if (sessions && typeof sessions.scope === "function"
							&& sessions.list && typeof sessions.list.getSnapshot === "function") {
							const escStop = (event) => {
								try {
									if (event.defaultPrevented) return;
									if (!matchesKeySpec(event, stopSpec)) return;
									if (document.querySelector('[role="dialog"], [role="menu"], [role="listbox"]')) return;
									const snap = sessions.list.getSnapshot();
									const id = snap.current;
									if (id === undefined || !snap.byId?.[id]?.running) return;
									const scoped = sessions.scope(id);
									const conversation = scoped && typeof scoped.get === "function"
										? scoped.get("conversation") : undefined;
									if (conversation && typeof conversation.cancel === "function") {
										// 失败 reject 会同时落到 promptError，页面自己会展示。
										conversation.cancel().catch(() => { /* 静默 */ });
									}
								} catch { /* 静默 */ }
							};
							sctx.effect(() => {
								document.addEventListener("keydown", escStop, true);
								return () => document.removeEventListener("keydown", escStop, true);
							}, "clam-layout: esc-stop");
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
