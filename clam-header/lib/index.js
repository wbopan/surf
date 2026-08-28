/**
 * clam-header —— 原生会话 header。
 *
 * 主内容区顶部那条 header（面包屑标题、`Chat | Trajectory` 标签、mode、
 * `Session log`）搬进原生工具栏的**内容侧**，网页那条就地折叠。
 *
 * ## 三个半边各管什么
 *
 * | 半边 | 管什么 | 为什么在这儿 |
 * |---|---|---|
 * | `lib/client.js` | tabs 的投影与驱动、折叠 CSS | active view 是 ui-conversation 的**私有客户端状态**，dsh 侧没有任何对应物，只有 DOM 能读能写（理由详见该文件模块注释） |
 * | `lib/index.js`（本文件） | 面包屑 / mode / 导出 / jobs 的数据面 | 这几样在 dsh 侧都有一等契约（RPC 或事件流），照 clam-sidebar 的路子订 `ctx.apiProxy` |
 * | `swift/` | 画，以及把动作发回来 | 同 clam-sidebar：Swift 只管画和发 |
 *
 * **两条数据通道并存不是重复**，是两类事实的分野：凡浏览器独有的 UI 状态走
 * 页内桥（client.js → 壳 → 事件总线），凡 dsh 拥有的领域事实走本文件 → 桥。
 * 判据是"这个事实的真相住在哪个进程里"。
 *
 * ## 桥协议
 *
 * 下行（`push(channel, payload)`）：
 *
 * | 频道 | 载荷 | 什么时候 |
 * |---|---|---|
 * | `snapshot` | `{version, session}` | 焦点会话的 header 事实变了；`session` 为 null = 无焦点 |
 * | `error` | `{action, code?, message}` | 写动作抛错（Swift 记一行日志） |
 *
 * **`error` 帧里一个显示文案都没有**（计划 §8-4，与 clam-sidebar 同一份协议）：
 * `action` 是动作 id、`code` 是我们自己认领得了的失败原因码（`notReady` /
 * `apiMissing`，见 `dsh-source.js` 的 `SourceError`），`message` 是上游那句原话。
 * node 不知道界面是哪种语言，也不该知道。
 *
 * `session` 的字段：`{id, crumbs:[{id,title,subagent}], preset, presets, jobs}`。
 *
 * 上行（Swift `bridge.send(action:payload:)`）：
 *
 * | 动作 | 载荷 |
 * |---|---|
 * | `focus` | `{sessionId}`（当前会话变了；null 清空） |
 * | `snapshot` | `{}`（请求全量重发） |
 * | `selectPreset` | `{sessionId, agentPreset}` |
 *
 * **当前会话从哪来**：`ClamEventBus.Topic.pageCurrentSession`——页内桥的公共
 * 通道（SDK 的公开常量），Swift 半身订到之后经 `focus` 动作告诉这边。
 * node 侧自己是不知道的：「哪个会话正被看着」是浏览器的 UI 状态，不是 dsh 的
 * 领域事实。
 *
 * @module clam-header
 */
import { createSwiftPlugin } from "../../clam-bridge/lib/plugin.js";
import { SOURCE_SERVICES, createHeaderSource } from "./dsh-source.js";

/**
 * 本插件与 Swift 半身之间数据形状的版本。**改了投影字段就 +1**——它折进
 * contentHash，Swift 那半边会被强制重编，不会出现新 node 配旧 Swift 的认知分裂。
 * v1 = 只有 tabs（走页内桥，不经这里）。v2 = 加上面包屑 / mode / jobs。
 * v3 = `error` 帧结构化（`message` 不再带中文前缀，改配 `code`；i3 文案双语化）。
 */
const SCHEMA_VERSION = 3;

/**
 * 桥这一侧的合并窗口。很短：数据源已经替我们把 I/O 那层的洪流合并掉了
 * （`dsh-source.js` 的 600ms），这里挡的只是"同一拍里两个来源都说变了"。
 */
const COALESCE_MS = 30;

/** 三个上行动作。表在这里定死，实现随作用域 inject 里的宿主服务就绪后挂进 RUNTIME。 */
const ACTIONS = ["snapshot", "focus", "selectPreset"];

/**
 * 插件实例 → 动作实现。键用 `createSwiftPlugin` 每次 `apply` 造的那个 api 对象，
 * 天然按实例隔离，实例没了就自然被回收（同 clam-sidebar）。
 */
const RUNTIME = new WeakMap();

export default createSwiftPlugin({
	name: "clam-header",
	// Swift 半身 import ClamLayout 取 `ClamConversationSurface`（点面包屑切会话）。
	// 一份声明两层消费：cordis 据此保证挂载时序，桥据此排编译拓扑序。
	inject: ["clam-layout"],
	swiftDir: new URL("../swift/", import.meta.url),
	swiftDeps: ["clam-layout"],
	schemaVersion: SCHEMA_VERSION,

	subscribe: (api) => {
		const { ctx, push } = api;
		const log = reporter(ctx.logger("clam-header"));
		let version = 0;
		let timer;
		/** 首份有内容的投影是否已经记过日志。 */
		let announced = false;

		// 宿主服务走**作用域 inject**，不写进插件顶层的 `inject` 数组：写上去就是
		// 硬依赖，dsh 换版本改了服务名会让整个 header（连同 Swift 半身）安静地
		// 不挂载。放这里的话，最坏情况是工具栏上少几格 + 终端一行 warn。
		ctx.inject(SOURCE_SERVICES, (inner) => {
			const source = createHeaderSource(inner, log);
			RUNTIME.set(api, {
				snapshot: () => pushSnapshot(source),
				focus: ({ sessionId }) => source.setFocus(sessionId ?? null),
				selectPreset: ({ sessionId, agentPreset }) =>
					source.selectPreset(String(sessionId), String(agentPreset)),
			});

			source.onChange((immediate) => schedulePush(source, immediate));
			log.info(`数据面就绪（宿主服务 ${SOURCE_SERVICES.join(" / ")}）`);

			inner.effect(() => () => {
				RUNTIME.delete(api);
				clearTimeout(timer);
				source.dispose();
			}, "clam-header 数据源");
		});

		// 服务名对不上时不会有任何异常，只是回调永远不跑——所以主动查一次哨。
		const sentinel = setTimeout(() => {
			if (RUNTIME.has(api)) return;
			log.warn(`等不到宿主服务 ${SOURCE_SERVICES.join(" / ")}，`
				+ "header 只会有视图切换那一格（dsh 版本变动改了服务名？核对 lib/dsh-source.js）");
		}, 10_000);
		sentinel.unref?.();
		ctx.effect(() => () => clearTimeout(sentinel), "clam-header 数据面守望");

		function schedulePush(source, immediate) {
			clearTimeout(timer);
			if (immediate) { pushSnapshot(source); return; }
			timer = setTimeout(() => pushSnapshot(source), COALESCE_MS);
			timer.unref?.();
		}

		function pushSnapshot(source) {
			version += 1;
			const session = source.projection();
			// 只在第一份有内容的投影上记一行，之后闭嘴——焦点每变一次、
			// 每条 job 翻牌都会推一份，逐条记会把终端刷没
			// （与 clam-sidebar 的「首份投影」同一条纪律）。
			if (!announced && session !== null) {
				announced = true;
				const preset = session.preset === null
					? "无" : `${session.preset.options.length} 个可选`;
				const tree = session.subagents;
				const subagents = tree === null || tree === undefined
					? "无"
					: `${Object.keys(tree.nodes).length} 个（根 ${tree.root}）`;
				log.info(`首份投影：${session.id}／面包屑 ${session.crumbs.length} 段`
					+ `／preset ${preset}／后台任务 ${session.jobs.count}`
					+ `／子代理 ${subagents}`);
			}
			push("snapshot", { version, session });
		}
	},

	// `expose` 的返回值桥不看（invoke 是单向帧），所以失败只能自己经 error 频道
	// 报回去——原生那边没有控制台，静默失败等于骗人。
	expose: Object.fromEntries(ACTIONS.map((action) => [action, async (payload, api) => {
		const handler = RUNTIME.get(api)?.[action];
		if (handler === undefined) {
			// snapshot / focus 在数据面就绪前到达是正常的（Swift 每代都会问一次），
			// 不值得报错——就绪那一刻会自己推一份。只有写动作才需要告诉用户。
			if (action === "selectPreset") {
				// 这一条没有上游原话可转，只有我们自己的原因码；`message` 是给
				// 日志与"万一 Swift 不认得这个码"兜底用的技术串，不是给用户看的句子。
				api.push("error", { action, code: "notReady",
					message: "header data plane is not ready" });
			}
			return;
		}
		try {
			await handler(payload ?? {});
		} catch (error) {
			const message = errorText(error);
			// 日志照旧中文（读它的是蹲在终端前的人，不跟界面语言走）。
			api.ctx.logger("clam-header").warn(`${action} 失败：${message}`);
			process.stderr.write(`clam-header: ${action} 失败：${message}\n`);
			const code = typeof error?.clamCode === "string" ? error.clamCode : undefined;
			api.push("error", code === undefined
				? { action, message }
				: { action, code, message });
		}
	}])),
});

/**
 * cordis logger 在 `dsh web` 下没有 exporter：消息只进环形缓冲。
 * 要给蹲在终端的人看的东西必须自己写 stderr——照 clam-bridge / clam-sidebar
 * 的做法两边都喂。
 */
function reporter(logger) {
	const emit = (level, message) => {
		logger[level](message);
		process.stderr.write(`clam-header: ${message}\n`);
	};
	return {
		info: (message) => emit("info", message),
		warn: (message) => emit("warn", message),
		error: (message) => emit("error", message),
	};
}

function errorText(error) {
	return error instanceof Error ? error.message : String(error);
}
