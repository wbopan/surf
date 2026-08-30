/**
 * surf-memory —— 给 dsh 加一个跨会话的持久记忆。
 *
 * 一目录 markdown，每条一个文件、带 frontmatter；每步把**索引**（name + description）
 * 注入上下文，正文与写入都交给模型手里的普通文件工具（`read` / `write` / `edit` /
 * `grep`）——记忆就是普通 markdown，本插件不提供任何专用工具（2026-08-30 起，
 * 见 README「为什么没有专用工具」与计划 §8 执行日志）。
 *
 * **注入走 C 通道**（`agent/pre-step` 里自己发一条 durable user 消息），不是
 * `systemPrompt.context()`。B 通道会把所有贡献者合并成一条署名
 * `@deepseek-ai/dsh-system-prompt` 的快照，我们在界面上就没有自己的名字；走 C
 * 才能像 CLAUDE.md 与 skill-catalog 那样独立成一行。实现照抄 `dsh-tool-skill`
 * 的 skill catalog（计划 §1.2 拆解过它那四条设计）。
 *
 * **纯 node 插件，零 macOS 依赖**（计划 §0 不变量 0）：不 inject `surfBridge`，
 * 没有 `swift/`，不碰壳也不碰 WebView。名字留在 `surf-*` 家族里只是出身，不是耦合
 * ——任何一台装了 dsh 的机器（含 Linux）都该能单独 `dsh plugin add` 它。
 *
 * 本文件只做**接线**：两样东西（注入、设置 ns）各自往 dsh 的哪个口子插。
 *   - 面向模型的文案全在 `./prompt.js`（读者视角的信封 + 作者视角的维护段）；
 *   - 路径决议、frontmatter、索引组装、上限截断全在 `./store.js`。
 * 这里出现的每一处 dsh API 事实都在下面就地注了源码位置，别再去猜。
 *
 * 权威计划：docs/archive/surf-memory-plan.md（尤其 §1.1 注入通道、§2.6 三处决策、§8 执行日志）。
 */

import { createHash } from "node:crypto";

import z from "@deepseek-ai/schemastery";
import { createUserMessage } from "@deepseek-ai/dsh-llm";

import { createMemoryStore } from "./store.js";
import { joinSections, renderSections } from "./prompt.js";

export const name = "surf-memory";

// `settings` **不在**这张表里：它走 apply 内部的运行时嵌套 inject（见下），
// 缺席时插件照常挂载，只是没有那一格设置界面。静态 inject 的语义是"服务不在就
// 整个插件不挂载"，而记忆的全部价值与设置界面无关。
//
// **`tools` 也不在**：2026-08-30 删掉了 `memory_read` / `memory_write` 两个专用
// 工具，模型改用 dsh 自带的 `read` / `write` / `edit` / `grep` 直接操作记忆文件
// （它们本来就是普通 markdown）。理由与代价见 README「为什么没有专用工具」。
//
// **`systemPrompt` 也不在了**：注入换成 C 通道（`ctx.on("agent/pre-step")`），
// 不再经 `systemPrompt.context()`。`agents` 与范本 `dsh-tool-skill` 一致——
// 没有 agent 子系统就没有会话，也就没有"哪个项目的记忆"这回事。
export const inject = ["agents"];

export const Config = z.object({
	// 编排表里给的缺省目的地。语义与设置 ns 的 `dir` 逐字相同（见 SETTINGS_SCHEMA）。
	dir: z.string().default(""),
});

/** 设置 ns 名。`^[a-z][a-z0-9-]*$`（dsh-settings/lib/index.js:81 NAMESPACE_PATTERN）。 */
const SETTINGS_NS = "surf-memory";

/**
 * ns schema 用的是 **schemastery `z`**（`@deepseek-ai/schemastery`），不是 zod。
 * dsh 里路径类设置一律裸 `z.string()`——没有 path role，别去造一个。
 */
const SETTINGS_SCHEMA = z.object({
	dir: z
		.string()
		.default("")
		.description(
			"记忆目录。留空 = dsh 自持（<dsh home>/memory/<项目>/）；" +
				'填 "claude" = 直接复用 Claude Code 的记忆目录，与它共享同一份；' +
				"其它值当作绝对路径（支持 ~）。",
		),
});

/**
 * 我们这条消息的 `source.kind`。
 *
 * Web UI 的 `contextProvenance` 对不认识的 kind 走 **default 分支，直接拿 kind 当标签**
 * （dsh-client-runtime/lib/client.js:10443），所以界面上显示成
 * `Context injection · surf-memory`——和 `CLAUDE.md`、`skill-catalog` 平起平坐。
 * 源码注释明确说这是留给"更新的或外部的生产者"的向前兼容路径，不认识的值降级成
 * 朴素展示而**不是丢掉那一行**。
 */
const SOURCE_KIND = "surf-memory";

/**
 * `source.form`。`"snapshot"` 在 UI 的 `KNOWN_FORMS` 白名单里
 * （dsh-client-runtime/lib/client.js:10452），于是走 `SnapshotBody`：把
 * `source.sections` 渲染成 `<dl>`，每段一个 `<dt>`（段名）+ `<dd>`（正文），
 * 顶上还有一句「取代先前的快照」——正是我们的语义（整表替换，不是增量）。
 */
const SOURCE_FORM = "snapshot";

/**
 * `ctx.logger` 在 `dsh web` 下没有 exporter，消息只进环形缓冲、终端一个字看不见
 * （CLAUDE.md 踩坑记录）。要给终端前的人看的东西自己写 stderr，两边都喂最保险。
 * @param {object} ctx cordis 上下文。
 * @param {string} message 一行，不带换行。
 */
function note(ctx, message) {
	process.stderr.write(`surf-memory: ${message}\n`);
	ctx.logger?.info?.(message);
}

/**
 * 从一次装配上下文里取会话 cwd。
 *
 * `context.agent?.session.header.cwd` 是 dsh 全库的惯用取法
 * （dsh-agent-loop/lib/index.js:1026 的 `cwd` 变量、dsh-tool-skill/lib/index.js:119）；
 * `header.cwd` 本身可选，缺席时退到进程 cwd（dsh-agent-instructions/lib/index.js:900 同款）。
 * @param {object | undefined} agent 装配上下文或执行上下文里的 agent。
 * @returns {string} 该会话的工作目录。
 */
function cwdOf(agent) {
	return agent?.session?.header?.cwd ?? process.cwd();
}

/**
 * @param {object} ctx cordis 上下文（已注入 agents）。
 * @param {{ dir: string }} config 编排表给的配置。
 */
export function apply(ctx, config) {
	// ── 存储层句柄 ────────────────────────────────────────────────────────
	//
	// `dir` 是**可变的**：设置 ns 一改就换一个 store。下面所有闭包都读这两个 let，
	// 不要在任何地方把 `store` 捕获成常量。
	let dir = config.dir ?? "";
	let store = createMemoryStore({ dir });

	// ── 设置 ns：运行时嵌套 inject ────────────────────────────────────────
	//
	// 写法照抄 surf-nativeify/lib/index.js:103-128。静态 `export const inject` 会让
	// settings 缺席时整个插件不挂载——那是把"少一格界面"升级成了"没有记忆"。
	// （这个 cordis fork 的 inject 没有 {required, optional} 形态，嵌套是表达
	// 可选依赖的唯一方式。）
	ctx.inject(["settings"], (scoped) => {
		// 注册一个 ns 就等于同时点亮两个界面、两边都不用改一行：surf-settings 那扇
		// 原生窗口（「插件 → 插件配置」把 `describe()` 里的每个 ns 一视同仁地列出来），
		// 以及 dsh 自己的页内设置对话框。
		const scope = scoped.settings.register(SETTINGS_NS, SETTINGS_SCHEMA, {
			// 改完立刻生效：换目录只是换一个 store 句柄，下一步装配就读新目录。
			applies: "live",
		});

		/**
		 * ns 的值**优先于** Config：ns 是用户在设置界面里改的，编排表是部署方给的缺省。
		 * 空串不算"有值"（它就是 schema 的 default），那时退回 Config。
		 * @param {{ dir?: string } | undefined} value ns 的解析值。
		 */
		const adopt = (value) => {
			const raw = typeof value?.dir === "string" ? value.dir.trim() : "";
			const next = raw.length > 0 ? raw : config.dir ?? "";
			if (next === dir) {
				// 目录没变也要清缓存：磁盘可能被别的进程改过（"claude" 模式下
				// Claude Code 就是那个别的进程），而设置被保存往往正是人刚动过手的时刻。
				store.invalidate();
				return;
			}
			dir = next;
			store = createMemoryStore({ dir });
			note(ctx, `记忆目录改为 ${dir === "" ? "dsh 自持" : JSON.stringify(dir)}`);
		};

		adopt(scope.get());
		// `watch` 是 ns owner 自己的通道（dsh-settings/lib/index.js:331），签名
		// `(next, prev)`，只在解析后的值真的变了时触发——比全局 `settings/updated`
		// 少一层自己按 ns 过滤，且随本 fiber 一起释放。
		scope.watch((next) => adopt(next));
	});

	// ── 注入：走 C（`agent/pre-step` 里自己发一条 durable user 消息）────────
	//
	// 为什么不是 B（`systemPrompt.context()`）：B 把所有贡献者**合并成一条**署名
	// `@deepseek-ai/dsh-system-prompt` 的快照（`joinContextSections`），界面上我们
	// 没有自己的名字，只能作为其中一个 `sections` 条目存在。走 C 才能像 CLAUDE.md
	// （kind=agent-instructions）与 skill-catalog（kind=skill-catalog）那样独立成行。
	// 代价是 B 白送的四件事要自己写，下面逐一对应：
	//   去重/取代 → digest 比对 + 替换 existing；清空 → 目录空了照发（内容变成
	//   "no memories yet"）；**resume 后恢复基线 → `memoryHistory` 倒扫
	//   `agent.session.events`**，不依赖任何进程内缓存。
	//
	// 四条设计逐条抄自 `dsh-tool-skill`（计划 §1.2）：digest 算在**结构化事实**上
	// 而不是渲染后的散文、消息带结构化 `source`、基线从 session events 得到、
	// 整表替换而不是 diff。
	//
	// 这里**可以做 IO**（hook 是 async），不像 B 的 `text` 那样被同步性捆住——
	// 但 store 本来就是同步的，照用不误。
	ctx.on("agent/pre-step", async ({ agent, signal }, next) => {
		const decision = await next();
		if (decision.kind === "reject") return decision;
		signal.throwIfAborted();

		let sections;
		let digest;
		try {
			const cwd = cwdOf(agent);
			// 目录必须存在：模型是用普通 `write` 工具往里写的，而注入文本里那句
			// "The directory already exists; do not create it" 得是真的。
			const dir = store.ensureDir(cwd);
			const index = store.index(cwd);
			const snapshot = {
				dir,
				pinned: store.pinned(cwd),
				entries: index?.entries ?? [],
				truncated: index?.truncated ?? null,
			};
			sections = renderSections(snapshot);
			digest = digestSnapshot(snapshot);
		} catch (error) {
			// 一个坏掉的 frontmatter 绝不能赔掉整个 agent step：吞掉、报到 stderr、
			// 这一步当作没有记忆（decision 原样放行）。
			noteOnce(ctx, error);
			return decision;
		}
		// 空数组只发生在没有会话、因而没有 cwd 的时候。**记忆为空不在此列**：
		// 那时仍有维护段，它是模型知道"有记忆这回事"的唯一信号。
		if (sections.length === 0) return decision;

		const history = memoryHistory(agent);
		const existing = existingMessage(decision.messages);

		// 历史里可见的那条已经是这份内容 → 不重发；顺手撤掉本次多出来的那条。
		if (history.visibleDigest === digest) {
			return existing === undefined
				? decision
				: { kind: "enter", messages: decision.messages.filter((message) => message.id !== existing.message.id) };
		}
		// 本次 decision 里已经有一条同内容的 → 什么都不用做。
		if (existing !== undefined && existing.digest === digest) return decision;

		const message = renderMemoryMessage(sections, digest);
		return {
			kind: "enter",
			messages:
				existing === undefined
					? [...decision.messages, message]
					: decision.messages.map((item) => (item.id === existing.message.id ? message : item)),
		};
	});

	note(ctx, `已挂载（目录：${dir === "" ? "dsh 自持" : JSON.stringify(dir)}）`);
}

/**
 * 装配路径上的错误去重报告。
 *
 * 装配**每 step 一次**，一个坏文件会让同一条错误刷屏；只在消息变了时才打印一次。
 * @param {object} ctx cordis 上下文。
 * @param {unknown} error 抛出来的东西。
 */
let lastInjectionError;
function noteOnce(ctx, error) {
	const message = error instanceof Error ? error.message : String(error);
	if (message === lastInjectionError) return;
	lastInjectionError = message;
	note(ctx, `装配记忆索引失败，本步跳过记忆：${message}`);
}

/**
 * 快照的身份，算在**结构化事实**上而不是渲染后的散文。
 *
 * 抄 `dsh-tool-skill` 的 `digestCatalogEntries`，它的注释解释了为什么：信封文案是
 * 写给模型的，改文案不该导致每个在跑的会话都重发一遍记忆。变的是事实——目录、
 * pinned 的正文、索引条目、截断状态。
 *
 * @param {{ dir: string, pinned: Array<object>, entries: Array<object>, truncated: object|null }} snapshot
 * @returns {string} sha256 hex。
 */
function digestSnapshot(snapshot) {
	const canonical = JSON.stringify([
		snapshot.dir,
		snapshot.pinned.map((memory) => [memory.name, memory.content]),
		snapshot.entries.map((entry) => [entry.name, entry.description]),
		snapshot.truncated,
	]);
	return createHash("sha256").update(canonical).digest("hex");
}

/**
 * 从一条消息的 source 里读回 digest。
 *
 * **这里存 digest 而不是像 skill-catalog 那样存结构化 entries**：pinned 是**全文**，
 * 少则几百字节多则几 KB，而 `content` 里已经有一份——再存一遍等于把每条消息撑成
 * 两倍。sections 仍然在 source 里（UI 要用它分段），所以"真相在 source 里"这条没丢。
 *
 * 读不出来就当"不是我们的消息"而不是抛：`agent.session.events` 可能是 resume、
 * fork 或外部写入的种子，种子校验只保证 source 是个 kind 非空的对象。在 step
 * 监听器里抛会让那个会话之后每一轮都失败。
 */
function readDigest(source) {
	if (typeof source !== "object" || source === null) return undefined;
	const digest = source.digest;
	return typeof digest === "string" && digest !== "" ? digest : undefined;
}

/**
 * 从会话事件里恢复基线：**最近一条仍然可见的**本插件消息的 digest。
 *
 * 倒扫是为了拿最近的那条；`session.surface.nodes` 是当前可见的 seq 集合——被压缩
 * 藏起来的旧消息不算数，那时应当重发。跨 resume 幂等，不依赖任何进程内状态。
 */
function memoryHistory(agent) {
	const visible = new Set(agent.session.surface.nodes);
	const events = agent.session.events;
	for (let index = events.length - 1; index >= 0; index -= 1) {
		const event = events[index];
		if (event.type !== "user/message" || event.data?.source?.kind !== SOURCE_KIND) continue;
		const digest = readDigest(event.data.source);
		if (digest === undefined) continue;
		if (visible.has(event.seq)) return { visibleDigest: digest };
	}
	return {};
}

/** 本次 decision 里已有的本插件消息（同一 step 内可能已经加过一条）。 */
function existingMessage(messages) {
	for (const message of messages) {
		if (message.source?.kind !== SOURCE_KIND) continue;
		const digest = readDigest(message.source);
		if (digest !== undefined) return { message, digest };
	}
	return undefined;
}

/**
 * 造那条 durable user 消息。
 *
 * `content` 是模型读到的整段；`source.sections` 是同一份内容的分段形态，供 Web UI
 * 逐段展示（每段一个 `<dt>`/`<dd>`）。两者由 `joinSections` 保证同源。
 */
function renderMemoryMessage(sections, digest) {
	return createUserMessage({
		content: [{ type: "text", text: joinSections(sections) }],
		source: { kind: SOURCE_KIND, form: SOURCE_FORM, sections, digest },
	});
}
