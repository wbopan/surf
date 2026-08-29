/*
 * clam-nativeify，浏览器半边（lazy-CJS 经典脚本，手写、无构建步骤）。
 *
 * **职责边界**：只做「让 dsh Web UI 摸起来像原生 macOS App」这一件事，
 * 几乎全部实现是注入一段 CSS，零服务依赖、零跨插件契约：禁掉 document 橡皮筋、
 * UI 文本不可选中（输入框与会话消息流除外）、实体按钮的按压手感、
 * 字体收到 macOS 原生度量（两个旋钮：CONTROL 管控件、BODY 管对话阅读列，
 * 见下面「原生字体度量」的实测表）、主内容区 header 贴合 macOS 27 工具栏
 * （HEADER 段，权威计划 docs/web-header-native-match-plan.md）。
 *
 * **唯一一条对外契约**是 header 那一段带来的：`watchDragPassthrough()` 把 header
 * 里可点元素的矩形经页内桥报给壳，换它对顶部拖动条放行。不报的话 header 上的
 * 胶囊全是假按钮（壳那 40pt 拖动条压在 WebView 上）。壳缺席时它静默失败，
 * CSS 照常生效。
 *
 * **不在这里的**：
 * - `window.__clam` 动作桥、收起 web 侧边栏、rail 轨道抵消——那些是原生分栏
 *   接管排版的一部分，住在 clam-layout 的 client 半边（协议两端同包：Swift 侧
 *   `WebViewConversationSurface` 是它们唯一的调用方）。
 * - 网页侧边栏的任何外观调整（顶部让位、背景透明化以透出原生玻璃）。这些是
 *   「网页侧边栏坐在壳的 NSGlassEffectView 上」那个旧世界的产物，已随 M6 作废：
 *   现在只有两种形态——原生侧边栏（clam-layout 占 root 槽，WebView 装在分栏右侧，
 *   够不着侧边栏那一栏）或完整网页模式（全出血逃生舱，原样展示 dsh UI，不修）。
 *   「用网页侧边栏但把它打扮成原生」这个中间态不存在，别再往回加。
 *
 * 门控只有一条：UA 含 "Clam/"（带斜杠，防普通子串误命中）。终端 `dsh web` /
 * 普通浏览器打开同一 profile 完全不受影响。
 *
 * 选择器说明：dsh Web UI 的类名是 hash 化 CSS module（如 Md3f7G_flowItem），
 * hash 随版本变化但语义后缀稳定，因此用 [class*="_flowItem"] 防御式命中。
 * 升级 dsh 后若失效，优先核对该语义名。
 */
window.__ModuleLoader__.load({
	id: "@wenbo/clam-nativeify",
	factory: () => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });

		const STYLE_ID = "clam-nativeify-style";
		/**
		 * 字体那一层**单独一张 style**，因为它是唯一随设置变化的部分。
		 *
		 * 合在 STYLE_ID 那张里也能工作，代价是改一次字号要把上面那整摞玻璃 CSS
		 * （几十 KB、八层 box-shadow、三个 @property）连带重建一遍——@property 重新
		 * 注册会让已注册的自定义属性瞬时回到 initial-value，按钮表面在那一帧塌掉。
		 * 拆开之后改字号只重写这一张的 textContent，别的一个字节都不动。
		 *
		 * 拆开不影响取胜：字体那批规则靠 `html body`（0,0,2）的特异性压过 dsh 的
		 * `body`（0,0,1），本来就不靠源码顺序——文件头 typeTokenDecls 那段写着理由。
		 */
		const FONT_STYLE_ID = "clam-nativeify-font";

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
		/**
		 * 主内容区 header 槽的 outlet。**槽名是槽系统的一等契约**（每个 outlet 都带
		 * `data-slot`、`display:contents`、不产生盒子），比任何 hash 化类名都稳。
		 *
		 * header 那一段的选择器**一律拿它打头**：`_label` / `_trigger` / `_root`
		 * 这种语义后缀在 dsh 全站到处都是（composer 的模型选择器、访问模式选择器
		 * 全叫 `_trigger`），不锚定就是全站误伤。
		 */
		const HEADER_SEAT = '[data-slot="conversation.session.header"]';

		const SOLID_BORDERED = [
			'button[class*="_newSession"]',        // 侧边栏新建会话（白底 + 1px border）
			// 会话流「回到底部」浮动圆钮（34×34，自带 1px border + 浮起投影）。
			// **不写 `button[...]` 前缀**：从 bundle 里确认不了它到底是 <button> 还是
			// role=button 的 div，去掉标签限定两种都能命中。代价是得手动排掉外层的
			// `_toBottomSlot` 容器 —— 属性选择器只有「包含」，没有「以…结尾」。
			'[class*="_toBottom"]:not([class*="Slot"])',
		];
		const SOLID_PLAIN = [
			'button[class*="_primary"]',           // composer 发送键（实心强调色，无 border）
			'button[class*="_add"]',               // composer 命令 +（浅灰实底，无 border）
			// 会话流顶部「加载更早」。它是个裸 <button type="button">，自己一个 class
			// 都没有，只能从父容器 Md3f7G_older 捞——所以这条是唯一的结构选择器。
			'[class*="_older"] > button',
			// ── header 那三枚玻璃胶囊（见下面 HEADER 段）─────────────────────────
			// 导出按钮。**它以前在 SOLID_BORDERED 里**（dsh 给了它 1px border-l2），
			// 现在收成 36×36 的图标钮，和旁边两枚描边由我们画的胶囊并排——留着
			// dsh 那条 1px 会让三枚里唯一一枚的边比别人黑一圈（墨量 .1 对 .049）。
			// 所以 HEADER 段把它的 border 抹掉，这里跟着换组，三枚描边同源。
			HEADER_SEAT + ' button[class*="_sessionLogButton"]',
			// 子代理计数下拉 / 兄弟切换器（ui-subagent 的 _trigger / _switcherTrigger）
			// 与后台任务下拉（ui-jobs 的 _trigger）。**必须锚在 HEADER_SEAT 之下**：
			// `_trigger` 这个后缀 composer 那排选择器也在用，不锚就全站上玻璃。
			HEADER_SEAT + ' button[class*="_trigger"]',
		];
		const SOLID_BUTTONS = SOLID_PLAIN.concat(SOLID_BORDERED);
		// 排除 dsh 自己的禁用态两种写法；:not() 链一次写好，供下面各态复用。
		const ENABLED = ':not(:disabled):not([aria-disabled="true"])';
		const join = (suffix) => SOLID_BUTTONS.map((s) => s + suffix).join(",\n");
		const joinPlain = (suffix) => SOLID_PLAIN.map((s) => s + suffix).join(",\n");
		// **给色只能有一处，那一处是 background-color。**
		// `_primary` 是唯一自带强调色的按钮，它的色由 dsh 自己画，我们碰都不碰，
		// 只补结构层；其余几枚的色由我们出，写进 background-color。
		// 这里以前是一层 `inset 0 0 0 100px var(--clam-glass-fill)`，理由写的是
		// 「不碰 background，dsh 自己的底色照常生效」—— 结果就是**两处都在给色**：
		// 半透明白压在 dsh 的强调蓝上，把发送键洗成藕荷色。少一个能给色的地方，
		// 这个 bug 在结构上就不可能再出现。
		const TINTED = ['button[class*="_primary"]'];
		const neutral = SOLID_BUTTONS.filter((sel) => !TINTED.includes(sel)).join(",\n");
		const tinted = TINTED.join(",\n");
		const solid = join("");
		const solidPlain = joinPlain("");
		const solidHover = join(ENABLED + ":hover");
		const solidActive = join(ENABLED + ":active");
		// 失活时给按钮整体去饱和用。前缀必须逐条加 —— 逗号串上只写一次
		// 只会命中第一条选择器。
		const blurSolid = SOLID_BUTTONS.map((sel) => ':root[data-clam-blur] ' + sel).join(",\n");
		// 切焦点那一帧用的「禁过渡」选择器，同样得逐条加前缀。
		const nofxSolid = SOLID_BUTTONS.map((sel) => ':root[data-clam-nofx] ' + sel).join(",\n");

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
			if (!v) throw new Error(`clam-nativeify: ${size}px 没有实测行高，先补测再用`);
			return v;
		};

		const CONTROL = 13;   // NSFont.systemFontSize：控件 / 工具调用行 / 次级标签

		/**
		 * 对话阅读列的字号——**唯一可配置的旋钮**（设置 → 插件 → clam-nativeify →
		 * 对话区字号）。其余全部派生，包括标题阶梯、行内代码、代码块、表格、
		 * 用户气泡与 composer。
		 *
		 * **CONTROL 不给调，这是有意的**：13 = `NSFont.systemFontSize`，它不是口味
		 * 而是"像原生"这件事的定义本身。菜单、工具栏、列表行在 macOS 上就是这一档，
		 * 壳的原生侧边栏也是；调它等于让 WebView 那半边和原生那半边用两套字，
		 * 本插件存在的理由当场作废。阅读列不一样——那是长文，字号是纯口味。
		 *
		 * 12~22 这个范围不是随手定的，是被 NATIVE_LINE_HEIGHT 那张实测表的边界
		 * 卡死的：BODY 会派生出 BODY-4（12 → 8，正好是表的下界）与标题档 26
		 * （22 → 26，在上界 28 之内）。**表里没有的字号 lh() 直接抛**，而它跑在
		 * 构造 CSS 的路上，一抛就是整段字体规则消失。要放宽范围先补测行高。
		 */
		const BODY_DEFAULT = 15;
		const BODY_MIN = 12;
		const BODY_MAX = 22;

		/**
		 * 收到 [BODY_MIN, BODY_MAX] 的整数。
		 *
		 * schema 那边已经写了 min/max，**这里仍要收一次**：设置文档是用户可以拿
		 * 编辑器手改的文本文件，而越界值的后果不是"字大了点"，是 lh() 抛错、
		 * 整段字体 CSS 一条都不生效。宁可默默夹住。
		 *
		 * @param {unknown} v 设置里的原始值。
		 * @returns {number} 可安全喂给 lh() 的字号。
		 */
		const clampBody = (v) => {
			const n = Math.round(Number(v));
			if (!Number.isFinite(n)) return BODY_DEFAULT;
			return Math.min(BODY_MAX, Math.max(BODY_MIN, n));
		};

		/**
		 * 标题阶梯 h1~h4。走 macOS 的语义档（largeTitle 26 / title1 22 / title2 17 /
		 * title3 15），取正文之上的四档；**h4 与正文同号、只差字重**——macOS 的层级
		 * 靠字重和颜色分，不靠字号跳变，这是原生做法。
		 * BODY 换档时这四个数要一起看，所以写在一起。
		 */
		const headings = (BODY) => (BODY >= 16 ? [26, 22, 20, BODY] : [20, 17, 15, BODY]);

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
		// **表体一字不改**：BODY 与 HEADINGS 从模块常量变成这两个参数，于是
		// 下面每一行的写法（`BODY - 2`、`HEADINGS[0]`）与它们的取值理由都原样成立。
		const typeTokens = (BODY, HEADINGS = headings(BODY)) => [
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
		const typeTokenDecls = (BODY) => typeTokens(BODY).flatMap(([name, size, weight, italic, family]) => {
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

		/**
		 * 字体那一层的全部 CSS。两个旋钮见上面的 CONTROL / BODY_DEFAULT。
		 *
		 * @param {number} BODY 对话阅读列字号（已 clamp）。
		 * @returns {string[]} CSS 行。
		 */
		const fontRules = (BODY) => [
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
				...typeTokenDecls(BODY),
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

		/**
		 * ===== 主内容区 header：一行 52pt，贴合 macOS 27 Unified Toolbar =====
		 *
		 * 权威计划 `docs/web-header-native-match-plan.md`，数值出自 Apple 官方
		 * macOS 27 UI Kit（Sketch）的 `Unified Toolbar + Title + Sidebar`。
		 *
		 * **为什么是 CSS 而不是原生重画**：原生那条路（clam-header）要自己复刻 header
		 * 的全部内容——面包屑、子代理目录、preset、后台任务、导出——内容一变就漂移。
		 * CSS 只改**形**，内容与行为仍归 dsh。判据不变：**圆胶囊是"可操作"的承诺**，
		 * 不可点的 preset 退成副标题，不做假按钮。
		 *
		 * ── 布局的那一招 ───────────────────────────────────────────────────────
		 * dsh 的 header 是两行：`_titleRow`（标题簇 + utilities）叠 `_tabs`（下划线标签）。
		 * 要把它们排成一行、且顺序是「标题 … 段控 子代理 导出」，就得让 `header`
		 * 直接看见这几样东西——所以三层纯布局容器（`_titleRow` / `_titleCluster` /
		 * `_headerActions`）一律 `display: contents` 摊平，`header` 自己变成 grid：
		 *
		 *   列： [1] 标题/副标题   [2] 1fr 弹性   [3] 段控   [4] 子代理·任务   [5] 导出
		 *   行： [1] 标题          [2] 副标题（preset；缺席时这行高度为 0）
		 *
		 * 两行都是 `auto` + `align-content: center`：**没有副标题时标题自己居中**
		 * （中线 y=26，与原生侧边栏那两枚 36 胶囊共用），有副标题时两行整体居中。
		 * 写成 `1fr 1fr` 就会在没有 preset 时把标题顶到上半格——差 9pt，一眼看得出。
		 *
		 * 列间距**不用 `column-gap`**：`_tabs` 只在视图多于一个时才渲染，空列的
		 * gap 照样占位，那 8pt 会凭空多出来。改成右侧每一项各自 `margin-left: 8px`。
		 *
		 * ── 选择器纪律 ─────────────────────────────────────────────────────────
		 * 一律 `HEADER_SEAT` 打头。`_label` / `_trigger` / `_root` 这些后缀在 dsh
		 * 全站到处都是（composer 那排选择器全叫 `_trigger`），不锚定就是全站误伤。
		 * `data-slot` 是槽系统的一等契约，比 hash 化类名稳——所以「actions 槽里
		 * 除了 preset 之外的东西」这类结构判断优先走它，再补一条类名版兜底。
		 *
		 * ── 已知失效方向 ───────────────────────────────────────────────────────
		 * - `display: contents` 会让这三层从 AX 树里消失。它们是纯布局 div、无 role，
		 *   无损；哪天 dsh 给 `_headerActions` 加了 role 就得换方案。
		 * - actions 槽今天只有两位住户（preset、后台任务）。再来第三位会和后台任务
		 *   挤在同一格里叠着——那时把第 4 列拆成两列。
		 * - `_tab` 没有 `data-view`，只有本地化文案和 `aria-selected`。CSS 只认后者。
		 *
		 * @returns {string[]} CSS 行。
		 */
		function headerRules() {
			const S = HEADER_SEAT;
			// 面包屑段之间的 `chevron.right`（Apple 的层级分隔符），换掉 dsh 的 `/`。
			const chevron = "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 8 12'%3E%3Cpath d='M2 1.4 6.6 6 2 10.6' fill='none' stroke='%23000' stroke-width='1.7' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E\")";
			return [
				// ── 四态配色（浅/深 × 激活/失活）────────────────────────────────
				// 标题色**不用 dsh 的 `label-primary`**（#0f1115，那是正文黑）：
				// Apple 的工具栏标题是 Labels/Vibrant/1 Primary 那档 vibrant 深灰。
				// 特异性：`${S}` 是 (0,1,0)，深色 (0,2,1)，失活 (0,2,1) 排在深色之后
				// 所以浅色失活赢；深色失活单列一条 (0,3,2) 压住它。
				S + " {",
				"  --clam-header-title: rgb(54, 54, 54);",
				"  --clam-header-subtitle: rgb(178, 178, 178);",
				"  --clam-header-seg-fill: rgba(0, 0, 0, 0.07);",
				"  --clam-header-seg-sep: rgba(0, 0, 0, 0.05);",
				"}",
				"body[data-ds-dark-theme] " + S + " {",
				"  --clam-header-title: rgba(255, 255, 255, 0.96);",
				"  --clam-header-subtitle: rgb(138, 138, 138);",
				"  --clam-header-seg-fill: rgba(255, 255, 255, 0.08);",
				"  --clam-header-seg-sep: rgba(255, 255, 255, 0.06);",
				"}",
				":root[data-clam-blur] " + S + " {",
				"  --clam-header-title: rgb(178, 178, 178);",
				"  --clam-header-seg-fill: rgba(0, 0, 0, 0.05);",
				"}",
				":root[data-clam-blur] body[data-ds-dark-theme] " + S + " {",
				"  --clam-header-title: rgba(255, 255, 255, 0.55);",
				"  --clam-header-seg-fill: rgba(255, 255, 255, 0.06);",
				"}",

				// ── 几何：一行 52 ───────────────────────────────────────────────
				// `:not(_headerHidden)` 是必须的：空会话时 dsh 用 `.wSkVaW_headerHidden
				// { display: none }`（0,1,0）把整条 header 收掉，而 `${S} > header`
				// 是 (0,1,1)，不排除的话 grid 会把它又显示出来。
				S + ' > header:not([class*="_headerHidden"]) {',
				"  box-sizing: border-box;",
				"  height: 52px;",
				// 左 16 = Apple 的标题起点（首项 x=8 + 项内 8）；右 8 = 末项右侧留白。
				"  padding: 8px 8px 8px 16px;",
				"  display: grid;",
				// 标题列可收缩到 0（窄窗口时让面包屑自己截断），别让它把胶囊挤出去。
				"  grid-template-columns: minmax(0, auto) 1fr auto auto auto;",
				"  grid-template-rows: auto auto;",
				"  align-content: center;",
				"  border-bottom: 0;",
				"}",
				// 底边那条 1px 线：Apple 的工具栏没有分隔线，内容从底下穿过。
				S + " > header::after { display: none; }",
				// 三层纯布局容器摊平，让 header 直接看见里面的东西。
				S + ' [class*="_titleRow"],',
				S + ' [class*="_titleCluster"],',
				S + ' [class*="_headerActions"] { display: contents; }',

				// ── 网格落位 ───────────────────────────────────────────────────
				S + ' nav[class*="_crumbs"] {',
				"  grid-column: 1;",
				"  grid-row: 1;",
				"  min-width: 0;",
				"  gap: 2px;",
				// dsh 给 nav 挂了 `overflow: hidden`，**而截断根本不靠它**——
				// `_crumb` 自己就有 `max-width: 220px` + `text-overflow: ellipsis`。
				// 留着它的唯一效果是把子代理那枚胶囊上下裁掉一截（实测：胶囊真的是
				// 36 高，只是 nav 只有 20 高，红框调试时上下两条边直接消失）。
				"  overflow: visible;",
				"  align-items: center;",
				// 面包屑按钮自带 8px 内边距（hover 药丸要它），把它抵掉，
				// 文字起点才真的落在 16。
				"  margin-left: -8px;",
				"}",
				// preset → 副标题。它是**锁定不可点**的（dsh 在 header 里只渲染一个
				// span），所以按判据退成文字，不做成假胶囊。
				S + ' [class*="_label"] {',
				"  grid-column: 1;",
				"  grid-row: 2;",
				"  align-self: center;",
				"  justify-self: start;",
				"  max-width: 100%;",
				"  min-width: 0;",
				"  height: auto;",
				"  margin: 0;",
				"  padding: 0;",
				"  gap: 4px;",
				"  background: none;",
				"  border-radius: 0;",
				"  font-size: 11px;",
				`  line-height: ${lh(11)}px;`,
				"  font-weight: 500;",
				"  color: var(--clam-header-subtitle);",
				"}",
				// preset 自己那枚图标跟着副标题走。**这是 web header，不受原生
				// `window.subtitle` 塞不进图标那条限制**（SF Symbols 是图片资源，
				// 不是可嵌进字符串的字体）——所以这里留着它。
				S + ' [class*="_label"] svg {',
				"  width: 11px;",
				"  height: 11px;",
				"  opacity: 1;",
				"}",
				// 段控（视图切换）。
				S + ' [role="tablist"] {',
				"  grid-column: 3;",
				"  grid-row: 1 / -1;",
				"  align-self: center;",
				"  margin: 0 0 0 8px;",
				"}",
				// actions 槽里除 preset 之外的住户（今天只有后台任务下拉）。
				// 两条选择器是同一件事的两种形状：槽 outlet 是 `display: contents`，
				// 若哪天多包一层 DOM，类名那条兜住；outlet 那条命中的才是真格子，
				// 另一条落在 `display: contents` 的元素上，是惰性的，无害。
				S + ' [data-slot="conversation.session.header.actions"] > *:not([class*="_label"]),',
				S + ' [class*="_headerActions"] > *:not([class*="_label"]) {',
				"  grid-column: 4;",
				"  grid-row: 1 / -1;",
				"  align-self: center;",
				"  display: flex;",
				"  align-items: center;",
				"  margin-left: 8px;",
				"}",
				S + ' [class*="_headerUtilities"] {',
				"  grid-column: 5;",
				"  grid-row: 1 / -1;",
				"  align-self: center;",
				"  margin-left: 8px;",  // dsh 原值 20
				"}",

				// ── 标题与面包屑 ───────────────────────────────────────────────
				// 父级面包屑（可点）留在 13——它们是次级信息，不该和标题同号。
				S + ' button[class*="_crumb"] {',
				"  padding: 0 8px;",
				"  font-size: 13px;",
				`  line-height: ${lh(13)}px;`,
				"  font-weight: 400;",
				"  border-radius: 8px;",
				"}",
				// 末段 = 标题。SF Pro Bold 15；web 里 600 比 700 更接近 AppKit 的
				// `.headline` 度量（700 偏重，落地截图比过）。
				// 排在上一条之后、同特异性，靠源码顺序赢——`_crumbCurrent` 和
				// `_crumb` 是同一个元素上的两个类。
				S + ' button[class*="_crumbCurrent"] {',
				"  font-size: 15px;",
				`  line-height: ${lh(15)}px;`,
				"  font-weight: 600;",
				"  color: var(--clam-header-title);",
				"}",
				// 段间分隔：dsh 写的是一个 `/` 字符，换成 `chevron.right`。
				// 走 mask + currentColor，深浅色自动跟随。
				S + ' [class*="_crumbSep"] {',
				"  display: inline-block;",
				"  width: 9px;",
				"  height: 9px;",
				"  font-size: 0;",
				"  color: var(--clam-header-subtitle);",
				"  background: currentColor;",
				`  -webkit-mask: ${chevron} center / 9px 9px no-repeat;`,
				`  mask: ${chevron} center / 9px 9px no-repeat;`,
				"}",

				// ── 段控：容器是玻璃胶囊，选中段自己画底 ────────────────────────
				// 容器**不进 SOLID_BUTTONS 白名单**：那套带 hover/按压/放大，
				// 而它不是按钮，是一块底板。所以这里自己抄一份表面层——
				// 用的是同一批 `--clam-glass-*` 变量，四态跟着走，不另起一套。
				S + ' [role="tablist"] {',
				"  box-sizing: border-box;",
				"  height: 36px;",
				"  padding: 4px;",
				"  gap: 0;",
				"  border-radius: 18px;",
				"  align-items: center;",
				"  --clam-surface:",
				"    inset 0 0 0 var(--clam-glass-edge-w) var(--clam-glass-edge),",
				...glowLayers(),
				"    inset 14px 0 8px -15px var(--clam-glass-side),",
				"    inset -14px 0 8px -15px var(--clam-glass-side);",
				"  background-color: var(--clam-glass-fill);",
				"  backdrop-filter: blur(var(--clam-glass-blur)) saturate(var(--clam-glass-sat));",
				"  box-shadow: var(--clam-surface), 0 1px 2px var(--clam-glass-drop);",
				"}",
				// 段本体。下划线 + 蓝色选中色全部去掉——Apple 的工具栏段控靠底板
				// 区分选中，不用强调色。
				S + ' [role="tab"] {',
				"  box-sizing: border-box;",
				"  height: 28px;",
				"  padding: 0 10px;",
				"  border-radius: 14px;",
				"  display: inline-flex;",
				"  align-items: center;",
				"  background: transparent;",
				"  font-size: 13px;",
				`  line-height: ${lh(13)}px;`,
				"  font-weight: 500;",
				"  color: var(--clam-header-title);",
				"  transition: background-color var(--clam-dur-fast) linear;",
				"}",
				S + ' [role="tab"]::after { display: none; }',
				S + ' [role="tab"]:hover:not([aria-selected="true"]) {',
				"  background: var(--clam-tint-hover);",
				"}",
				S + ' [role="tab"][aria-selected="true"] {',
				"  background: var(--clam-header-seg-fill);",
				"  color: var(--clam-header-title);",
				"}",
				// 段间那道 1×16 细线。**选中段两侧不画**——Apple 的分隔只出现在
				// 两个未选段之间（今天只有两个段，所以它实际上永远不显示；
				// dsh 哪天加第三个视图就用得上了）。
				S + ' [role="tab"] + [role="tab"]::before {',
				'  content: "";',
				"  position: absolute;",
				"  left: 0;",
				"  top: 50%;",
				"  translate: 0 -50%;",
				"  width: 1px;",
				"  height: 16px;",
				"  background: var(--clam-header-seg-sep);",
				"}",
				S + ' [role="tab"][aria-selected="true"]::before,',
				S + ' [role="tab"][aria-selected="true"] + [role="tab"]::before { display: none; }',

				// ── 子代理 / 后台任务：下拉玻璃胶囊 ─────────────────────────────
				// 玻璃表面来自 SOLID_PLAIN 白名单（见文件头），这里只给几何与字。
				S + ' button[class*="_trigger"] {',
				"  box-sizing: border-box;",
				"  height: 36px;",
				"  min-height: 36px;",
				"  padding: 0 10px;",
				"  border-radius: 18px;",
				"  gap: 4px;",
				"  font-size: 13px;",
				`  line-height: ${lh(13)}px;`,
				"  font-weight: 500;",
				"  color: var(--clam-header-title);",
				"}",
				// **子代理那枚是例外：24 高，不是 36。**
				//
				// 计划把它画成右侧第二枚 36 胶囊，落地时发现做不到——dsh 把 lineage 槽
				// 放在 `nav._crumbs > span._crumbSeg` 里面，**它是面包屑的一段，不是
				// actions 槽的住户**。要把它挪到第 4 列就得把 nav 和 _crumbSeg 一起
				// `display: contents` 摊平，那样多段面包屑的每个按钮都会变成独立格子、
				// 互相叠在一起——为了一枚胶囊赔掉子代理会话的整条面包屑，不值。
				//
				// 所以顺着 DOM 来：它是**面包屑末段的下拉**，就按内联尺寸给。
				// 24 是被标题行卡死的——36 会把标题行撑到 36，加上副标题那行就是
				// 52，副标题只能贴着栏底，标题与右侧胶囊的中线也对不上了。
				S + ' nav[class*="_crumbs"] button[class*="_trigger"] {',
				"  height: 24px;",
				"  min-height: 24px;",
				"  padding: 0 8px;",
				"  border-radius: 12px;",
				"  font-size: 12px;",
				`  line-height: ${lh(12)}px;`,
				"}",
				// 子代理模块自带的那个 `/`（`ZKlsPq_separator`，不是面包屑那个
				// `_crumbSep`）跟着一起换成 chevron。
				S + ' [class*="_separator"] {',
				"  display: inline-block;",
				"  width: 9px;",
				"  height: 9px;",
				"  font-size: 0;",
				"  color: var(--clam-header-subtitle);",
				"  background: currentColor;",
				`  -webkit-mask: ${chevron} center / 9px 9px no-repeat;`,
				`  mask: ${chevron} center / 9px 9px no-repeat;`,
				"}",

				// ── 导出：36×36 图标钮 ─────────────────────────────────────────
				// 文字收成 0 宽而不是 `display: none`：**它得留在 AX 树里**
				// （VoiceOver 与 peekaboo 都靠它认这枚按钮）。
				S + ' button[class*="_sessionLogButton"] {',
				"  box-sizing: border-box;",
				"  width: 36px;",
				"  min-width: 0;",
				"  height: 36px;",
				"  padding: 0;",
				"  gap: 0;",
				"  border: 0;",
				"  border-radius: 18px;",
				"  color: var(--clam-header-title);",
				"}",
				S + ' button[class*="_sessionLogButton"] span { font-size: 0; }',
				S + ' button[class*="_sessionLogButton"] svg { width: 16px; height: 16px; }',
			];
		}

		function insideClam() {
			try {
				return navigator.userAgent.includes("Clam/");
			} catch {
				return false;
			}
		}

		/**
		 * 插件体：注入原生化样式；fiber 卸载（HMR/禁用）时移除。
		 * @param {import('@deepseek-ai/cordis').Context} ctx
		 */
		/**
		 * 把承载窗口的激活态映射到 <html data-clam-blur>。
		 *
		 * 页面拿不到 AppKit 的窗口状态，但 WKWebView 会把承载窗口的激活/失活
		 * 转成页面的 focus/blur 事件（Safari 里切 app 也是同一套）。
		 *
		 * **刻意不走"让壳注入"那条路**：壳的窗口通知要经 clam-layout 的 Swift
		 * 半边才够得着 WebView，那会给 clam-nativeify 添一条跨插件契约。收不到
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
		 *   --clam-glass-glow-t / -b   最外一像素的峰值（上下可以不等，深色下确实不等）
		 *   --clam-glass-glow-d        每向内一像素乘的衰减系数，越小掉得越快
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
				const decay = "*var(--clam-glass-glow-d)".repeat(k - 1);
				out.push(`    inset 0 ${k}px 0 rgb(var(--clam-glass-glow-c) / calc(var(--clam-glass-glow-t)${decay})),`);
				out.push(`    inset 0 -${k}px 0 rgb(var(--clam-glass-glow-c) / calc(var(--clam-glass-glow-b)${decay})),`);
			}
			return out;
		}

		/**
		 * 把按下的位置写成按钮上的 --clam-px / --clam-py（百分比）。
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
				el.style.setProperty("--clam-px", ((e.clientX - r.left) / r.width * 100).toFixed(1) + "%");
				el.style.setProperty("--clam-py", ((e.clientY - r.top) / r.height * 100).toFixed(1) + "%");
			};
			document.addEventListener("pointerdown", onDown, { capture: true, passive: true });
			return () => document.removeEventListener("pointerdown", onDown, { capture: true });
		}

		/**
		 * 把 header 里可点元素的位置报给壳，换它对拖动条放行。
		 *
		 * **不报的话新 header 就是三枚假按钮。** 壳在 contentView 顶部盖了一块
		 * 40pt 的 `WindowDragRegionView`（`fullSizeContentView` 下原生标题栏被
		 * WebView 挡住，没它就整窗拖不动），它压在 WebView 上，网页顶部 40pt 里的
		 * mouseDown 全部变成拖窗。旧 header 撑得住只是因为那 40pt 里只有一个
		 * disabled 的面包屑和一个 span；新 header 的三枚胶囊正落在 y=8–44。
		 *
		 * 报的是 `getBoundingClientRect()` 的原始值——**CSS px、视口左上为原点**。
		 * 壳那边负责换算（WebView 在窗口里的偏移、AppKit 的翻转坐标、pageZoom），
		 * 页面这边因此不需要知道侧边栏有多宽，也不需要知道用户按过几次 ⌘+。
		 *
		 * **不设上下界**：只报"这些地方有可点的东西"，40pt 那条线是壳的事——
		 * 壳哪天把拖动条改高改矮，页面一个字都不用改。
		 *
		 * 常驻轮询而不是绑 observer：header 是 React 组件，root entry 重注册会把
		 * 整个节点换掉，绑死的 observer 会永久失效（仓库里踩过这条）。一次
		 * `querySelectorAll` 只扫 header 子树的十来个元素，JSON 一样就不发，
		 * 代价约等于零。
		 */
		function watchDragPassthrough() {
			const INTERACTIVE = 'button, a[href], input, select, summary, [role="button"], [role="tab"]';
			let last = "";
			const post = () => {
				const seat = document.querySelector(HEADER_SEAT);
				const rects = [];
				// header 被 dsh 自己藏起来时（空会话 hero）一条都不报 = 整条带子归拖窗。
				if (seat && seat.firstElementChild?.getAttribute("aria-hidden") !== "true") {
					for (const el of seat.querySelectorAll(INTERACTIVE)) {
						const r = el.getBoundingClientRect();
						if (r.width < 1 || r.height < 1) continue;
						const round = (v) => Math.round(v * 10) / 10;
						rects.push({ x: round(r.left), y: round(r.top), w: round(r.width), h: round(r.height) });
					}
				}
				const json = JSON.stringify(rects);
				if (json === last) return;
				last = json;
				try {
					window.webkit.messageHandlers.clam.postMessage({ type: "dragPassthrough", rects });
				} catch {
					// 壳缺席（普通浏览器）就一直抛，无所谓：last 已经记下，不会每轮都抛。
				}
			};
			const timer = setInterval(post, 300);
			addEventListener("resize", post);
			post();
			return () => {
				clearInterval(timer);
				removeEventListener("resize", post);
				// 退场时把放行表清空，否则壳会照着一份再也不会更新的旧表放行。
				try {
					window.webkit.messageHandlers.clam.postMessage({ type: "dragPassthrough", rects: [] });
				} catch { /* 同上 */ }
			};
		}

		function watchWindowFocus() {
			const root = document.documentElement;
			// **激活 ↔ 失活必须是瞬时的，不能补间。** 窗口换焦点时系统是重绘，不是动画；
			// 而按钮上挂着 box-shadow / background-color / filter 的过渡（那是给 hover 和
			// 按下用的），焦点一变就会顺带把整摞玻璃层做成 160ms 淡入淡出 —— 一眼假。
			//
			// 老办法：先挂 data-clam-nofx（配套 CSS 把过渡整个关掉）→ 改值 →
			// **读一次 offsetHeight 强制刷新样式**，让新值以「无过渡」落定 → 摘掉标记。
			// 那次读取是整段的关键，删了就等于没加：不强制刷新，浏览器会把加标记、改值、
			// 摘标记合成一次样式计算，过渡照旧发生。
			const sync = () => {
				root.setAttribute("data-clam-nofx", "");
				root.toggleAttribute("data-clam-blur", !document.hasFocus());
				void root.offsetHeight;
				root.removeAttribute("data-clam-nofx");
			};
			addEventListener("focus", sync);
			addEventListener("blur", sync);
			sync();
			return () => {
				removeEventListener("focus", sync);
				removeEventListener("blur", sync);
				root.removeAttribute("data-clam-blur");
				root.removeAttribute("data-clam-nofx");
			};
		}

		function apply(ctx) {
			if (!insideClam()) return;
			ctx.effect(watchWindowFocus);
			ctx.effect(() => watchPressPoint(SOLID_BUTTONS.join(",")));
			ctx.effect(watchDragPassthrough);

			/** 当前生效的对话区字号。设置服务缺席或还没就绪时就是这个默认值。 */
			let body = BODY_DEFAULT;
			/** 字体那一层的 style 元素；设置一变就重写它的 textContent。 */
			let fontStyle = null;

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
					"  --clam-ease: cubic-bezier(0.32, 0.72, 0, 1);",
					"  --clam-dur-press: 90ms;",
					"  --clam-dur-fast: 160ms;",
					"  --clam-dur: 320ms;",
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
					//
					// ── 背景模糊 ──────────────────────────────────────────────────
					// 上面那些是**表面**，这两个是**材质本身**：玻璃先把背后的东西
					// 糊掉、把颜色提饱和，然后才谈描边和高光。缺了这一层，按钮在
					// 花哨背景（会话气泡、代码块、渐变）上就是一块贴纸。
					//
					// 数值实测自 `.glassEffect(.regular)`，探针在 docs/spikes/glass-blur/：
					// 玻璃条底下垫一条竖直硬边（左黑右白），理想硬边被 σ 的高斯核糊过
					// 之后是条 erf 曲线，10%→90% 的宽度 W 与 σ 成定比 W = 2.5631 σ。
					// 只看曲线**形状**，所以玻璃自己的提亮/描边（都是仿射变换）不干扰。
					//
					//   96pt 面板   σ = 26.28 图像 px
					//   48pt 条     σ = 26.02
					//   32pt 条     σ = 25.88      ← 三档几乎重合
					//   无玻璃对照  σ =  0.34      ← 确认硬边本身是锐的
					//
					// 截图是 2x，所以 **σ ≈ 13pt**。CSS 的 `blur(<length>)` 参数按规范
					// 就是标准差，可以原样填。
					//
					// **模糊半径不随控件尺寸缩放**——这和本文件上面量到的"剖面不随尺寸
					// 缩放"是同一条事实的两面：玻璃的所有度量都是绝对量。
					//
					// 两个只有量了才知道的细节：
					//  · **系统的模糊在线性光里做**。直接拿 sRGB 码值扫剖面会得到一条明显
					//    不对称的曲线（暗侧拖长、亮侧收紧），σ 被高估 ~2%；解码回线性光
					//    之后 50% 穿越点正好落在几何边界上。CSS 的 backdrop-filter 是在
					//    sRGB 里做的，这一条我们复刻不了，只能接受过渡略偏暗。
					//  · **底色的合成确实在 sRGB 里**：玻璃盖纯黑读 145.0、盖纯白读 254.0，
					//    这条直线预测中灰 127 → 199.3，实测 199.2。所以下面的 --clam-glass-fill
					//    用普通 alpha 合成就对，不需要换空间。
					//    （顺带：这两个点解出的是 rgba(253,253,253,0.5725)，比下面定稿的
					//     0.5272 更透一点。定稿是只拿白底一个点校的，两者在白底上等价，
					//     在深色背景上才分得出。真要更贴系统就改那一行，不必动这里。）
					"  --clam-glass-blur: 13px;",
					// 饱和度。模糊会把颜色搅浑，系统靠提饱和补回来——这就是"糊了却不脏"
					// 的来源。四条中间色带（避开纯色，纯红/纯绿在提亮后会撞 255 天花板，
					// 一 clip 就再也解不出系数）逐通道做最小二乘，得 S = 1.966；网上复刻
					// 液态玻璃的教程普遍给 saturate(180%)，量出来的正好落在同一档。
					"  --clam-glass-sat: 1.95;",
					"  --clam-glass-edge: rgba(0, 0, 0, 0.197);",
					"  --clam-glass-edge-w: 0.25px;",
					// 发光的颜色。无色玻璃是白的；**带色玻璃不是** —— 系统蓝键的峰值是 #00C0FF，
					// R 通道从头到尾是 0，白色叠加会把 R 拉起来，对不上（红键同理，峰值 #FF5762）。
					// 所以留成变量：真要给某个带色按钮上玻璃，换成同色系更亮的一档，别用白。
					"  --clam-glass-glow-c: 255 255 255;",
					"  --clam-glass-glow-t: 0.795;",
					"  --clam-glass-glow-b: 0.795;",
					"  --clam-glass-glow-d: 0.45;",
					"  --clam-glass-side: rgba(0, 0, 0, 0.119);",
					// 底色 = 元素的 background-color（不是阴影层）。**这是唯一的给色处**；
					// 半透明 = 页面透上来，压到 1 就是实色。名字以前叫 -body，读起来像"玻璃本体"，
					// 正是那个"再叠一层材料"的错误心智模型的来源，已改名。
					"  --clam-glass-fill: rgba(252, 252, 252, 0.5272);",
					// 按压亮光。**浅色档几乎没有余量**：本体已经 248/255，纯白也只抬得动 7 级，
					// 所以给到 1.0 仍然是"淡淡一片"。真想按下去更明显，把它换成一点点黑
					// （rgba(0,0,0,.10)）读起来强得多 —— 那是"压下去"不是"泛起光"，看要哪个。
					// 浅色档按下**不泛光**：系统实测就是整体压暗，一点白光都没有；而且浅色
					// 玻璃本体已经 248/255，头顶只剩 7 级，白光物理上也抬不动（实测 +1 级）。
					"  --clam-press-glow: transparent;",
					// hover 变暗、按下更暗。系统实测（激活窗口、同图左右对照）：
					// 248.1 → 悬停 239.5（−8.6）→ 按下 230.8（−17.3）。tint 是叠在最上面的
					// 整片 inset，所以 alpha 直接由 Δ/底色算：8.6/248.1、17.3/248.1。
					"  --clam-tint-hover: rgba(0, 0, 0, 0.035);",
					"  --clam-tint-press: rgba(0, 0, 0, 0.070);",
					"  --clam-glass-drop: rgba(0, 0, 0, 0.05);",
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
					"  --clam-glass-edge: rgba(255, 255, 255, 0);",
					"  --clam-glass-edge-w: 0.25px;",
					// 系统在深色下上下**不等强**（+4.7 vs +8.0，与浅色反过来），但定稿在校准台上
					// 眼调回了等强 —— 深色玻璃本体已经比背景亮 37，上下差那 3 级看不出来，
					// 反倒是整体的发光强度和衰减速度更要紧。峰值分上下两个变量仍留着，随时能拆开。
					"  --clam-glass-glow-t: 0.06;",
					"  --clam-glass-glow-b: 0.06;",
					"  --clam-glass-glow-d: 0.5;",
					"  --clam-glass-side: rgba(0, 0, 0, 0);",
					"  --clam-glass-fill: rgba(255, 255, 255, 0.137);",
					// 深色档余量大得多，扫过 .20/.30/.40/.55 后取 .30：再高就白成一块。
					"  --clam-press-glow: rgba(255, 255, 255, 0.17);",
					// 深色档 hover 提亮。系统实测 66.6 → 88.5（+21.9），**按下与悬停逐像素
					// 完全一致** —— 深色那档的高光到 hover 就到顶了，按下不再加码。我们仍然在
					// 按下时多叠一层跟指针走的泛光（--clam-press-glow），那是自己要的层次：
					// 闲时 → 悬停（整面提亮）→ 按下（手指底下再亮一块），系统只有前两级。
					"  --clam-tint-hover: rgba(255, 255, 255, 0.113);",
					"  --clam-tint-press: rgba(255, 255, 255, 0.113);",
					"  --clam-glass-drop: rgba(0, 0, 0, 0.25);",
					"}",

					// 深色档的页面底色。dsh 的 `body` 规则是
					// `background: var(--dsw-alias-bg-base, #fff)`，所以**改这一个 token
					// 就等于改整页底色**，不用去猜哪个容器在画背景、也不用打 !important。
					// 和字体那层是同一个套路（见 README「token 重映射」）。
					//
					// 特异性写 `html body[…]`（0,1,2）而不是 `body[…]`（0,1,1）：dsh 自己
					// 在哪一层定义这个 token 没查到（不在前端 dist 里，运行时注入的），
					// 多垫一个 `html` 是便宜的保险。自定义属性会继承，body 子树全跟着走。
					"html body[data-ds-dark-theme] {",
					"  --dsw-alias-bg-base: #1E1E1E;",
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
					// 触发靠 data-clam-blur，由下面 watchWindowFocus() 打在 <html> 上。
					// 特异性：:root[…] body 是 (0,2,2)，稳压上面 body[data-ds-dark-theme] 的
					// (0,1,1)；深色失活再多一个属性选择器，压住浅色失活。
					":root[data-clam-blur] body {",
					// 失活描边反过来走「更宽更淡」：0.6px/.095 的墨量（.057）比激活的
					// 0.25px/.197（.049）略重，但摊开后是一圈灰雾而不是一道锐线 —— 正是
					// 失活该有的"退到背景里"的样子。
					"  --clam-glass-edge: rgba(0, 0, 0, 0.095);",
					"  --clam-glass-edge-w: 0.6px;",
					"  --clam-glass-glow-t: 0;",
					"  --clam-glass-glow-b: 0;",
					"  --clam-glass-side: transparent;",
					"  --clam-glass-fill: rgba(0, 0, 0, 0.059);",
					"}",
					":root[data-clam-blur] body[data-ds-dark-theme] {",
					"  --clam-glass-edge: rgba(255, 255, 255, 0);",
					"  --clam-glass-glow-t: 0;",
					"  --clam-glass-glow-b: 0;",
					"  --clam-glass-side: transparent;",
					"  --clam-glass-fill: rgba(255, 255, 255, 0.094);",
					"}",

					// 表面换成平色只做了一半 —— **失活时按钮里的内容也得褪色**。系统在失活窗口里
					// 把控件整个去饱和（实测：带色玻璃连色相都不剩，退成平灰），发送键那圈强调蓝
					// 还亮着就穿帮。grayscale(1) 对已经中性的玻璃层是空操作，只咬有色的内容。
					//
					// 只给白名单里那五个按钮，不给整页：系统灰的是**控件**，正文该什么色还是什么色。
					blurSolid + " {",
					"  filter: grayscale(1);",
					"}",

					// 切焦点那一帧把过渡整个关掉。只在 sync() 里挂着，读一次 offsetHeight
					// 之后立刻摘掉，所以它只影响那一次样式落定 —— hover / 按下的过渡照旧。
					// `!important` 是必须的：上面那条 transition 自己就是 !important 的。
					nofxSolid + " {",
					"  transition: none !important;",
					"}",

					// 统一过渡。dsh 给按钮写的是 transition: all，会把 scale 一起卷进它
					// 自己的时长里；这里换成逐属性声明，scale 走长曲线、配色走短线性。
					solid + " {",
					// 表面质感抽成变量，好让 hover / active 换投影时不必重抄一遍
					// （box-shadow 是整体覆盖的，漏抄一层就会把表面抹平）。
					// **这里不含描边**——自带 border 的那组就到此为止，由 dsh 自己那条
					// border 充当玻璃边界，我们只补高光和暗带。
					"  --clam-surface:",
					...glowLayers(),
					// hover / 按下的整片着色。**放在高光层之下**：上下那两道高光是镜面反射，
					// 不该被"鼠标移上去"改掉；系统那组 Δ 也是量按钮腰部（本体）得来的，
					// 所以 alpha 也只该按本体算。闲时 transparent，由 @property 兜底。
					"    inset 0 0 0 100px var(--clam-tint),",
					"    inset 14px 0 8px -15px var(--clam-glass-side),",
					"    inset -14px 0 8px -15px var(--clam-glass-side);",
					"  box-shadow: var(--clam-surface), 0 1px 2px var(--clam-glass-drop);",
					"}",
					// 底色 = 元素自己的 background-color。`!important` 是必须的：dsh 在更具体的
					// 规则里用 `background` 简写，不加会被静默清掉，连报错都没有。
					// **`_primary` 不在这条里** —— 它的色是 dsh 画的，我们再盖一层就是两处给色。
					neutral + " {",
					"  background-color: var(--clam-glass-fill) !important;",
					// 材质层。**跟着 --clam-glass-fill 走，只给这一组**：`_primary` 那枚
					// 强调键是 dsh 自己画的实色，背后糊什么都看不见，给它上 backdrop-filter
					// 只是白白多一个合成层。
					//
					// 不加 `-webkit-` 前缀：本插件由 UA 门控（含 `Clam/`），只会跑在壳的
					// WKWebView 里，那是 Safari 26 的引擎，无前缀版本从 Safari 18 就有了。
					//
					// 一条 WebKit/Blink 的共同行为要知道：backdrop-filter 的采样**基本只
					// 取元素正后方那块**，边界处是钳位而不是把外面的内容卷进来。所以 32px
					// 高的按钮不会真的糊进 13px 半径外的东西，读起来更像"把身下这块摊匀"。
					// 这和系统玻璃在小控件上的观感是一致的，不用去补 Comeau 那套
					// 「撑高 200% 再拿 mask 裁回来」的花招——那是给整条横幅用的。
					"  backdrop-filter: blur(var(--clam-glass-blur)) saturate(var(--clam-glass-sat));",
					"}",
					solid + " {",
					"  transition:",
					"    scale var(--clam-dur) var(--clam-ease),",
					"    background-color var(--clam-dur-fast) linear,",
					"    box-shadow var(--clam-dur-fast) var(--clam-ease),",
					"    --clam-press-r var(--clam-dur) var(--clam-ease),",
					"    --clam-press-a var(--clam-dur) var(--clam-ease),",
					"    filter var(--clam-dur-fast) linear,",
					"    color var(--clam-dur-fast) linear !important;",
					"}",
					// 无 border 的那组：把描边补进 --clam-surface 的最前面（层序在最上，
					// 不被暗带糊掉）。写在共用规则之后，靠源码顺序覆盖同特异性的上一条。
					// hover / active 引用的是同一个变量，所以那两态自动带上描边。
					solidPlain + " {",
					"  --clam-surface:",
					"    inset 0 0 0 var(--clam-glass-edge-w) var(--clam-glass-edge),",
					...glowLayers(),
					// hover / 按下的整片着色。**放在高光层之下**：上下那两道高光是镜面反射，
					// 不该被"鼠标移上去"改掉；系统那组 Δ 也是量按钮腰部（本体）得来的，
					// 所以 alpha 也只该按本体算。闲时 transparent，由 @property 兜底。
					"    inset 0 0 0 100px var(--clam-tint),",
					"    inset 14px 0 8px -15px var(--clam-glass-side),",
					"    inset -14px 0 8px -15px var(--clam-glass-side);",
					"}",

					// 强调键的高光要跟着它自己的色走，不能用白的。
					// 白高光在近白的玻璃上第一行只抬 3.1 级（看不见），压到饱和蓝上抬 51.3 级 ——
					// 硬边几何叠层只在底色与高光颜色接近时才连续，底色一饱和立刻变成条带，
					// 那圈"贴上去的白帽子"就是这么来的。**改底色不改高光等于没修。**
					//
					// 值取自系统实测的 .glassEffect(.regular.tint(.blue))：峰值是同色系更亮的一档
					// （浅 #00C0FF / 深 #00CBFF），不是白 —— 蓝键的 R 通道从头到尾是 0，
					// 掺白会把 R 拉起来，对不上。衰减也比无色档慢（.5 对 .45）。
					//
					// 这里写死了蓝：dsh 的强调色藏在 --dsw-alias-brand-primary → neutral-bluish
					// 的别名链后面，而高光变量吃的是"通道三元组"（配 rgb(... / calc(...))），
					// 塞不进一个 var(--色)。dsh 换主题色的话这圈边会偏色，到那时再说。
					tinted + " {",
					"  --clam-glass-glow-c: 0 192 255;",
					"  --clam-glass-glow-t: 0.6;",
					"  --clam-glass-glow-b: 0.6;",
					"  --clam-glass-glow-d: 0.5;",
					"}",
					"body[data-ds-dark-theme] " + tinted + " {",
					"  --clam-glass-glow-c: 0 203 255;",
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
					// 不是聚成一小块。位置仍然跟着 --clam-px/--clam-py 走（渐变中心在手指底下，
					// 只是摊得很开）。这一行留着是为了把"不收拢"写在用它的地方，改回收拢就调它。
					"  --clam-press-r: 150%;",
					"  --clam-press-a: var(--clam-press-glow);",
					"  transition-duration: var(--clam-dur-press) !important;",
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
					// **没注册的自定义属性不参与插值**，会直接跳变。位置走 --clam-px/--clam-py，
					// 由 watchPressPoint() 喂；拿不到指针时兜底 50% 50%。
					//
					// **走 background-image 而不是 ::after**：伪元素盖在内容之上，浅色档那点
					// 白光会把按钮文字一起冲淡（实测过，"Session log" 直接发虚）。background-image
					// 这一层在 background-color 之上、内容之下，文字纹丝不动。代价是两条：
					// 它会覆盖 dsh 自己的 background-image（这几个按钮目前都是纯色，没有渐变），
					// 而且 inset 阴影画在背景之上，玻璃底色那层会把亮光吃掉一半 —— 后者反而
					// 更对：光是从材料内部透出来的，不是糊在玻璃表面。
					// 不注册它，闲时 var(--clam-tint) 解析不出来会让**整条 box-shadow 失效**，
					// 玻璃表面直接消失。注册成 <color> 顺带也让它自己可插值。
					"@property --clam-tint {",
					"  syntax: \"<color>\";",
					"  inherits: false;",
					"  initial-value: transparent;",
					"}",
					"@property --clam-press-r {",
					"  syntax: \"<percentage>\";",
					"  inherits: false;",
					"  initial-value: 150%;",
					"}",
					"@property --clam-press-a {",
					"  syntax: \"<color>\";",
					"  inherits: false;",
					"  initial-value: transparent;",
					"}",
					solid + " {",
					// !important 是必须的：`background` 简写会把 background-image 一起清掉，
					// dsh 只要在哪条更具体的规则里用了简写（发送键那种实心色最容易），亮光就
					// 整个没了，而且是静默的 —— 不报错、不留痕。
					"  background-image: radial-gradient(circle at var(--clam-px, 50%) var(--clam-py, 50%),",
					"    var(--clam-press-a) 0%, transparent var(--clam-press-r)) !important;",
					"}",

					// 悬停：整面着色（浅色变暗 / 深色提亮，见上面两组 tint 变量），
					// 外加把贴地投影抬高一档（"浮起来"）。表面其余层原样保留 ——
					// box-shadow 是整体覆盖的，所以这里必须重抄 var(--clam-surface)。
					solidHover + " {",
					"  --clam-tint: var(--clam-tint-hover);",
					"  box-shadow: var(--clam-surface), 0 2px 5px var(--clam-glass-drop);",
					"}",
					// **实心强调键不参与 hover**：系统实测 .glassProminent 悬停零变化
					// （浅深两档、逐像素 diff 都是空的，且 .onHover 指示灯确认游标确实到位）。
					// 选择器与上一条同特异性，靠源码顺序覆盖。投影那一档保留。
					'button[class*="_primary"]' + ENABLED + ':hover {',
					"  --clam-tint: transparent;",
					"}",
					// 按下：着色加深一档 + 投影压回去（贴地），配合容器放大，像被按进桌面。
					// 排在 hover 之后，所以两态同时命中时这条赢（含上面那条 _primary 的清零）。
					solidActive + " {",
					"  --clam-tint: var(--clam-tint-press);",
					"  box-shadow: var(--clam-surface), 0 0 1px var(--clam-glass-drop);",
					"}",

					// 尊重"减少动态效果"：关掉形变，保留配色反馈。
					"@media (prefers-reduced-motion: reduce) {",
					"  " + solidActive + " { scale: 1 !important; }",
					"  " + solidActive + " { --clam-press-r: 100% !important; }",
					"}",

					...headerRules(),
				];
				style.textContent = rules.join("\n");
				document.head.appendChild(style);
				return () => { style.remove(); };
			});

			// 字体那一层。**首帧就用默认值把它装上**，不等任何服务——见文件尾
			// `exports.inject = []` 那条注释：这段 CSS 的全部意义就是抢在首帧之前
			// 生效。设置到位之后再改字号，用户看到的是"字号跳一下"，而不是
			// "整页字先是 dsh 的原样、过一会儿才原生化"。
			ctx.effect(() => {
				document.getElementById(FONT_STYLE_ID)?.remove();
				const style = document.createElement("style");
				style.id = FONT_STYLE_ID;
				style.textContent = fontRules(body).join("\n");
				document.head.appendChild(style);
				fontStyle = style;
				return () => {
					// **只在还是自己那张时才清引用**：HMR 的重载顺序是"新实例先启、
					// 旧实例后清"，无条件置 null 会把新实例刚装好的那张抹掉，
					// 于是新实例后续的设置变更再也写不进 DOM（CLAUDE.md 踩坑记录）。
					if (fontStyle === style) fontStyle = null;
					style.remove();
				};
			});

			// 设置面：`clam-nativeify` 这个命名空间由本包的 node 半边注册，
			// 原生设置窗口与 dsh 页内设置都会自动列出它（一个都不用改）。
			//
			// **运行时嵌套 inject，不是 `exports.inject`**：静态依赖会把上面那两张
			// style 一起推迟到 settingsScope 就绪之后，那正是文件尾那条注释要避免的
			// 首帧闪动。缺席（远程浏览器的设置 RPC 只走 loopback，那边永远缺席）
			// 时字号就一直是默认值——退化，不是故障。
			ctx.inject(["settingsScope"], (scoped) => {
				const scope = scoped.settingsScope.bind({ namespace: "clam-nativeify" });
				const sync = () => {
					const snap = scope.getSnapshot();
					// `loading` / `unavailable` 时 value 还没有意义，退到默认值。
					const next = clampBody(snap.status === "ready" ? snap.value?.bodyFontSize : BODY_DEFAULT);
					if (next === body) return;
					body = next;
					if (fontStyle) fontStyle.textContent = fontRules(next).join("\n");
				};
				scoped.effect(() => scope.subscribe(sync));
				sync();
			});
		}

		exports.apply = apply;
		// 顶层留空是刻意的：这段 CSS 的全部意义就是抢在首帧之前生效。挂上任何
		// 硬依赖都会把它推迟到那些服务就绪之后，且服务重载会连带本插件卸载重挂
		// （= 用户能看见的一次背景闪动）。
		//
		// 本插件唯一够得着的服务是 `settingsScope`（对话区字号），而它**必须**是
		// 可选的——所以走 apply 里的运行时嵌套 `ctx.inject`，不进这张表。
		exports.inject = [];
		return module.exports;
	}
});
