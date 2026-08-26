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
		const solidHover = join(ENABLED + ":hover");
		const solidActive = join(ENABLED + ":active");
		// 失活时给按钮整体去饱和用。前缀必须逐条加 —— 逗号串上只写一次
		// 只会命中第一条选择器。
		const blurSolid = SOLID_BUTTONS.map((sel) => ':root[data-dash-blur] ' + sel).join(",\n");

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
		/**
		 * 把承载窗口的激活态映射到 <html data-dash-blur>。
		 *
		 * 页面拿不到 AppKit 的窗口状态，但 WKWebView 会把承载窗口的激活/失活
		 * 转成页面的 focus/blur 事件（Safari 里切 app 也是同一套）。这是本插件
		 * 唯一一段 JS —— 其余全是 CSS。
		 *
		 * **刻意不走"让壳注入"那条路**：壳的窗口通知要经 dash-layout 的 Swift
		 * 半边才够得着 WebView，那会给 dash-nativeify 添一条跨插件契约。收不到
		 * 事件的后果只是永远停在激活态那套值 = 今天的行为，无害，所以宁可要
		 * 零依赖。（普通浏览器里 focus/blur 照常工作，效果同样合理。）
		 */
		/**
		 * 上下内侧发光的 8 条 box-shadow 层。
		 *
		 * 发光不能是一层。`inset 0 3px 0 白` 的 blur 是 0 = 一条纯白硬边直接盖住边缘；
		 * 给它加 blur 也不行 —— inset 阴影的模糊核有一半落在元素外，**最外那一两像素
		 * 反而最弱**，够不到系统的峰值。所以拿 4 条等宽硬边叠出几何衰减：第 k 条填最外
		 * k 像素、alpha = peak × decay^(k-1)。box-shadow 先写的盖后写的，于是第 n 行的
		 * 累积不透明度是第 n..4 层的合成 —— 天然单调递减，且只用两个旋钮：
		 *
		 *   --dash-glass-glow-t / -b   最外一像素的峰值（上下可以不等，深色下确实不等）
		 *   --dash-glass-glow-d        每向内一像素乘的衰减系数，越小掉得越快
		 *
		 * 实测（浅色 peak .55 / decay .45，相对白底）：−1 → −3 → −4（本体）；decay 调到
		 * .55 就摊成 −1 → −2 → −3 → −4。深色 peak .025 / decay .45：+8 → +4 → +2 → +1 → 0，
		 * 标准的对半衰减。
		 *
		 * alpha 里的 calc 连乘（`rgb(255 255 255 / calc(var(--a)*var(--d)*var(--d)))`）
		 * 在 WKWebView 里实测可用，三次连乘也对得上字面量。
		 *
		 * @returns {string[]} box-shadow 层，每行末尾带逗号
		 */
		function glowLayers() {
			const out = [];
			for (let k = 1; k <= 4; k++) {
				const decay = "*var(--dash-glass-glow-d)".repeat(k - 1);
				out.push(`    inset 0 ${k}px 0 rgb(var(--dash-glass-glow-c) / calc(var(--dash-glass-glow-t)${decay})),`);
				out.push(`    inset 0 -${k}px 0 rgb(var(--dash-glass-glow-c) / calc(var(--dash-glass-glow-b)${decay})),`);
			}
			return out;
		}

		/**
		 * 把按下的位置写成按钮上的 --dash-px / --dash-py（百分比）。
		 *
		 * 按压时那块亮光要从**手指底下**泛起来，不是从按钮正中 —— 位置这件事 CSS
		 * 拿不到，只能由 JS 喂。一条 document 上的委托监听，capture 阶段抓，
		 * passive 不阻塞滚动；不匹配白名单就立刻返回，代价约等于零。
		 *
		 * 拿不到指针（键盘回车、辅助技术触发）时两个变量不存在，CSS 那边的
		 * 兜底值是 50% 50%，亮光从正中泛起，仍然合理。
		 *
		 * @param {string} sel 白名单选择器（逗号串）
		 */
		function watchPressPoint(sel) {
			const onDown = (e) => {
				const el = e.target instanceof Element ? e.target.closest(sel) : null;
				if (!el) return;
				const r = el.getBoundingClientRect();
				if (!r.width || !r.height) return;
				el.style.setProperty("--dash-px", ((e.clientX - r.left) / r.width * 100).toFixed(1) + "%");
				el.style.setProperty("--dash-py", ((e.clientY - r.top) / r.height * 100).toFixed(1) + "%");
			};
			document.addEventListener("pointerdown", onDown, { capture: true, passive: true });
			return () => document.removeEventListener("pointerdown", onDown, { capture: true });
		}

		function watchWindowFocus() {
			const root = document.documentElement;
			const sync = () => root.toggleAttribute("data-dash-blur", !document.hasFocus());
			addEventListener("focus", sync);
			addEventListener("blur", sync);
			sync();
			return () => {
				removeEventListener("focus", sync);
				removeEventListener("blur", sync);
				root.removeAttribute("data-dash-blur");
			};
		}

		function apply(ctx) {
			if (!insideDash()) return;
			ctx.effect(watchWindowFocus);
			ctx.effect(() => watchPressPoint(SOLID_BUTTONS.join(",")));
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
					"  --dash-dur-press: 90ms;",
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
					// 落到 CSS 是六层（层序自上而下，box-shadow 里先写的盖后写的）：
					//   描边 → 上下发光·硬边 → 上下发光·晕开 → 左右内侧阴影 → 铺满的本体底噪
					// 本体用 `inset 0 0 0 100px`：spread 撑满即纯色填充，且不碰 background，
					// 所以 dsh 自己的底色/渐变照常生效（换成 background-image 就会覆盖掉）。
					//
					// **必须拿窗口激活态的玻璃当基准。** 失活窗口里 macOS 把玻璃整个换成一块
					// −12 的平灰：没有描边层次、没有渐变、没有边缘发光，剖面从头到尾一条直线。
					// 照它调只会越调越灰。探针默认后台起，截到的正是失活态；refs 探针加 --hold
					// 反复抢回 key，并把 NSApp.isActive / isKeyWindow 回显进窗口标题，可验明。
					//
					// **上下和左右是正交的两回事，只量垂直剖面会整个漏掉水平维度。**
					// 把整枚胶囊打成二维亮度图（相对白底 255）才看得出真实结构：
					//
					//     y \ x     0pt    3     10    …    56    63    66
					//      1pt              −1.6 一路平           ← 上内侧发光，最亮
					//      5pt      −4.8  −4.8  −4.8   …  −4.8  −4.8  −4.4
					//      8pt      −4.8  −4.8  −4.8   …  −4.8  −4.8  −4.8   ← 上部暗带横向贯通
					//     11pt      −4.8  −4.0  −2.4   …  −2.4  −3.2  −4.0
					//     15pt      −4.8  −2.4  −1.6   …  −1.6  −2.8  −4.8   ← 只剩两端暗
					//     20pt      −2.4  −2.0  −1.6   …  −1.6  −1.6  −2.4
					//
					// 暗是**沿内缘走一圈的环带**：上半部横向贯通（整行 −4.8），下半部只剩左右
					// 两端，中间回到底色 −1.6。上下边缘各 2px 的发光把边缘提回 −1.6。
					// 左右端描边 −32.5，比上下的 −12.4 深得多（圆弧处抗锯齿叠上描边）。
					//
					// **最终值是肉眼在校准台上对着系统胶囊调的，不是扫描的最优解。** 扫描能把
					// 六个特征点都压进 0.5 阶内，看着仍不对——因为特征点没覆盖到的地方（描边的
					// 锐度、发光的宽窄）也在影响观感。定稿相对扫描结果有三处偏离，都是有意的：
					//
					//   描边   0.5px/.048 → **0.25px/.197**。等墨量下更窄更浓 = 更锐。
					//          玻璃边缘要的是"实"，摊薄了就散成一圈灰雾。
					//   暗带   **整层删掉**。上部暗带原是为复刻"上深下浅"，但发光加强后
					//          它只让上半发浑，删了更干净。代价是放弃系统那 2.8 倍的上下差。
					//   底色   从"往下压"翻成"往上提"：`rgba(252,252,252,.5272)` 是近白色的高
					//          不透明度填充，按钮在页面灰上是**浮起来的一块亮**（+3），而不是
					//          陷下去的一块暗。系统那枚是 −1.6 的微暗，方向正相反 —— 但按钮
					//          坐的是页面灰不是纯白，肉眼比对下提亮更像玻璃。
					//
					// 发光为什么必须是四层的几何衰减，见 glowLayers() 的注释。
					"  --dash-glass-edge: rgba(0, 0, 0, 0.197);",
					"  --dash-glass-edge-w: 0.25px;",
					// 发光的颜色。无色玻璃是白的；**带色玻璃不是** —— 系统蓝键的峰值是 #00C0FF，
					// R 通道从头到尾是 0，白色叠加会把 R 拉起来，对不上（红键同理，峰值 #FF5762）。
					// 所以留成变量：真要给某个带色按钮上玻璃，换成同色系更亮的一档，别用白。
					"  --dash-glass-glow-c: 255 255 255;",
					"  --dash-glass-glow-t: 0.795;",
					"  --dash-glass-glow-b: 0.795;",
					"  --dash-glass-glow-d: 0.45;",
					"  --dash-glass-side: rgba(0, 0, 0, 0.119);",
					"  --dash-glass-body: rgba(252, 252, 252, 0.5272);",
					// 按压亮光。**浅色档几乎没有余量**：本体已经 248/255，纯白也只抬得动 7 级，
					// 所以给到 1.0 仍然是"淡淡一片"。真想按下去更明显，把它换成一点点黑
					// （rgba(0,0,0,.10)）读起来强得多 —— 那是"压下去"不是"泛起光"，看要哪个。
					// 浅色档按下**不泛光**：系统实测就是整体压暗，一点白光都没有；而且浅色
					// 玻璃本体已经 248/255，头顶只剩 7 级，白光物理上也抬不动（实测 +1 级）。
					"  --dash-press-glow: transparent;",
					// hover 变暗、按下更暗。系统实测（激活窗口、同图左右对照）：
					// 248.1 → 悬停 239.5（−8.6）→ 按下 230.8（−17.3）。tint 是叠在最上面的
					// 整片 inset，所以 alpha 直接由 Δ/底色算：8.6/248.1、17.3/248.1。
					"  --dash-tint-hover: rgba(0, 0, 0, 0.035);",
					"  --dash-tint-press: rgba(0, 0, 0, 0.070);",
					"  --dash-glass-drop: rgba(0, 0, 0, 0.05);",
					"}",
					// dsh 的深色主题挂在 body[data-ds-dark-theme] 上（它自己的 --dsw-*
					// token 也是在那儿翻面的）。深色下描边翻成亮的（玻璃边缘在暗背景上
					// 反光，不是压暗）；暗带要加重才看得见；高光反过来要压住，否则像
					// 镀了层塑料。
					"body[data-ds-dark-theme] {",
					// 深色下**结构本身就不一样**，不是把浅色那套翻个面。同一支探针在 #1E1E20
					// 上量 ACTIVE 态（背景实测 37.5），二维图横向**完全平**：
					//
					//     y \ x     0pt    3     10    …    56    63    66
					//      1pt       0.0  42.0  43.1   …  41.8  43.1  42.0   ← 上发光 +4.7
					//      5pt       0.0  37.3  37.3   …  37.3  37.3  37.3
					//      8pt      −7.2  37.3  37.3   …  37.3  37.3  37.3   ← 整行一个值
					//     13pt       0.0  37.3  37.4   …  37.4  37.4  37.3
					//     20pt       0.0   0.0  46.3   …  45.3  46.3  53.9   ← 下发光 +8
					//
					// 也就是：本体比背景**亮 +37.3**（不是压暗）· 没有暗描边 · **没有左右阴影**·
					// **没有上部暗带** · 只有上下两条发光，且**下比上强**（+8 vs +4.7，与浅色反过来）。
					// 深色玻璃靠整体提亮和边缘发光站住，不靠明暗渐变，所以 side / top 两层归零。
					"  --dash-glass-edge: rgba(255, 255, 255, 0);",
					"  --dash-glass-edge-w: 0.25px;",
					// 系统在深色下上下**不等强**（+4.7 vs +8.0，与浅色反过来），但定稿在校准台上
					// 眼调回了等强 —— 深色玻璃本体已经比背景亮 37，上下差那 3 级看不出来，
					// 反倒是整体的发光强度和衰减速度更要紧。峰值分上下两个变量仍留着，随时能拆开。
					"  --dash-glass-glow-t: 0.06;",
					"  --dash-glass-glow-b: 0.06;",
					"  --dash-glass-glow-d: 0.5;",
					"  --dash-glass-side: rgba(0, 0, 0, 0);",
					"  --dash-glass-body: rgba(255, 255, 255, 0.137);",
					// 深色档余量大得多，扫过 .20/.30/.40/.55 后取 .30：再高就白成一块。
					"  --dash-press-glow: rgba(255, 255, 255, 0.17);",
					// 深色档 hover 提亮。系统实测 66.6 → 88.5（+21.9），**按下与悬停逐像素
					// 完全一致** —— 深色那档的高光到 hover 就到顶了，按下不再加码。我们仍然在
					// 按下时多叠一层跟指针走的泛光（--dash-press-glow），那是自己要的层次：
					// 闲时 → 悬停（整面提亮）→ 按下（手指底下再亮一块），系统只有前两级。
					"  --dash-tint-hover: rgba(255, 255, 255, 0.113);",
					"  --dash-tint-press: rgba(255, 255, 255, 0.113);",
					"  --dash-glass-drop: rgba(0, 0, 0, 0.25);",
					"}",
					
					// ── 窗口失活 ──────────────────────────────────────────────────────
					// **失活时 macOS 把玻璃整个换成一块平色，零结构。** 四格矩阵实测：
					//
					//              浅色              深色
					//   ACTIVE     有描边/发光/      提亮 +37.3
					//              左右阴影/渐变     + 上下发光
					//   失活       整块 −12.0        整块 +25.7
					//              描边 −34.8        无描边
					//
					// 失活那两格从头到尾一个值 —— 没有发光、没有左右阴影、没有明暗渐变。
					// 所以这里不是"把值调淡"，是**把四层里的三层直接关掉**，只留底色
					// （浅色再留一条更浓的描边：−34.8 对激活的 −16.0，浓 2.2 倍）。
					//
					// 触发靠 data-dash-blur，由下面 watchWindowFocus() 打在 <html> 上。
					// 特异性：:root[…] body 是 (0,2,2)，稳压上面 body[data-ds-dark-theme] 的
					// (0,1,1)；深色失活再多一个属性选择器，压住浅色失活。
					":root[data-dash-blur] body {",
					// 失活描边反过来走「更宽更淡」：0.6px/.095 的墨量（.057）比激活的
					// 0.25px/.197（.049）略重，但摊开后是一圈灰雾而不是一道锐线 —— 正是
					// 失活该有的"退到背景里"的样子。
					"  --dash-glass-edge: rgba(0, 0, 0, 0.095);",
					"  --dash-glass-edge-w: 0.6px;",
					"  --dash-glass-glow-t: 0;",
					"  --dash-glass-glow-b: 0;",
					"  --dash-glass-side: transparent;",
					"  --dash-glass-body: rgba(0, 0, 0, 0.059);",
					"}",
					":root[data-dash-blur] body[data-ds-dark-theme] {",
					"  --dash-glass-edge: rgba(255, 255, 255, 0);",
					"  --dash-glass-glow-t: 0;",
					"  --dash-glass-glow-b: 0;",
					"  --dash-glass-side: transparent;",
					"  --dash-glass-body: rgba(255, 255, 255, 0.094);",
					"}",

					// 表面换成平色只做了一半 —— **失活时按钮里的内容也得褪色**。系统在失活窗口里
					// 把控件整个去饱和（实测：带色玻璃连色相都不剩，退成平灰），发送键那圈强调蓝
					// 还亮着就穿帮。grayscale(1) 对已经中性的玻璃层是空操作，只咬有色的内容。
					//
					// 只给白名单里那五个按钮，不给整页：系统灰的是**控件**，正文该什么色还是什么色。
					blurSolid + " {",
					"  filter: grayscale(1);",
					"}",

					// 统一过渡。dsh 给按钮写的是 transition: all，会把 scale 一起卷进它
					// 自己的时长里；这里换成逐属性声明，scale 走长曲线、配色走短线性。
					solid + " {",
					// 表面质感抽成变量，好让 hover / active 换投影时不必重抄一遍
					// （box-shadow 是整体覆盖的，漏抄一层就会把表面抹平）。
					// **这里不含描边**——自带 border 的那组就到此为止，由 dsh 自己那条
					// border 充当玻璃边界，我们只补高光和暗带。
					"  --dash-surface:",
					...glowLayers(),
					// hover / 按下的整片着色。**放在高光层之下**：上下那两道高光是镜面反射，
					// 不该被"鼠标移上去"改掉；系统那组 Δ 也是量按钮腰部（本体）得来的，
					// 所以 alpha 也只该按本体算。闲时 transparent，由 @property 兜底。
					"    inset 0 0 0 100px var(--dash-tint),",
					"    inset 14px 0 8px -15px var(--dash-glass-side),",
					"    inset -14px 0 8px -15px var(--dash-glass-side),",
					"    inset 0 0 0 100px var(--dash-glass-body);",
					"  box-shadow: var(--dash-surface), 0 1px 2px var(--dash-glass-drop);",
					"  transition:",
					"    scale var(--dash-dur) var(--dash-ease),",
					"    background-color var(--dash-dur-fast) linear,",
					"    box-shadow var(--dash-dur-fast) var(--dash-ease),",
					"    --dash-press-r var(--dash-dur) var(--dash-ease),",
					"    --dash-press-a var(--dash-dur) var(--dash-ease),",
					"    filter var(--dash-dur-fast) linear,",
					"    color var(--dash-dur-fast) linear !important;",
					"}",
					// 无 border 的那组：把描边补进 --dash-surface 的最前面（层序在最上，
					// 不被暗带糊掉）。写在共用规则之后，靠源码顺序覆盖同特异性的上一条。
					// hover / active 引用的是同一个变量，所以那两态自动带上描边。
					solidPlain + " {",
					"  --dash-surface:",
					"    inset 0 0 0 var(--dash-glass-edge-w) var(--dash-glass-edge),",
					...glowLayers(),
					// hover / 按下的整片着色。**放在高光层之下**：上下那两道高光是镜面反射，
					// 不该被"鼠标移上去"改掉；系统那组 Δ 也是量按钮腰部（本体）得来的，
					// 所以 alpha 也只该按本体算。闲时 transparent，由 @property 兜底。
					"    inset 0 0 0 100px var(--dash-tint),",
					"    inset 14px 0 8px -15px var(--dash-glass-side),",
					"    inset -14px 0 8px -15px var(--dash-glass-side),",
					"    inset 0 0 0 100px var(--dash-glass-body);",
					"}",

					// 按压：容器 scale，**内容跟着容器一起走**。`scale` 是可继承的形变，
					// 图标本来就跟着涨，不需要也不该再给它写一层。
					//
					// 这里曾经给图标补过一条反向的 `scale: 0.88`，注释还称"容器涨、图标缩"是
					// Liquid Glass 手感的全部秘密 —— **没有这种说法，那条是错的**，仓库里也从来
					// 没有任何实测支持它。净效果是图标只有 1.06 × 0.88 = 0.93 倍，按下去像被
					// 捏了一把而不是被按下去。图标现在什么都不额外做，跟着容器走。
					//
					// scale 是独立属性、不占布局，所以在 flex/grid 里放大不会挤动邻居。
					solidActive + " {",
					"  scale: 1.09;",
					// 150% 就是闲时那个值 —— **定稿故意不收拢**：亮光只淡入淡出，是整面泛光，
					// 不是聚成一小块。位置仍然跟着 --dash-px/--dash-py 走（渐变中心在手指底下，
					// 只是摊得很开）。这一行留着是为了把"不收拢"写在用它的地方，改回收拢就调它。
					"  --dash-press-r: 150%;",
					"  --dash-press-a: var(--dash-press-glow);",
					"  transition-duration: var(--dash-dur-press) !important;",
					"}",

					// 按下时手指底下泛起一片亮光，松手淡掉。渐变中心跟着指针走。
					//
					// **定稿只让不透明度变，半径两态都是 150%** —— 整面泛光，不收拢成一小块。
					// 半径这个旋钮仍然接着：**"散开"这件事必须写进闲时那一态**才做得出来。
					// transition 只有两态，闲时 = 摊开 + 全透明、按住 = 收拢 + 亮起来，按下去就是
					// "光聚到手指底下"，松手自动成为"摊开并淡掉"，一条 transition 拿到两个方向，
					// 不用 JS 补第三个关键帧。反过来写（闲时收小、按住摊开）松手就成了"缩回去"。
					//
					// 半径和颜色都能过渡，是因为 @property 把它们注册成了 <percentage> / <color>：
					// **没注册的自定义属性不参与插值**，会直接跳变。位置走 --dash-px/--dash-py，
					// 由 watchPressPoint() 喂；拿不到指针时兜底 50% 50%。
					//
					// **走 background-image 而不是 ::after**：伪元素盖在内容之上，浅色档那点
					// 白光会把按钮文字一起冲淡（实测过，"Session log" 直接发虚）。background-image
					// 这一层在 background-color 之上、内容之下，文字纹丝不动。代价是两条：
					// 它会覆盖 dsh 自己的 background-image（这几个按钮目前都是纯色，没有渐变），
					// 而且 inset 阴影画在背景之上，玻璃底色那层会把亮光吃掉一半 —— 后者反而
					// 更对：光是从材料内部透出来的，不是糊在玻璃表面。
					// 不注册它，闲时 var(--dash-tint) 解析不出来会让**整条 box-shadow 失效**，
					// 玻璃表面直接消失。注册成 <color> 顺带也让它自己可插值。
					"@property --dash-tint {",
					"  syntax: \"<color>\";",
					"  inherits: false;",
					"  initial-value: transparent;",
					"}",
					"@property --dash-press-r {",
					"  syntax: \"<percentage>\";",
					"  inherits: false;",
					"  initial-value: 150%;",
					"}",
					"@property --dash-press-a {",
					"  syntax: \"<color>\";",
					"  inherits: false;",
					"  initial-value: transparent;",
					"}",
					solid + " {",
					// !important 是必须的：`background` 简写会把 background-image 一起清掉，
					// dsh 只要在哪条更具体的规则里用了简写（发送键那种实心色最容易），亮光就
					// 整个没了，而且是静默的 —— 不报错、不留痕。
					"  background-image: radial-gradient(circle at var(--dash-px, 50%) var(--dash-py, 50%),",
					"    var(--dash-press-a) 0%, transparent var(--dash-press-r)) !important;",
					"}",

					// 悬停：整面着色（浅色变暗 / 深色提亮，见上面两组 tint 变量），
					// 外加把贴地投影抬高一档（"浮起来"）。表面其余层原样保留 ——
					// box-shadow 是整体覆盖的，所以这里必须重抄 var(--dash-surface)。
					solidHover + " {",
					"  --dash-tint: var(--dash-tint-hover);",
					"  box-shadow: var(--dash-surface), 0 2px 5px var(--dash-glass-drop);",
					"}",
					// **实心强调键不参与 hover**：系统实测 .glassProminent 悬停零变化
					// （浅深两档、逐像素 diff 都是空的，且 .onHover 指示灯确认游标确实到位）。
					// 选择器与上一条同特异性，靠源码顺序覆盖。投影那一档保留。
					'button[class*="_primary"]' + ENABLED + ':hover {',
					"  --dash-tint: transparent;",
					"}",
					// 按下：着色加深一档 + 投影压回去（贴地），配合容器放大，像被按进桌面。
					// 排在 hover 之后，所以两态同时命中时这条赢（含上面那条 _primary 的清零）。
					solidActive + " {",
					"  --dash-tint: var(--dash-tint-press);",
					"  box-shadow: var(--dash-surface), 0 0 1px var(--dash-glass-drop);",
					"}",

					// 尊重"减少动态效果"：关掉形变，保留配色反馈。
					"@media (prefers-reduced-motion: reduce) {",
					"  " + solidActive + " { scale: 1 !important; }",
					"  " + solidActive + " { --dash-press-r: 100% !important; }",
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
