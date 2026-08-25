/*
 * dash-nativeify，浏览器半边（lazy-CJS 经典脚本，手写、无构建步骤）。
 *
 * **职责边界**：只做「让 dsh Web UI 摸起来像原生 macOS App」这一件事，
 * 全部实现是注入一段 CSS，零服务依赖、零跨插件契约：禁掉 document 橡皮筋、
 * UI 文本不可选中（输入框与会话消息流除外）、实体按钮的按压手感、
 * 字体收到 macOS 原生度量（两个旋钮：CONTROL 管控件、BODY 管对话阅读列，
 * 见下面「原生字体度量」的实测表）。
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

		/**
		 * 「实体按钮」白名单——按钮原生化只作用于这些。
		 *
		 * 判据（与 macOS 的分野一致）：**normal 态自己画了背景色或边框的才算按钮**，
		 * 全透明的只是"可点的图标"，不该有按压形变，就像 Finder 工具栏的按钮有玻璃
		 * 底、而列表行里的展开箭头没有。实测 dsh 0.1.1-rc.2 的 26 个可点元素：
		 *
		 *   实体（在册）      _primary 发送 · _sessionLogButton 下载 · _add 命令
		 *                    · _newSession 新建会话
		 *   幽灵（不在册）    _action 复制/点赞/点踩/分支 · _trigger 访问模式/模型/
		 *                    上下文 · _tab 对话轨迹 · _crumb 面包屑 · _iconButton
		 *                    · _searchButton · thinking 与重试折叠（那两个连
		 *                    <button> 都不是，是 DIV / SUMMARY）
		 *
		 * 为什么是白名单而不是「排除幽灵」的黑名单：两者的失效方向不同。dsh 改版后
		 * 白名单失配 = 效果消失（退回现状，无害）；黑名单失配 = 效果乱加到内联图标上
		 * （正是本次要修的毛病）。宁可漏，不可滥。
		 *
		 * 类名是 hash 化 CSS module（`uV2eYG_add`），hash 变、语义后缀稳，故用
		 * `[class*="_x"]` 命中。**新增实体按钮不会自动获得效果**，需要手工在此登记；
		 * 想知道有哪些漏网的，在页面控制台跑：
		 *   [...document.querySelectorAll('button')].filter(b => {
		 *     const c = getComputedStyle(b);
		 *     return !/,\\s*0\\)$/.test(c.backgroundColor) || parseFloat(c.borderTopWidth) > 0;
		 *   }).map(b => b.className)
		 */
		/**
		 * 白名单再分两组，差别只有一条：**要不要由我们画描边**。
		 *
		 * dsh 给一部分按钮自带了 `border: 1px rgba(0,0,0,.1)`，那一条的"墨量"
		 * （宽 × alpha = 1 × .1 = .1）本身就已经超过 macOS 整条玻璃描边（.33pt ×
		 * .21 = .069）。再叠一层 inset 描边，墨量翻到 .13 以上，肉眼就是"边黑了一圈"。
		 * 所以自带 border 的这组只上高光和暗带，描边交给 dsh 自己那条。
		 */
		const SOLID_BORDERED = [
			'button[class*="_sessionLogButton"]',  // 会话头部 Session log ⬇（1px border）
			'button[class*="_newSession"]',        // 侧边栏新建会话（白底 + 1px border）
		];
		const SOLID_PLAIN = [
			'button[class*="_primary"]',           // composer 发送键（实心强调色，无 border）
			'button[class*="_add"]',               // composer 命令 +（浅灰实底，无 border）
			// 会话流顶部「加载更早」。它是个裸 <button type="button">，自己一个 class
			// 都没有，只能从父容器 Md3f7G_older 捞——所以这条是唯一的结构选择器。
			'[class*="_older"] > button',
		];
		const SOLID_BUTTONS = SOLID_PLAIN.concat(SOLID_BORDERED);
		// 排除 dsh 自己的禁用态两种写法；:not() 链一次写好，供下面各态复用。
		const ENABLED = ':not(:disabled):not([aria-disabled="true"])';
		const join = (suffix) => SOLID_BUTTONS.map((s) => s + suffix).join(",\n");
		const joinPlain = (suffix) => SOLID_PLAIN.map((s) => s + suffix).join(",\n");
		const solid = join("");
		const solidPlain = joinPlain("");
		const solidSvg = join(" svg");
		const solidHover = join(ENABLED + ":hover");
		const solidActive = join(ENABLED + ":active");
		const solidActiveSvg = join(ENABLED + ":active svg");

		/**
		 * ===== 原生字体度量：两个旋钮 =====
		 *
		 * **数据是本机实测的，不是查来的**：`NSFont` + `NSLayoutManager.defaultLineHeight`，
		 * macOS 26。CSS px 与 AppKit pt 的等价性也是逐像素验过的——同一句中英混排，
		 * NSTextField 13pt 与 WKWebView 13px 的汉字墨高都是 26 设备 px（2x 屏），
		 * 16pt/16px 都是 32。所以下面的 px 可以和 pt 直接对读。
		 *
		 * 实测行高表（中英混排：CoreText 一行取各 run 的最大行高，中文 run 回退到
		 * PingFang SC，它比 SF 高得多——**所以常说的"原生行高倍数 1.23"对这个界面是
		 * 错的**，那只对纯拉丁成立）：
		 *
		 *   字号 | 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26
		 *   SF   | 12 13 15 16 17 18 18 20 21 22 23 24 26 27 28 29 30
		 *   PF   | 14 16 17 18 20 21 22 24 25 26 28 29 30 32 33 36 37
		 *   混排 | 14 16 17 18 20 21 22 24 25 26 28 29 30 32 33 36 37  ← NATIVE_LINE_HEIGHT
		 *
		 * ---
		 *
		 * **两个档位，别混为一谈**（第一版就是栽在这里）：
		 *
		 * `CONTROL = 13` —— `NSFont.systemFontSize`。菜单、工具栏、列表行、次级标签。
		 *   壳的原生侧边栏就是这一档，所以工具调用行/时间戳跟着它，两边才是同一套字。
		 *
		 * `BODY` —— 对话阅读列。**这里不是 systemFontSize，差得还很远。**
		 *   13pt 是 chrome 度量，不是阅读面度量；把它套到一列 700px 宽的长文上，
		 *   等于把邮件正文调成菜单栏字号。对照 macOS 27 的新 Siri App——同一代系统里
		 *   Apple 自己的对话面——消息文字明显在 17pt 一档，远高于 systemFontSize。
		 *   dsh 原本的 16px 其实离 Apple 的对话面不远，真正离谱的是它 28px 的行高
		 *   （1.75；16px 的原生行高是 22px）。所以这一层要做的是**收行高、不是砍字号**。
		 *
		 * 改字号只动 BODY 一个数，其余全部派生。
		 */
		const NATIVE_LINE_HEIGHT = {
			8: 11, 9: 13, 10: 14, 11: 16, 12: 17, 13: 18, 14: 20, 15: 21,
			16: 22, 17: 24, 18: 25, 19: 26, 20: 28, 21: 29, 22: 30, 23: 32,
			24: 33, 25: 36, 26: 37, 27: 38, 28: 40,
		};
		/** 取原生行高；表里没有的字号直接抛，逼着补测而不是随手算个倍数。 */
		const lh = (size) => {
			const v = NATIVE_LINE_HEIGHT[size];
			if (!v) throw new Error(`dash-nativeify: ${size}px 没有实测行高，先补测再用`);
			return v;
		};

		const CONTROL = 13;   // NSFont.systemFontSize：控件 / 工具调用行 / 次级标签
		const BODY = 15;      // 对话阅读列。改字号只动这一个数，其余全部派生。

		/**
		 * 标题阶梯 h1~h4。走 macOS 的语义档（largeTitle 26 / title1 22 / title2 17 /
		 * title3 15），取正文之上的四档；**h4 与正文同号、只差字重**——macOS 的层级
		 * 靠字重和颜色分，不靠字号跳变，这是原生做法。
		 * BODY 换档时这四个数要一起看，所以写在一起。
		 */
		const HEADINGS = BODY >= 16 ? [26, 22, 20, BODY] : [20, 17, 15, BODY];

		const NATIVE_FONT_FAMILY = "var(--dsw-font-family)";   // 别动：第一位已是 -apple-system
		const NATIVE_MONO_FAMILY = "var(--ds-font-family-code)";

		/**
		 * dsh 的 `--dsw-font-*` token → 原生度量。
		 *
		 * **为什么改 token 而不是改选择器**：dsh 全站零 rem（65KB 静态 CSS + 45 个插件
		 * 内联 CSS，`rem` 出现 0 次、`px` 3069 次），所以 `html { font-size }` 那种全局
		 * 等比缩放根本不成立。但 dsh 自己有一套完整的排版 token，其中 markdown 那一族
		 * 是高杠杆的——`._markdown` 一处声明就覆盖整个助手回复正文，h1~h4 / code /
		 * table 各一处。改 token 等于在 dsh 自己的语义层里说话：不碰任何类名、不打
		 * `!important`、深浅主题自动跟随、dsh 升级换 hash 也不受影响。
		 *
		 * 覆盖率诚实说：全站 309 条规则里只有 68 处用 token，其余是硬编码 px。硬编码
		 * 那部分见下面 FLOW_SCOPE 的注释。
		 *
		 * 每项 = [token 名, 字号, 字重(0=不指定即400), 斜体?, 字族]；行高一律查表。
		 */
		const TYPE_TOKENS = [
			// —— markdown 正文族：`._markdown` 及其子元素，助手回复的全部文字 ——
			//    字号维持在阅读档，收的是行高（dsh 16/28 → 17/24，倍数 1.75 → 1.41）。
			["markdown-base",                 BODY,       0, 0, NATIVE_FONT_FAMILY],
			["markdown-base-strong",          BODY,     600, 0, NATIVE_FONT_FAMILY],
			["markdown-base-italic",          BODY,       0, 1, NATIVE_FONT_FAMILY],
			["markdown-base-strong-italic",   BODY,     600, 1, NATIVE_FONT_FAMILY],
			//    次级正文降两档（dsh 自己也是 base 之下一档）。
			["markdown-small",                BODY - 2,   0, 0, NATIVE_FONT_FAMILY],
			["markdown-small-strong",         BODY - 2, 600, 0, NATIVE_FONT_FAMILY],
			["markdown-small-italic",         BODY - 2,   0, 1, NATIVE_FONT_FAMILY],
			["markdown-small-strong-italic",  BODY - 2, 600, 1, NATIVE_FONT_FAMILY],
			//    标题：见 HEADINGS。字重统一 600（macOS semibold），不是 dsh 的 700。
			["markdown-h1",                   HEADINGS[0], 600, 0, NATIVE_FONT_FAMILY],
			["markdown-h2",                   HEADINGS[1], 600, 0, NATIVE_FONT_FAMILY],
			["markdown-h3",                   HEADINGS[2], 600, 0, NATIVE_FONT_FAMILY],
			["markdown-h4",                   HEADINGS[3], 600, 0, NATIVE_FONT_FAMILY],
			//    等宽比正文小两档：等宽的 x-height 更大，同号会显得胖，这是原生惯例。
			["markdown-code",                 BODY - 2,   0, 0, NATIVE_MONO_FAMILY],
			["markdown-code-block",           BODY - 3,   0, 0, NATIVE_MONO_FAMILY],
			["markdown-code-block-small",     BODY - 4,   0, 0, NATIVE_MONO_FAMILY],
			["markdown-table",                BODY - 2,   0, 0, NATIVE_FONT_FAMILY],
			["markdown-table-head",           BODY - 2, 600, 0, NATIVE_FONT_FAMILY],
			// —— 通用 UI 族：token 名里的数字是 dsh 的原字号，别照着念 ——
			//    base-16 / s-14 / xs-13 三档全部收到 CONTROL：原生窗口里它们本来就该是
			//    同一档（systemFontSize），dsh 分三档纯属网页习惯。
			["base-16",                       CONTROL,     0, 0, NATIVE_FONT_FAMILY],
			["base-strong-16",                CONTROL,   600, 0, NATIVE_FONT_FAMILY],
			["s-14",                          CONTROL,     0, 0, NATIVE_FONT_FAMILY],
			["s-strong-14",                   CONTROL,   600, 0, NATIVE_FONT_FAMILY],
			["xs-13",                         CONTROL,     0, 0, NATIVE_FONT_FAMILY],
			["xs-strong-13",                  CONTROL,   600, 0, NATIVE_FONT_FAMILY],
			//    小字两档已经踩在 macOS 的 callout(12) / small(11) 上，只收行高。
			["xxs-12",                        12,          0, 0, NATIVE_FONT_FAMILY],
			["xxs-strong-12",                 12,        600, 0, NATIVE_FONT_FAMILY],
			["xxxs-11",                       11,          0, 0, NATIVE_FONT_FAMILY],
			["xxxs-strong-11",                11,        600, 0, NATIVE_FONT_FAMILY],
			//    大字三档 → title3 / title2 / title1。
			["m-18",                          15,        600, 0, NATIVE_FONT_FAMILY],
			["l-20",                          17,        600, 0, NATIVE_FONT_FAMILY],
			["xl-24",                         22,        600, 0, NATIVE_FONT_FAMILY],
		];

		/**
		 * 展开成 CSS 声明。dsh 每个 token 都有一个 `font` 简写和五个长手
		 * （`-font-size` / `-line-height` / `-font-weight` / `-font-style` / `-font-family`）。
		 * 实测 dsh 当前**只引用简写、长手零引用**，但两者失配是颗定时炸弹——dsh 哪天
		 * 改用长手就会一半新一半旧地分裂——所以六个一起写，成本只是几 KB。
		 */
		const typeTokenDecls = TYPE_TOKENS.flatMap(([name, size, weight, italic, family]) => {
			const lineHeight = lh(size);
			const shorthand = [
				italic ? "italic" : "",
				weight || "",
				`${size}px/${lineHeight}px`,
				family,
			].filter(Boolean).join(" ");
			return [
				`  --dsw-font-${name}: ${shorthand};`,
				`  --dsw-font-${name}-font-size: ${size}px;`,
				`  --dsw-font-${name}-line-height: ${lineHeight}px;`,
				`  --dsw-font-${name}-font-weight: ${weight || 400};`,
				`  --dsw-font-${name}-font-style: ${italic ? "italic" : "normal"};`,
				`  --dsw-font-${name}-font-family: ${family};`,
			];
		});

		/**
		 * 会话流里**不走 token** 的那批文字。
		 *
		 * dsh 的工具调用摘要行、文件名、时间戳、错误行……字号是硬编码的
		 * `font-size:14px; line-height:24px`，token 够不着。实测这一族占会话流可见
		 * 文字的 62%——正文改到 13px 之后，它们反而比正文还大，层级整个是反的
		 * （macOS 里次级标签只会更小或同号，绝不会更大）。
		 *
		 * **为什么用容器作用域而不是类名白名单**：这批规则有 309 条、61 个不同的语义
		 * 后缀，而且后缀互相打架——`_title` 在 12/13/14/15/16px 五档里都出现过，
		 * `_input`、`_label`、`_item` 同样跨档。按后缀白名单必然误伤。改用结构事实：
		 * **它们全都住在 `_flowItem` 子树里、且全都在 `_markdown` 子树之外**（实测：
		 * 该范围内 129 个带文字的元素，126 个是 14px/24px，另外 2 个 16px/24px、
		 * 1 个是屏幕阅读器的隐藏节点——没有更小的字号会被这条规则放大）。
		 *
		 * 已知失效方向：dsh 若在会话流里新增一种 10~12px 的小标签（badge、tag 之类），
		 * 会被这条规则顶到 13px（变大，而不是变乱）。发现了就往 EXCLUDED 里加一条。
		 */
		const FLOW_SCOPE = '[class*="_flowItem"]';
		const FLOW_EXCLUDED = [
			'[class*="_markdown"]',    // markdown 子树自己走 token，别重复接管
			'[class*="_markdown"] *',
			// 用户气泡是**对话内容**，不是 chrome——它和助手回复是同一场对话的两半，
			// 必须同号，否则自己说的话比对面说的小一档。dsh 给它 16px/24px 且不走
			// token（内层 `_text` 是 `font: inherit`），所以从这条兜底里摘出去，
			// 由下面 fontRules 里那条单独按 BODY 给。
			'[class*="_bubble"]',
			'[class*="_bubble"] *',
			"pre", "pre *", "code", "code *",   // 代码块的行高是它自己的事
			"svg", "svg *",            // 图标内部有按 em 定尺的几何，别碰
		].join(", ");

		/** 字体那一层的全部 CSS。两个旋钮见上面的 CONTROL / BODY。 */
		const fontRules = [
				// ===== 字体原生化（macOS 度量）=====
				//
				// 度量表、两个旋钮（CONTROL / BODY）与取值理由见文件头。
				//
				// 基准。dsh 没给 html reset 过 font-size，浏览器默认 16px；改成 CONTROL
				// = NSFont.systemFontSize。因为 dsh 全站零 rem，这一行**只影响"自己没
				// 声明 font-size、靠继承吃基准值"的元素**，不会等比缩放任何东西——
				// 它的作用是兜底，让 dsh 漏设字号的地方落在原生档位而不是 16px。
				`html { font-size: ${CONTROL}px; }`,

				// token 重映射。dsh 把 --dsw-font-* 定义在 `body` 上（特异性 0,0,1），
				// 这里写 `html body`（0,0,2）稳压一头——**刻意不靠源顺序取胜**：
				// dsh 的 UI 插件是运行时逐个注入 <style> 的，谁先谁后不受本插件控制。
				"html body {",
				...typeTokenDecls,
				"}",

				// 行内代码。dsh 写的是 `._markdown :not(pre) > code { font-size:.875em !important }`，
				// 相对定尺，落在正文的 0.875 倍上——会得到 14.875px 这种次像素值。钉成
				// 整数并与 markdown-code token 对齐。要盖过对方的 !important 就得拼
				// 特异性：对方 (0,1,2)，这里 `html body [class*=] :not(pre) > code` 是 (0,1,4)。
				`html body [class*="_markdown"] :not(pre) > code { font-size: ${BODY - 2}px !important; }`,

				// 会话流里不走 token 的硬编码文字（工具调用摘要行、文件名、时间戳……）。
				// 作用域与失效方向见文件头 FLOW_SCOPE 的注释。只写 font-size + line-height
				// 两条长手，**不用 `font` 简写**——简写会把 font-weight 一起重置成
				// normal，把这批标签里本来加粗的那些拍平。
				"html body " + FLOW_SCOPE + " :not(" + FLOW_EXCLUDED + ") {",
				`  font-size: ${CONTROL}px;`,
				`  line-height: ${lh(CONTROL)}px;`,
				"}",

				// 用户气泡。dsh 硬编码 16px/24px、不走 token，内层 `_text` 是 `font: inherit`
				// 所以只设气泡本身就够。跟 BODY 走的理由同 composer：你说的话和对面说的话
				// 是同一场对话，必须同号。
				`html body [class*="_bubble"] { font-size: ${BODY}px; line-height: ${lh(BODY)}px; }`,

				// composer 输入卡片。dsh 硬编码 16px/24px，卡片内的 textarea 走
				// `font: inherit` 跟着它。这是**唯一一处越过"控件区不动"边界的规则**，
				// 理由是它非动不可：你敲进去的字和发出来渲染的字必须同号，否则同一段
				// 文本在同一个窗口里两个字号，比不改更不像原生。所以它跟 BODY 走，
				// 不跟 CONTROL 走。
				// `:has(textarea)` 把「卡片」收窄到「装着输入框的那张卡片」——`_card`
				// 这个后缀太泛，光靠它会误伤设置页里的卡片。
				`html body [class*="_card"]:has(textarea) { font-size: ${BODY}px; line-height: ${lh(BODY)}px; }`,
		];

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
					// **只作用于"实体按钮"**，见文件头的 SOLID_BUTTONS 白名单。
					//
					// 三条 Apple 动效常数。曲线取自 SwiftUI 全系基准（起步快、收尾极缓）；
					// 按下切到 80ms 让它跟手，松开回到 320ms 留余韵。
					":root {",
					"  --dash-ease: cubic-bezier(0.32, 0.72, 0, 1);",
					"  --dash-dur-press: 80ms;",
					"  --dash-dur-fast: 160ms;",
					"  --dash-dur: 320ms;",
					// 玻璃表面，三层：**硬描边** + 上缘镜面高光 + 整圈 Fresnel 暗带。
					//
					// 数值不是估的，是量出来的：用 SwiftUI 的 .glassEffect(.regular, in:
					// .capsule) 让系统自己渲染一个胶囊，3x 截图后**以 1px 步长**扫过
					// 边界（白底、260x64pt）：
					//
					//     距边界 -1px : 254.2   （背景）
					//     距边界  0px : 201.3   ← 描边，暗 54 阶，一条硬线
					//     距边界 +1px : 250.2   ← Fresnel 暗带起点，暗 4.8 阶
					//     距边界+12px : 253.4   （渐亮回去）
					//     中心        : 253.8
					//
					// **玻璃不是「边缘暗、中心亮」的 Fresnel——方向正好相反。** 第一版按
					// 「边缘一圈暗带」做，怎么调都不对，因为模型就是错的。让系统渲染
					// 32/40/64pt 三档胶囊、逐列剔除图标后平均取垂直剖面（白底 255）：
					//
					//     距边缘      32pt     40pt     64pt
					//     0（描边）   −11.8    −11.2    −10.3
					//     1~2px       −1.1     −1.1     −1.1     ← 最亮，比本体还亮
					//     ≥6pt 本体   −5.0     −4.9     −4.8
					//     下半本体    −2.2     −2.1     −2.0
					//
					// 读出两条事实：
					//
					// **一、紧贴边缘那 1~2px 是整块玻璃最亮的地方**，越往里越暗，到 6pt 后
					//   稳定。所以正确的结构是「本体一层灰 + 上下两条内侧亮边把边缘提回来」，
					//   不是「中间干净 + 四周压暗」。
					//
					// **二、剖面不随尺寸缩放**——三档的数值几乎重合（差 ≤0.2 阶）。暗度是
					//   绝对量而非按钮高度的比例，所以 64pt 探针上量到的可以原样搬到 32px
					//   的按钮上，不需要换算。这也是为什么之前「blur 8px 在大胶囊上调好、
					//   套到小按钮上糊成一片」——那次错的是**宽度**跟着尺寸走了。
					//
					// 落到 CSS 是四层（层序自上而下，box-shadow 里先写的盖后写的）：
					//   描边 → 上下内侧亮边 → 上部加深层 → 铺满的本体底噪
					// 本体用 `inset 0 0 0 100px`：spread 撑满即纯色填充，且不碰 background，
					// 所以 dsh 自己的底色/渐变照常生效（换成 background-image 就会覆盖掉）。
					//
					// **必须拿窗口激活态的玻璃当基准。** 失活窗口里 macOS 把玻璃整个换成
					// 一块 −12 的平灰：没有描边层次、没有上下渐变、没有边缘亮边，剖面从头到尾
					// 就是 −12.0 一条直线。照它调，只会越调越灰——早先几版"偏深"的根源就在这。
					// 探针默认后台起，截到的正是失活态；refs 探针加 --hold 反复抢回 key，
					// 并把 NSApp.isActive / isKeyWindow 回显进窗口标题，截图里可直接验明。
					//
					//     白底 255        ACTIVE     失活
					//     描边            −12.4      −26.7
					//     内 1~2px        −1.9       −15.7
					//     上本体          −4.8       −12.0
					//     下本体          −1.7       −12.0
					//     上/下            2.8        1.0
					//
					// 数值在真 WKWebView 里扫出来，逐项对表 ACTIVE 实测（括号内为目标）：
					//     描边 −12.8（−12.4） 内1px −1.6（−1.9）
					//     上本体 −4.5（−4.8） 下本体 −1.6（−1.7） 上/下 2.87（2.8）
					"  --dash-glass-edge: rgba(0, 0, 0, 0.053);",
					"  --dash-glass-spec-w: 1px;",
					"  --dash-glass-specular: rgba(255, 255, 255, 0.75);",
					"  --dash-glass-specular-b: rgba(255, 255, 255, 0.50);",
					"  --dash-glass-top: rgba(0, 0, 0, 0.022);",
					"  --dash-glass-body: rgba(0, 0, 0, 0.0067);",
					"  --dash-glass-drop: rgba(0, 0, 0, 0.05);",
					"}",
					// dsh 的深色主题挂在 body[data-ds-dark-theme] 上（它自己的 --dsw-*
					// token 也是在那儿翻面的）。深色下描边翻成亮的（玻璃边缘在暗背景上
					// 反光，不是压暗）；暗带要加重才看得见；高光反过来要压住，否则像
					// 镀了层塑料。
					"body[data-ds-dark-theme] {",
					// 深色下**结构本身就不一样**，不是把浅色那套翻个面。同一支探针在
					// #1E1E20 上量 ACTIVE 态（背景实测 37.5）：
					//
					//     描边      +0.0   ← 根本没有暗描边
					//     边缘 1~2px +70    ← 上下各一条亮边，等强
					//     本体      +38    ← 比背景亮，不是压暗
					//     上/下      1.03   ← 几乎对称，没有浅色那 2.8 倍的上下差
					//
					// 所以深色下：描边归零、上部加深层归零、本体从"压暗"改成大幅提亮、
					// 上下亮边等强且加宽到 2px。浅色那套"上深下浅"在这里不成立——
					// 深色玻璃靠整体提亮和边缘亮边站住，不靠明暗渐变。
					"  --dash-glass-edge: rgba(255, 255, 255, 0);",
					"  --dash-glass-spec-w: 2px;",
					"  --dash-glass-specular: rgba(255, 255, 255, 0.18);",
					"  --dash-glass-specular-b: rgba(255, 255, 255, 0.18);",
					"  --dash-glass-top: rgba(0, 0, 0, 0);",
					"  --dash-glass-body: rgba(255, 255, 255, 0.176);",
					"  --dash-glass-drop: rgba(0, 0, 0, 0.25);",
					"}",

					// 统一过渡。dsh 给按钮写的是 transition: all，会把 scale 一起卷进它
					// 自己的时长里；这里换成逐属性声明，scale 走长曲线、配色走短线性。
					solid + " {",
					// 表面质感抽成变量，好让 hover / active 换投影时不必重抄一遍
					// （box-shadow 是整体覆盖的，漏抄一层就会把表面抹平）。
					// **这里不含描边**——自带 border 的那组就到此为止，由 dsh 自己那条
					// border 充当玻璃边界，我们只补高光和暗带。
					"  --dash-surface:",
					"    inset 0 var(--dash-glass-spec-w) 0 var(--dash-glass-specular),",
					"    inset 0 calc(-1 * var(--dash-glass-spec-w)) 0 var(--dash-glass-specular-b),",
					"    inset 0 16px 14px -8px var(--dash-glass-top),",
					"    inset 0 0 0 100px var(--dash-glass-body);",
					"  box-shadow: var(--dash-surface), 0 1px 2px var(--dash-glass-drop);",
					"  transition:",
					"    scale var(--dash-dur) var(--dash-ease),",
					"    background-color var(--dash-dur-fast) linear,",
					"    box-shadow var(--dash-dur-fast) var(--dash-ease),",
					"    color var(--dash-dur-fast) linear !important;",
					"}",
					// 无 border 的那组：把描边补进 --dash-surface 的最前面（层序在最上，
					// 不被暗带糊掉）。写在共用规则之后，靠源码顺序覆盖同特异性的上一条。
					// hover / active 引用的是同一个变量，所以那两态自动带上描边。
					solidPlain + " {",
					"  --dash-surface:",
					"    inset 0 0 0 0.5px var(--dash-glass-edge),",
					"    inset 0 var(--dash-glass-spec-w) 0 var(--dash-glass-specular),",
					"    inset 0 calc(-1 * var(--dash-glass-spec-w)) 0 var(--dash-glass-specular-b),",
					"    inset 0 16px 14px -8px var(--dash-glass-top),",
					"    inset 0 0 0 100px var(--dash-glass-body);",
					"}",
					solidSvg + " {",
					"  transition: scale var(--dash-dur) var(--dash-ease), opacity var(--dash-dur) var(--dash-ease);",
					"}",

					// 按压：容器涨、图标缩。这两个方向相反的形变是 Liquid Glass 手感的
					// 全部秘密——只做其中一个都不像（实测：单独放大像网页 hover，单独
					// 缩小像 Android ripple 的前摇）。scale 是独立属性、不占布局，
					// 因此在 flex/grid 里放大不会挤动邻居。
					solidActive + " {",
					"  scale: 1.06;",
					"  transition-duration: var(--dash-dur-press) !important;",
					"}",
					solidActiveSvg + " {",
					"  scale: 0.88;",
					"  opacity: 0.7;",
					"  transition-duration: var(--dash-dur-press);",
					"}",

					// 悬停：表面质感原样保留，只把贴地投影抬高一档（"浮起来"）。
					// dsh 自己的 hover 底色照常生效，深浅主题自动跟随。
					solidHover + " {",
					"  box-shadow: var(--dash-surface), 0 2px 5px var(--dash-glass-drop);",
					"}",
					// 按下：投影压回去（贴地），配合容器放大，像被按进桌面。
					solidActive + " {",
					"  box-shadow: var(--dash-surface), 0 0 1px var(--dash-glass-drop);",
					"}",

					// 尊重"减少动态效果"：关掉形变，保留配色反馈。
					"@media (prefers-reduced-motion: reduce) {",
					"  " + solidActive + ", " + solidActiveSvg + " { scale: 1 !important; }",
					"}",

					...fontRules,
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
