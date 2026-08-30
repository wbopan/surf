/**
 * clam-memory —— 给 dsh 加一个跨会话的持久记忆。
 *
 * 一目录 markdown，每条一个文件、带 frontmatter；每步把**索引**（name + description）
 * 注入上下文，正文由模型按需 `memory_read`，写入由模型自己 `memory_write` 发起。
 *
 * **纯 node 插件，零 macOS 依赖**（计划 §0 不变量 0）：不 inject `clamBridge`，
 * 没有 `swift/`，不碰壳也不碰 WebView。名字留在 `clam-*` 家族里只是出身，不是耦合
 * ——任何一台装了 dsh 的机器（含 Linux）都该能单独 `dsh plugin add` 它。
 *
 * 本文件只做**接线**：三样东西（注入、两个工具、设置 ns）各自往 dsh 的哪个口子插。
 *   - 面向模型的文案全在 `./prompt.js`；
 *   - 路径决议、frontmatter、索引组装、上限截断、路径加固全在 `./store.js`。
 * 这里出现的每一处 dsh API 事实都在下面就地注了源码位置，别再去猜。
 *
 * 权威计划：docs/clam-memory-plan.md（尤其 §1.1 注入通道、§2.4 工具、§2.6 三处决策）。
 */

import z from "@deepseek-ai/schemastery";
import { defineTool } from "@deepseek-ai/dsh-tools";

import { MEMORY_TYPES, createMemoryStore } from "./store.js";
import {
	MEMORY_READ_DESCRIPTION,
	MEMORY_READ_PARAM_NAME,
	MEMORY_WRITE_DESCRIPTION,
	MEMORY_WRITE_PARAM_CONTENT,
	MEMORY_WRITE_PARAM_DESCRIPTION,
	MEMORY_WRITE_PARAM_NAME,
	MEMORY_WRITE_PARAM_TYPE,
	renderInjection,
	renderOversizeWarning,
} from "./prompt.js";

export const name = "clam-memory";

// `settings` **不在**这张表里：它走 apply 内部的运行时嵌套 inject（见下），
// 缺席时插件照常挂载，只是没有那一格设置界面。静态 inject 的语义是"服务不在就
// 整个插件不挂载"，而记忆的全部价值与设置界面无关。
export const inject = ["systemPrompt", "tools"];

export const Config = z.object({
	// 编排表里给的缺省目的地。语义与设置 ns 的 `dir` 逐字相同（见 SETTINGS_SCHEMA）。
	dir: z.string().default(""),
});

/** 设置 ns 名。`^[a-z][a-z0-9-]*$`（dsh-settings/lib/index.js:81 NAMESPACE_PATTERN）。 */
const SETTINGS_NS = "clam-memory";

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

/** 注入项的名字。同一 layer 内唯一（dsh-system-prompt/lib/index.js:198 `contexts.insert`）。 */
const CONTEXT_NAME = "clam-memory:index";

/**
 * 注入项的排序。
 *
 * dsh 现存住户：`sandbox:policy`=110、`approval:policy`=115、**`subagent:delegation`=120**
 * （dsh-subagent/lib/index.js:572，只注册在子代理的 childCtx 上）。计划里写的 120 会在
 * 子代理会话里与它撞成并列——`sort` 稳定，不会报错，但先后就成了注册顺序的副产物。
 * 取 125 让它无歧义地排在最后：记忆是最"软"的那一段，放在策略之后读着也对。
 */
const CONTEXT_ORDER = 125;

/**
 * `ctx.logger` 在 `dsh web` 下没有 exporter，消息只进环形缓冲、终端一个字看不见
 * （CLAUDE.md 踩坑记录）。要给终端前的人看的东西自己写 stderr，两边都喂最保险。
 * @param {object} ctx cordis 上下文。
 * @param {string} message 一行，不带换行。
 */
function note(ctx, message) {
	process.stderr.write(`clam-memory: ${message}\n`);
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
 * @param {object} ctx cordis 上下文（已注入 systemPrompt / tools）。
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
	// 写法照抄 clam-nativeify/lib/index.js:103-128。静态 `export const inject` 会让
	// settings 缺席时整个插件不挂载——那是把"少一格界面"升级成了"没有记忆"。
	// （这个 cordis fork 的 inject 没有 {required, optional} 形态，嵌套是表达
	// 可选依赖的唯一方式。）
	ctx.inject(["settings"], (scoped) => {
		// 注册一个 ns 就等于同时点亮两个界面、两边都不用改一行：clam-settings 那扇
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

	// ── 注入：走 B（`systemPrompt.context()`）────────────────────────────
	//
	// 计划 §2.6 D1 的裁决。B 落成会话历史里的 durable user 快照，框架白送四件事：
	// 去重（文本没变返回 undefined）、取代（"supersedes earlier runtime-context
	// snapshots"）、清空（CLEARED 墓碑）、**resume 后从 session events 恢复基线**。
	// 所以这里**不要**自己写 digest、也不要去扫 `agent.session.events`——
	// skill catalog 那套（走 C）之所以要自己写，只因为它的快照源是异步的，我们不是。
	//
	// **`text` 是同步的**（dsh-system-prompt/lib/index.js:271,278 —— assemble 里
	// `typeof entry.text === "function" ? entry.text(context) : entry.text`，没有 await），
	// 所以这里**绝不能做 IO**：只读 store 的内存缓存。
	ctx.systemPrompt.context({
		name: CONTEXT_NAME,
		order: CONTEXT_ORDER,
		text: (assembleContext) => {
			// `context.agent` 可能缺席（诊断装配、裸 `assemble()`）。没有会话就没有
			// cwd，也就没有"哪个项目的记忆"这回事——整段消失。
			const agent = assembleContext?.agent;
			if (agent === undefined) return "";
			try {
				const cwd = cwdOf(agent);
				const index = store.index(cwd);
				// 返回 "" = 这一段整体消失（renderContextSections 过滤空文本）。
				// 计划 §0 不变量 3：记忆目录为空时**零注入**，不留空壳标签。
				return renderInjection({
					pinned: store.pinned(cwd),
					entries: index?.entries ?? [],
					truncated: index?.truncated ?? null,
				});
			} catch (error) {
				// 装配失败会赔掉整个 agent step。记忆是可选的锦上添花，**绝不能**
				// 因为一个坏掉的 frontmatter 让人连话都说不了：吞掉、报到 stderr、
				// 这一步当作没有记忆。
				noteOnce(ctx, error);
				return "";
			}
		},
	});

	// ── 工具 ──────────────────────────────────────────────────────────────
	//
	// 参数 schema 是 dsh 自己的 `ParameterSchemaSpec` DSL：每个属性
	// `{ type, required?, description, enum? }`，显式 object 必须写
	// `additionalProperties`。**不是** schemastery，**不是**裸 JSON Schema。
	// `output` 是强制的：`execute` 返回 canonical JSON，registry 校验冻结后
	// 由 `render` 投成模型真正看到的文本。
	// description 与 parameters **自动**进 prompt，这里什么都不用做。

	ctx.tools.register(
		defineTool({
			name: "memory_read",
			description: MEMORY_READ_DESCRIPTION,
			parameters: {
				name: {
					type: "string",
					required: true,
					description: MEMORY_READ_PARAM_NAME,
				},
			},
			output: {
				schema: {
					type: "object",
					additionalProperties: false,
					properties: {
						found: { type: "boolean", required: true },
						name: { type: "string", required: true },
						description: { type: "string" },
						type: { type: "string" },
						content: { type: "string" },
					},
				},
				render: (_args, value) => [
					{
						type: "text",
						text: value.found
							? `Memory \`${value.name}\`${value.type ? ` (${value.type})` : ""}\n\n${value.content ?? ""}`
							: `No memory named \`${value.name}\`. Names must match the memory index exactly.`,
					},
				],
			},
			execute(args, exec) {
				const record = store.read(args.name, cwdOf(exec.agent));
				if (record === undefined) return Promise.resolve({ found: false, name: args.name });
				return Promise.resolve({
					found: true,
					name: record.name,
					...(record.description === undefined ? {} : { description: record.description }),
					...(record.type === undefined ? {} : { type: record.type }),
					content: record.content ?? "",
				});
			},
			presentCall: (args) => ({
				card: "generic",
				title: `Read memory ${args.name}`,
				kind: "read",
				rawInput: args,
			}),
		}),
	);

	ctx.tools.register(
		defineTool({
			name: "memory_write",
			description: MEMORY_WRITE_DESCRIPTION,
			parameters: {
				name: { type: "string", required: true, description: MEMORY_WRITE_PARAM_NAME },
				description: {
					type: "string",
					required: true,
					description: MEMORY_WRITE_PARAM_DESCRIPTION,
				},
				type: {
					type: "string",
					required: true,
					enum: [...MEMORY_TYPES],
					description: MEMORY_WRITE_PARAM_TYPE,
				},
				content: { type: "string", required: true, description: MEMORY_WRITE_PARAM_CONTENT },
			},
			// **没有 `pinned` 参数，这是设计**（计划 §2.6 D3）：pinned 决定什么被全文
			// 常驻注入，那是人的决定，模型写不了。ETH 那条证据（模型生成的常驻上下文
			// 可能是负收益）说的正是这件事——索引行错了只值一行，pinned 全文错了不止。
			//
			// **也没有 `memory_delete`**（计划 §2.4）：删除不可逆，而"这条过时了"是本
			// 设计里模型判断最没把握的一环。过时就同名 `memory_write` 覆盖；真要删，
			// 用户那边是一条 `rm`。
			output: {
				schema: {
					type: "object",
					additionalProperties: false,
					properties: {
						name: { type: "string", required: true },
						bytes: { type: "integer", required: true },
						created: { type: "boolean", required: true },
						dir: { type: "string", required: true },
						// 超过召回显示上限时才有。**写入照样成功**——见 execute。
						warning: { type: "string" },
					},
				},
				render: (_args, value) => [
					{
						type: "text",
						text:
							`${value.created ? "Created" : "Replaced"} memory \`${value.name}\` ` +
							`(${value.bytes} bytes) in ${value.dir}. ` +
							"It will appear in the memory index of future sessions in this project." +
							(value.warning ? `\n\n${value.warning}` : ""),
					},
				],
			},
			execute(args, exec) {
				// 写入要盖 `originSessionId`，没有会话就没有作者——fails loud，
				// 和 `todo_write` 对无主调用的处理同款。
				if (!exec.agent) throw new Error("memory_write requires an owning agent session");
				const cwd = cwdOf(exec.agent);
				const existed = store.read(args.name, cwd) !== undefined;
				// slug / description 非空 / type 枚举的校验全在 store 里；
				// 违规它自己抛，错误经正常的 tool-error 路径回到模型面前。
				// `modified` / `originSessionId` / `node_type` 由 store 盖，不由模型写
				// （计划 §2.2），`pinned` 出现在 rec 里会被它当场拒（D3）。
				// store.write 自己 invalidate，所以刚写完的那条下一步就在索引里了
				// ——不然模型会以为写失败、再写一遍。
				const written = store.write(
					{
						name: args.name,
						description: args.description,
						type: args.type,
						content: args.content,
						sessionId: exec.agent.session?.header?.id ?? exec.agent.id,
					},
					cwd,
				);
				// **4096 是"召回显示上限"，不是"写入上限"**——实测本机 190 条真实
				// Claude 记忆里 29 条（15%）超过它，最大 13 KB。硬拒绝会让我们连
				// Claude Code 自己写下的大记忆都改不动（"claude" 模式是读写同一份）。
				// 所以超限**写入照样成功**，只在回执后面附一句"你以后看不到后面那段"。
				const recallLimit = store.limits?.recordBytes ?? 4096;
				const warning =
					typeof written.warning === "string"
						? written.warning
						: written.bytes > recallLimit
							? renderOversizeWarning(written.bytes, recallLimit)
							: undefined;
				return Promise.resolve({
					// 报 store 数出来的字节（**整个文件**，含 frontmatter），因为
					// 召回上限量的就是它——报正文长度会让模型对着一个和上限
					// 不同量纲的数字做取舍。
					name: written.name,
					bytes: written.bytes,
					created: !existed,
					dir: store.resolveDir(cwd),
					...(warning === undefined ? {} : { warning }),
				});
			},
			presentCall: (args) => ({
				card: "generic",
				title: `Remember ${args.name}`,
				kind: "other",
				rawInput: { name: args.name, description: args.description, type: args.type },
			}),
		}),
	);

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
