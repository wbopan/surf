/*
 * clam-header，浏览器半边（lazy-CJS 经典脚本，手写、无构建步骤）。
 *
 * 干三件事，全部围绕**内置 header 那条 tabs 行**：
 *
 * 1. **投影**：把 `[role="tab"]` 的名单与选中态报给壳（`headerTabs` 页内消息）。
 * 2. **驱动**：装 `window.__clamHeader.setView(index)`，原生段控点了就派发
 *    一次 click 到对应按钮。
 * 3. **折叠**：原生侧确认接管之后，才把 tabs 行压成零高度。
 *
 * ## 为什么是 DOM 而不是服务
 *
 * active view 住在 ui-conversation 的**私有** chat store 里，写入口 `setView`
 * 全仓只有三处、全在该包内部（`dsh-client-ui-conversation/lib/client.js` 的
 * 38 / 7385 / 10198）。store handle 是它 `apply` 里的局部变量，`ctx.conversation`
 * 服务面一个 view 成员都没有，而框架发给 session 域槽的标准件只有
 * `useSession`（runtime 的 ConversationSnapshot）/ `sessionId` / `useProjection`
 * ——`view` 不在其中。第三方自己声明 `store: createChatStore` 只会被框架
 * 铸一个 per-entry handle（新实例），写进去那边读不到。
 *
 * 也别去写它的 localStorage（`persist: "dsh.conversation.chat"` 确实在）：
 * rehydrate 只发生在实例创建时，外部写不会即时生效。那是陷阱不是通道。
 *
 * 于是只剩 DOM 一条路，而 DOM 这条路是**实测通的**：把 tablist 压成
 * `height:0; pointer-events:none` 之后，`dispatchEvent('click')` 照样翻转
 * `aria-selected` 并真的切换视图（程序化派发不走 hit-testing）。
 *
 * ## 锚点
 *
 * 用 `[data-slot="conversation.session.header"]`——**槽系统给每个 outlet 挂的
 * 一等属性**（值就是槽名，`display:contents` 不影响布局），比 hash 化的 CSS
 * module 类名和 `[data-phase]` 这种间接关系都稳。header 元素是它的**第一个子
 * 元素**，不是 `[data-phase]` 的直接子元素——中间隔着这层 outlet。
 *
 * ## 折叠要等原生点头
 *
 * `data-clam-native-header` 属性不是发现 tablist 就加，而是等 Swift 半身收到
 * 投影、画好段控、回调 `confirmNative()` 之后才加。这样"原生侧缺席"
 * （插件编译失败、壳是旧版、根本没装）的退化结果是**网页 header 原样露出**，
 * 而不是标题栏和页面各画一半。
 *
 * 门控：UA 含 "Clam/" 且 URL 带 clam-native-sidebar=1，与 clam-layout 同款。
 */
window.__ModuleLoader__.load({
	id: "@wenbo/clam-header",
	factory: () => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });

		const STYLE_ID = "clam-header-style";
		const NATIVE_ATTR = "data-clam-native-header";
		/** 折叠范围：`tabs` 只折视图标签那一行，`full` 折整条 header。 */
		const SCOPE_ATTR = "data-clam-header-scope";
		/** full 模式下补给滚动容器的顶部留白（px），由原生实测后传下来。 */
		const INSET_VAR = "--clam-header-inset";
		/** header 槽 outlet 的选择器。槽名是槽系统的一等身份，不会随 CSS 改。 */
		const HEADER_SEAT = '[data-slot="conversation.session.header"]';
		/** 巡检周期。与 clam-layout 的守护同一个节奏。 */
		const PATROL_MS = 500;

		/**
		 * 每次 effect 启动生成的实例 token，写进全局状态当所有权标记。
		 * client 半边 HMR 的重载顺序是「新实例先启、旧实例后清」，无条件清理
		 * 会让后跑的旧 cleanup 砍掉新实例刚装好的东西。
		 * @returns {string}
		 */
		function makeToken() {
			try { return "dh" + Math.random().toString(36).slice(2, 10); } catch { return "dh0"; }
		}

		function insideClam() {
			try { return navigator.userAgent.includes("Clam/"); } catch { return false; }
		}

		function nativeMode() {
			try {
				return insideClam()
					&& new URLSearchParams(window.location.search).get("clam-native-sidebar") === "1";
			} catch { return false; }
		}

		/**
		 * 经 window.webkit.messageHandlers.clam 向壳发消息；普通浏览器静默跳过。
		 * 壳对未知 type 一律广播成 `clam.page.<type>`（去白名单后的通用转发），
		 * 所以这里加一条新消息**不需要改壳**。
		 * @param {Record<string, unknown>} msg
		 */
		function postToShell(msg) {
			try {
				const handler = window.webkit && window.webkit.messageHandlers
					&& window.webkit.messageHandlers.clam;
				if (handler && typeof handler.postMessage === "function") handler.postMessage(msg);
			} catch { /* 上报失败静默 */ }
		}

		/** header 槽 outlet 里那个 `<header>`（outlet 是 display:contents 的包装层）。 */
		function pickHeader() {
			try {
				const seat = document.querySelector(HEADER_SEAT);
				const el = seat && seat.firstElementChild;
				return el instanceof HTMLElement && el.tagName === "HEADER" ? el : null;
			} catch { return null; }
		}

		/** 当前的 tab 按钮（DOM 顺序即 view 顺序）。找不到返回空数组。 */
		function pickTabs(header) {
			try {
				const list = header && header.querySelector('[role="tablist"]');
				return list ? [...list.querySelectorAll('[role="tab"]')] : [];
			} catch { return []; }
		}

		/**
		 * 读一份 tabs 投影。
		 *
		 * **按下标认人，不按 id**：DOM 里根本没有 view id，只有本地化过的 label
		 * （`viewTab.label`）。按 label 匹配等于把 i18n 变成正确性依赖，
		 * 而投影与驱动共用下标，DOM 顺序就是唯一的对齐基准。
		 *
		 * `present` 跟随内置 header 自己的隐藏规则（空会话时它挂 headerHidden +
		 * aria-hidden），否则新建会话时标题栏上会挂着上一个会话的 tab。
		 * @returns {{tabs: string[], active: number, present: boolean}}
		 */
		function readProjection() {
			const header = pickHeader();
			const hidden = header === null || header.getAttribute("aria-hidden") === "true";
			const buttons = hidden ? [] : pickTabs(header);
			return {
				tabs: buttons.map((b) => (b.textContent || "").trim()),
				active: buttons.findIndex((b) => b.getAttribute("aria-selected") === "true"),
				// tabs 少于 2 个时内置 header 自己就不渲染 tablist，原生跟着藏。
				present: !hidden && buttons.length > 1,
				// 导出按钮在不在（原生那一格据此显示/隐藏）。它由
				// dsh-session-log-export 占 utilities 槽提供，装没装是部署的事。
				canExport: !hidden && pickExportButton() !== null,
			};
		}

		function sameProjection(a, b) {
			return a !== undefined && a.present === b.present && a.active === b.active
				&& a.canExport === b.canExport
				&& a.tabs.length === b.tabs.length && a.tabs.every((t, i) => t === b.tabs[i]);
		}

		/**
		 * 导出按钮（`Session log`）。它是 dsh-session-log-export 占
		 * `conversation.session.header.utilities` 槽放进去的，槽名是它的一等身份。
		 *
		 * **为什么点它而不自己拼 URL**：那边的 `run()` 会先 HEAD 探一次、
		 * 按会话 id 生成文件名、失败时在页面上给提示。自己拼
		 * `/api/session.export?sessionId=…&includeDescendants=true` 等于把这三样
		 * 重新实现一遍，还会和上游漂移。而且导出是**纯动作、无浮层**，
		 * 正好符合"DOM 驱动只用于即时生效、无浮层的控件"这条纪律
		 * （mode 那种带下拉的就不能这么干，浮层会锚到零尺寸元素上）。
		 * @returns {HTMLElement | null}
		 */
		function pickExportButton() {
			try {
				const seat = document.querySelector(
					'[data-slot="conversation.session.header.utilities"]');
				return seat ? seat.querySelector("button") : null;
			} catch { return null; }
		}

		/**
		 * 投影通道：常驻巡检 + MutationObserver。
		 *
		 * **observer 必须常驻并每轮比对节点身份**：header 是 React 组件，
		 * root entry 重注册会把它整个换成新节点，绑死旧节点的 observer 就此
		 * 永久失效（与 clam-layout 的 forceSidebarCollapsed 同一个坑）。
		 * @returns {{stop: () => void, resync: () => void}} 停止与强制重报
		 */
		function trackTabs() {
			let observer = null;
			let observed = null;
			let last;
			const sync = () => {
				const header = pickHeader();
				if (header !== observed) {
					observer?.disconnect();
					observed = header;
					if (header !== null) {
						observer = new MutationObserver(sync);
						// childList：切会话/换 view 会重建 tablist 子树。
						// attributes：aria-selected 与 aria-hidden 就地翻。
						observer.observe(header, {
							subtree: true, childList: true,
							attributes: true, attributeFilter: ["aria-selected", "aria-hidden"],
						});
					}
				}
				const next = readProjection();
				if (sameProjection(last, next)) return;
				last = next;
				postToShell({ type: "headerTabs", ...next });
			};
			const timer = setInterval(sync, PATROL_MS);
			sync();
			return {
				stop: () => { clearInterval(timer); observer?.disconnect(); },
				// 强制重报：Swift 半身**每装一代**都要一份开局投影，而它换代时
				// client 这边可能早就报完、去抖住了。与 clam-sidebar 的 `snapshot`
				// 动作同一条纪律——**不给新世代补发，由请求方自己要**。
				resync: () => { last = undefined; sync(); },
			};
		}

		/**
		 * 折叠样式。只折 tabs 那一行，titleRow 原样留着——面包屑、
		 * `…header.actions`、`…header.utilities` 三个子槽的内容因此一条不丢，
		 * jobs 那种带浮层的控件也不受影响（锚到零尺寸元素上位置会错）。
		 * @returns {HTMLStyleElement}
		 */
		function installStyle() {
			document.getElementById(STYLE_ID)?.remove();
			const style = document.createElement("style");
			style.id = STYLE_ID;
			// 折叠共用的一组声明。**绝不用 display:none**：那样元素不参与布局，
			// 但更要紧的是保持挂载——按钮还在 DOM 里才派发得了 click
			// （零高度 + pointer-events:none 下 dispatchEvent 照常触发，实测过）。
			const collapse = [
				"  height: 0 !important;",
				"  min-height: 0 !important;",
				"  margin: 0 !important;",
				"  padding: 0 !important;",
				"  border: 0 !important;",
				"  overflow: hidden !important;",
				"  opacity: 0 !important;",
				"  pointer-events: none !important;",
			];
			style.textContent = [
				// scope=tabs：只折视图标签那一行，titleRow 原样留着。
				// 面包屑 / actions / utilities 三个子槽的内容因此一条不丢。
				"html[" + SCOPE_ATTR + '="tabs"] ' + HEADER_SEAT + ' [role="tablist"] {',
				...collapse,
				"}",
				// scope=full：整条 header 收掉（原生已经接管了里面每一样东西）。
				"html[" + SCOPE_ATTR + '="full"] ' + HEADER_SEAT + " > header {",
				...collapse,
				"}",
				// full 模式下正文会顶到窗口最上沿、被工具栏盖住。补一段顶部留白，
				// 高度由原生实测 `contentLayoutGuide` 后传下来（硬编码会在
				// 工具栏样式或系统版本变化时错位）。
				"html[" + SCOPE_ATTR + '="full"] [data-conversation-scroll] {',
				"  padding-top: var(" + INSET_VAR + ", 0px) !important;",
				"}",
				// 工具栏底下那条带子。**必须由页面画**，原生三条路全试过：
				// `titlebarAppearsTransparent = false` 给的是**不透明**背景，模糊没了；
				// `NSVisualEffectView` **采不到** WKWebView 那层 remote layer 的像素
				// （和 NSGlassEffectView 并排实测，它完全不生效）；
				// `NSGlassEffectView` 采得到，但自带一圈边缘高光，关不掉。
				//
				// 系统那条 scroll edge effect 也召唤不到，而且它本来就不是一条带子：
				// 载体是私有的 `NSScrollPocket`，由滚动内容视图自己画，Apple 的原话是
				// 效果"applied underneath toolbar items"、形状"varies based on the
				// content floating above it"——**形状跟着浮元素走**。给它一个真实可见、
				// 滚到 2600 的 NSScrollView 也一样：条纹原样穿过带子，只有工具栏胶囊
				// 底下被糊。`obscuredContentInsets` 那条公开路造得出 pocket，但风格默认
				// 是纯色（Soft 要 SPI），且只认**主 frame** 滚动——dsh 滚的是内层 div。
				//
				// 所以 `backdrop-filter` 不是退而求其次：它与正文同处一个渲染上下文，
				// **页面 compositor 是唯一看得见内层滚动的东西**。
				//
				// 用 `::before` 而不是插一个 div：它跟着 `padding-top` 那条规则
				// 同生同灭，不需要另一套 DOM 生命周期。`position: fixed` 让它
				// 逃出滚动容器的裁剪，锚在视口顶上不动。
				"html[" + SCOPE_ATTR + '="full"] [data-conversation-scroll]::before {',
				'  content: "";',
				"  position: fixed;",
				"  top: 0; left: 0; right: 0;",
				"  height: var(" + INSET_VAR + ", 0px);",
				// 细线算在留白之内，否则带子会比标题栏高出 1px。
				"  box-sizing: border-box;",
				"  z-index: 10;",
				"  pointer-events: none;", // 底下的正文照样可点、可选
				"  -webkit-backdrop-filter: blur(8px) saturate(180%);",
				"  backdrop-filter: blur(8px) saturate(180%);",
				// **滚动时的闪烁是 backdrop-filter 自带的**（WebKit 89475 /
				// Chromium 339841685 / Firefox 1418923 三家都开着 bug）：每帧都要
				// 重新快照背后的内容再模糊，合成时序一抖边缘就"缺料"，内容**滑过
				// 细线时最明显**——而 dsh 正文全是细线。`will-change` 把它提成
				// 独立合成层，能压掉大部分抖动。
				// **只提 transform、不写 `translateZ(0)`**：真加一个 3D 变换会让
				// 元素不再是可合成的 2D 平面，backdrop-filter 直接失效。
				"  will-change: transform;",
				// 底色跟着 dsh 自己的页面底色走，深浅色自动切换。
				"  background: color-mix(in srgb, var(--dsw-alias-bg-base, #fff) 55%, transparent);",
				// 底边那条 hairline：走 dsh 的边框色，深浅色自动跟随。
				// **不配 mask 软收**——两者互斥（mask 会把线一起淡掉），
				// 而有线的硬边本来就更像原生工具栏。
				"  border-bottom: 1px solid var(--dsw-alias-border-l2, rgba(0, 0, 0, 0.08));",
				"}",
			].join("\n");
			document.head.appendChild(style);
			return style;
		}

		/**
		 * 一对 id 的两种形态：原样，以及"另一种前缀"。
		 * 上游的规范形是 `session-<uuid>`，但 `session.list` 里的 subagent 行
		 * 实测有时是光 uuid，所以谁也别假定——两种都试。
		 */
		function idCandidates(parentId, childId) {
			const forms = (id) => {
				const raw = String(id ?? "");
				if (raw === "") return [];
				const bare = raw.startsWith("session-") ? raw.slice("session-".length) : raw;
				return bare === raw ? [raw, "session-" + raw] : [raw, bare];
			};
			const parents = forms(parentId);
			const children = forms(childId);
			const pairs = [];
			// **笛卡尔积，不是同步翻转**。实测上游的形态是混合的：
			// `subagents.list` 要 parent 带 `session-` 前缀，而它 catalog 里
			// 的 child 是光 uuid。同步翻转两个恰好把唯一正确的组合跳过去，
			// 症状是"两种都试过了，两种都被拒"。
			for (const parent of parents) for (const child of children) pairs.push([parent, child]);
			return pairs;
		}

		/**
		 * 插件体。
		 * @param {import('@deepseek-ai/cordis').Context} ctx
		 */
		function apply(ctx) {
			if (!nativeMode()) return;

			ctx.effect(() => {
				const token = makeToken();
				const style = installStyle();

				/**
				 * `sessions` 服务，**导航专用**（见下面 openSubagent）。
				 *
				 * 三件事照 clam-layout 的 `installBridge` 办，每一条都是踩过的：
				 *
				 * 1. **走作用域 `ctx.inject` 而不是 `exports.inject`**：顶层 inject
				 *    会让整个插件在服务缺席时不挂载，而缺 `sessions` 只该让"点
				 *    catalog 一行"失效，tabs / 折叠 / 导出不该跟着消失。
				 * 2. **包 try**：`ctx.inject` 自己会抛（实测过——裸调一次，
				 *    整个 apply 挂掉，页面上连 `window.__clamHeader` 都没有，
				 *    症状是原生这边所有页面调用回执 `no-bridge`）。
				 * 3. **装在 effect 内部**：每代重装。沿用上一代的服务句柄等于留一个
				 *    fiber 已卸载的僵尸接线。
				 */
				let sessionsService = null;
				try {
					ctx.inject(["sessions"], (scope) => {
						sessionsService = scope?.sessions ?? null;
						return () => { sessionsService = null; };
					});
				} catch { /* 没有这个服务：导航失效，其余照常 */ }
				const tracker = trackTabs();
				const root = document.documentElement;
				/** 见过的最大原生世代号（见 confirmNative 的「世代闸门」）。 */
				let lastGeneration = -1;

				/** 原生点了段控：按下标派发一次 click。 */
				const setView = (index) => {
					try {
						const buttons = pickTabs(pickHeader());
						const target = buttons[Number(index)];
						// 已经是选中态就别派发：省一次 React 往返，也避免抖动。
						if (target && target.getAttribute("aria-selected") !== "true") target.click();
					} catch { /* DOM 不符静默 */ }
				};

				/** 点一下网页那个导出按钮（见 pickExportButton 的注释）。 */
				const exportSession = () => {
					try { pickExportButton()?.click(); } catch { /* DOM 不符静默 */ }
				};

				/**
				 * 打开一个子代理会话——原生 catalog 选中一行时调。
				 *
				 * **为什么走这里而不是 node 半边**：`openSubagent` 是 client
				 * runtime 的服务（`ctx.sessions`），路由状态住在浏览器进程里，
				 * node 侧没有对应物。上游 ui-subagent 的注册处也是这么接的：
				 * `openChild(address) { sessions.openSubagent(address); }`。
				 *
				 * 树的数据来自 node 半边、导航动作走这里——**与本插件既有的
				 * 两通道判据一致**：看这个事实的真相住在哪个进程。
				 *
				 * id 形态两边可能不一致（`session.list` 里 subagent 行有时是光
				 * uuid，node 半边统一补了 `session-` 前缀），所以两种形态各试
				 * 一次，谁不抛错算谁。
				 */
				/**
				 * **预热一个父会话的 catalog。**
				 *
				 * 这一步不是可选的优化——`openSubagent` 内部会校验目标是不是
				 * "healthy catalog child"，而它认的是 client runtime 自己那份
				 * `subagentsByParent`。没让它拉过 `subagents.list` 就直接导航，
				 * 一律被挡：
				 *
				 * ```
				 * sessions.selectSubagent: <id> is not a healthy catalog child
				 * ```
				 *
				 * （实测，两种 id 形态都挡。）所以上游 `setCatalogOpen` 的真正
				 * 作用不止是"上报可见分支做去抖刷新"，它还是**导航的前提**。
				 * 原生 catalog 一打开就调这里，用户从 hover 到点击的这几百毫秒
				 * 正好够那趟 RPC 回来。
				 */
				const primeCatalog = (parentSessionId) => {
					const service = sessionsService;
					if (service === null) return "no-service";
					// 两种 id 形态都预热：多打一趟 RPC 是无害的，猜错则整条路不通。
					for (const [parent] of idCandidates(parentSessionId, parentSessionId)) {
						try { service.setSubagentCatalogOpen?.(parent, true); } catch { /* 没有这个方法 */ }
						try { service.refreshSubagents?.(parent); } catch { /* 同上 */ }
					}
					return "ok";
				};

				/** 关掉 catalog 时松开上报，别让 runtime 一直为它做去抖刷新。 */
				const releaseCatalog = (parentSessionId) => {
					const service = sessionsService;
					if (service === null) return "no-service";
					for (const [parent] of idCandidates(parentSessionId, parentSessionId)) {
						try { service.setSubagentCatalogOpen?.(parent, false); } catch { /* 同上 */ }
					}
					return "ok";
				};

				/**
				 * 让 runtime 自己交出权威地址。
				 *
				 * `subagentAddress(id)` 返回的是 runtime **已经从 catalog 认下来的**
				 * `{parentSessionId, childSessionId, mode}`，比我们照着 `session.list`
				 * 拼一个强得多：id 形态、mode 都不用猜。拿到就直接喂回
				 * `openSubagent`，那道 "healthy catalog child" 校验必然通过。
				 *
				 * 它只在 catalog 已经加载过之后才有值——所以拿不到不等于失败，
				 * 而是"还没热"，见 openSubagent 的第二段。
				 */
				const resolveAndOpen = (service, childSessionId) => {
					if (typeof service.subagentAddress !== "function") return null;
					for (const [child] of idCandidates(childSessionId, childSessionId)) {
						try {
							const address = service.subagentAddress(child);
							if (address === undefined || address === null) continue;
							service.openSubagent(address);
							return "ok:" + child;
						} catch (error) {
							window.__clamHeaderLastError = String(error && error.message ? error.message : error);
						}
					}
					return null;
				};

				/** 自己拼地址试一遍（runtime 没认下来时的兜底）。 */
				const tryOpen = (service, parentSessionId, childSessionId, kind) => {
					const notes = [];
					for (const [parent, child] of idCandidates(parentSessionId, childSessionId)) {
						try {
							service.openSubagent({ parentSessionId: parent, childSessionId: child, mode: kind });
							return { ok: true, note: "ok:" + child };
						} catch (error) {
							notes.push(String(error && error.message ? error.message : error));
						}
					}
					return { ok: false, note: notes.join(" | ") };
				};

				/**
				 * 打开一个子代理会话。**两段式**：
				 *
				 * 1. catalog 已经热了（popover 打开时预热过）→ 让 runtime 交出权威
				 *    地址，同步完成。
				 * 2. 还没热 → `await refreshSubagents(parent)`（它返回 Promise，
				 *    这是唯一可靠的"加载完了"信号；盲等固定毫秒数不行），回来再走
				 *    第 1 步，仍不行才自己拼地址兜底，全败则把理由经页内桥报上去。
				 *
				 * 同步返回值只说"这一轮的结论"，异步那段的失败经 `headerDiag` 上报
				 * ——静默失败等于骗人，而这是用户刚点过的东西。
				 */
				const openSubagent = (parentSessionId, childSessionId, mode) => {
					const service = sessionsService;
					if (service === null) return "no-service";
					if (typeof service.openSubagent !== "function") {
						return "no-method:" + Object.keys(service).slice(0, 12).join(",");
					}
					const kind = mode === "one-shot" || mode === "continuable" ? mode : "continuable";

					const direct = resolveAndOpen(service, childSessionId);
					if (direct !== null) return direct;

					const parents = idCandidates(parentSessionId, parentSessionId).map(([p]) => p);
					const refreshes = parents.map((parent) => {
						try {
							const value = service.refreshSubagents?.(parent);
							return value && typeof value.then === "function"
								? value.catch(() => undefined) : Promise.resolve();
						} catch (error) { return Promise.resolve(); }
					});
					Promise.all(refreshes).then(() => {
						if (resolveAndOpen(service, childSessionId) !== null) return;
						const fallback = tryOpen(service, parentSessionId, childSessionId, kind);
						if (fallback.ok) return;
						postToShell({
							type: "headerDiag",
							text: "openSubagent 失败（catalog 刷新后仍不认）：" + fallback.note,
						});
					});
					return "ok:refreshing";
				};

				/**
				 * 原生侧确认接管了才折叠（见模块注释「折叠要等原生点头」）。
				 *
				 * `scope` 是**渐进的**：原生只画出了视图段控就传 `"tabs"`，
				 * 面包屑 / mode / 导出 也都画出来了才传 `"full"`。这样"数据面
				 * 没起来"的退化结果是网页那条 titleRow 还在（面包屑和导出没丢），
				 * 而不是一条空标题栏。传 `"none"` 或 false 则完全撤销。
				 *
				 * `inset` 是 full 模式下补给正文的顶部留白（px），原生实测
				 * `contentLayoutGuide` 后给的。
				 *
				 * Swift 半身每装一代都会重新调一次——世代替换后新一代确认，
				 * 折叠不会因为换代而中断。
				 */
				const confirmNative = (scope, inset, generation) => {
					try {
						const gen = typeof generation === "number" ? generation : 0;
						// **世代闸门**：Swift 插件换代时，旧一代的析构会跟着喊一声撤销，
						// 而新一代早就把折叠设好了——无条件执行就等于替新一代把自己的
						// 折叠摘掉（症状：热替换后网页 header 突然冒出来）。只认
						// 世代号不小于已知最新的那一声。
						// 这与本文件的实例 token 是两套独立的闸门：token 挡的是
						// client 半边自己的 HMR，这里挡的是原生半边的换代。
						if (gen < lastGeneration) return;
						lastGeneration = gen;
						const next = scope === true ? "tabs"
							: (scope === "tabs" || scope === "full") ? scope : "none";
						if (next === "none") {
							if (root.getAttribute(NATIVE_ATTR) === token) {
								root.removeAttribute(NATIVE_ATTR);
								root.removeAttribute(SCOPE_ATTR);
								root.style.removeProperty(INSET_VAR);
							}
							return;
						}
						root.setAttribute(NATIVE_ATTR, token);
						root.setAttribute(SCOPE_ATTR, next);
						if (typeof inset === "number" && inset >= 0) {
							root.style.setProperty(INSET_VAR, Math.round(inset) + "px");
						}
						// 原生说「我接管了」，就把当前状态报一遍给它开局。
						tracker.resync();
					} catch { /* 静默 */ }
				};

				window.__clamHeader = {
					setView, exportSession, openSubagent, primeCatalog, releaseCatalog,
					confirmNative, __clamToken: token,
				};
				// 壳可能早就连上了：告诉原生侧「我这一代起来了，重新报一次」。
				postToShell({ type: "headerReady" });

				return () => {
					tracker.stop();
					style.remove();
					try {
						// 所有权检查（见 makeToken）：新实例可能已经接管。
						if (root.getAttribute(NATIVE_ATTR) === token) {
							root.removeAttribute(NATIVE_ATTR);
							root.removeAttribute(SCOPE_ATTR);
							root.style.removeProperty(INSET_VAR);
						}
						if (window.__clamHeader && window.__clamHeader.__clamToken === token) {
							delete window.__clamHeader;
						}
					} catch { /* 静默 */ }
				};
			});
		}

		exports.apply = apply;
		// 零服务依赖：全部走 DOM 与页内桥，不 inject 任何 dsh 服务。
		exports.inject = [];
		return module.exports;
	}
});
