/**
 * dash-sidebar —— 原生会话侧边栏（计划 §7.2）。
 *
 * **node 半边就是这个插件的数据面**（M10）。它订宿主的会话/工作区服务与事件，
 * 组好一份"侧边栏要画的东西"的投影，经桥推给 Swift 半身；Swift 那边只管画，
 * 以及把用户动作原样发回来。
 *
 * 为什么数据面在这儿而不在 Swift：壳与共享 module 随 app bundle 冻结、用户改不了，
 * 而会话/工作区的 wire 模型是随 dsh 版本演进最快的那一层——层放错了。node 半边
 * 住在 dsh 进程里、随 npm 可更新，且 Swift 插件怎么热替换它都不动。
 * （M6~M9 时这套逻辑是 Swift 的 `DSHKit.SessionStore`，自己开 WS 解 `/api` 的帧。）
 *
 * `inject`/`swiftDeps` 里的 `dash-layout` 一份声明两层消费：Cordis 据此保证
 * "layout 未挂好本插件不挂载、layout 换代时本插件级联重载"，桥据此排编译拓扑序
 * （Swift 侧 `import DashLayout` 拿 `DashConversationSurface`）。
 *
 * ## 桥协议
 *
 * 下行（`push(channel, payload)`）：
 *
 * | 频道 | 载荷 | 什么时候 |
 * |---|---|---|
 * | `snapshot` | `{version, groups:[{id, workspaceId, title, sessions:[…]}]}` | 数据变化时（见 `schedulePush`），以及被 `snapshot` 动作请求时 |
 * | `forked` | `{sourceId, sessionId}` | `fork` 完成，供 Swift 切到子会话 |
 * | `error` | `{action, message}` | 任一写动作抛错（Swift 弹一次 alert） |
 *
 * 会话行的字段：`{id, title, preview, status, updatedAt, blank, isSubagent, archived}`。
 * `preview` 是副行摘要（尾部一条消息的文本，取不到时为 null，见 `dsh-source.js`
 * 的「预览行从哪来」）；`archived` 是归档标记——**归档不再在数据层滤掉**，
 * 侧边栏有了「显示已归档」开关之后，显不显示成了 UI 政策。
 * `status` 是字符串（`running` / `pendingApproval` / `idle`；壳还认一个
 * `pendingQuestion`，但 node 侧现在推不出来，原因见 `dsh-source.js` 的 `statusOf`）
 * 而不是数字枚举：加新状态时旧壳解码不会失败，只会当成 idle。
 * `blank` / `isSubagent` / `archived` 原样带上、**不在这里过滤**——"列表里显示什么"
 * 是 UI 政策，归 Swift 的 `AppSidebarModel`。
 *
 * 上行（Swift `bridge.send(action:payload:)`，一律 fire-and-forget）：
 *
 * | 动作 | 载荷 |
 * |---|---|
 * | `snapshot` | `{}`（请求全量重发） |
 * | `archive` | `{sessionId}` |
 * | `renameSession` | `{sessionId, title}` |
 * | `fork` | `{sessionId}` |
 * | `createWorkspace` | `{path}` |
 * | `renameWorkspace` | `{workspaceId, title}` |
 * | `deleteWorkspace` | `{workspaceId}` |
 *
 * **只有 `snapshot` 一条数据频道，没有增量帧。** 组一份投影是进程内的纯遍历，
 * 全量比"增量协议 + 两边对账"便宜也可靠得多——Swift 那边因此没有任何合并逻辑，
 * 收到什么画什么。（向 dsh **要**数据不便宜，那一层的增量还在，见 `dsh-source.js`
 * 顶部"为什么这里还留着增量"。两件事别混：贵的是 I/O，不是过桥。）
 *
 * **不给新连上来的世代补发。** 每代 Swift 半身 activate 时自己发一次 `snapshot`
 * 动作要全量（与桥不给壳补发 `app-build` 同一条纪律：补发的判断该由请求方做）。
 *
 * 搜索留在 Swift 侧的客户端过滤（标题/组名子串），没有走桥——上游的
 * `session.search` 是全文检索，是另一件事，本次不迁也不新增。
 *
 * @module dash-sidebar
 */
import { createSwiftPlugin } from "../../dash-bridge/lib/plugin.js";
import { SOURCE_SERVICES, createSessionSource } from "./dsh-source.js";
import { increasedForkTitle } from "./fork-title.js";

/**
 * 桥这一侧的合并窗口。很短：数据源已经替我们把 I/O 那层的洪流合并掉了
 * （`dsh-source.js` 的 400ms），这里挡的只是"同一拍里两个来源都说变了"。
 */
const COALESCE_MS = 30;

/**
 * 本插件与 Swift 半身之间数据形状的版本。**改了投影字段就 +1**——它折进
 * contentHash，Swift 那半边会被强制重编，不会出现新 node 配旧 Swift 的认知分裂。
 * v1 = M6 的"没有数据面"，v2 = M10 的投影协议，v3 = 副行摘要 `preview` +
 * 归档不再在数据层滤除（新增 `archived`）。
 */
const SCHEMA_VERSION = 3;

/** 七个上行动作。表在这里定死，实现随数据面就绪后挂进 `RUNTIME`。 */
const ACTIONS = ["snapshot", "archive", "renameSession", "fork",
	"createWorkspace", "renameWorkspace", "deleteWorkspace"];

/**
 * 插件实例 → 动作实现。
 *
 * 绕这一圈是因为 `expose` 表在模块求值时就要定好，而动作的实现要等作用域 inject
 * 里的宿主服务到齐。键用 `createSwiftPlugin` 每次 `apply` 造的那个 api 对象
 * （`subscribe` 与每个 `expose` 处理器收到的是同一个），所以天然按实例隔离，
 * 而且实例没了就自然被回收——不需要谁记得清理。
 */
const RUNTIME = new WeakMap();

export default createSwiftPlugin({
	name: "dash-sidebar",
	provide: "dash-sidebar",
	inject: ["dash-layout"],
	swiftDir: new URL("../swift/", import.meta.url),
	swiftDeps: ["dash-layout"],
	schemaVersion: SCHEMA_VERSION,
	// 没有 sharedModules：Swift 半身只 import DashSDK（无条件）与 DashLayout。
	// 曾经声明的 DSHKit 随本次迁移整体退役。

	subscribe: (api) => {
		const { ctx, push } = api;
		const log = reporter(ctx.logger("dash-sidebar"));
		let version = 0;
		let timer;
		/** 首份有内容的投影是否已经记过日志。 */
		let announced = false;

		// 宿主服务走**作用域 inject**，不写进插件顶层的 `inject` 数组：写上去就是
		// 硬依赖，dsh 换版本改了服务名会让整个侧边栏（连同 Swift 半身）安静地不挂载。
		// 放这里的话，最坏情况是壳里一个空列表 + 终端一行 warn，而不是白屏。
		ctx.inject(SOURCE_SERVICES, (inner) => {
			const source = createSessionSource(inner, log);
			RUNTIME.set(api, buildActions(source));

			// 数据变了就重推。`immediate` = 状态翻牌（用户正等着那个点亮/熄灭），
			// 不 immediate = 一轮重取落地，可以再压一拍。
			source.onChange((immediate) => schedulePush(source, immediate));

			log.info(`数据面就绪（宿主服务 ${SOURCE_SERVICES.join(" / ")}）`);
			// 就绪即推一份：此刻壳可能早就连上、也早就问过 snapshot 了。
			// （首轮取数是异步的，所以这一份多半是空的；真正有内容的那份
			//  随第一次 onChange 到来。）
			schedulePush(source, true);

			inner.effect(() => () => {
				RUNTIME.delete(api);
				clearTimeout(timer);
				source.dispose();
			}, "dash-sidebar 会话数据源");
		});

		// 服务名对不上时不会有任何异常，只是回调永远不跑——所以主动查一次哨。
		const sentinel = setTimeout(() => {
			if (RUNTIME.has(api)) return;
			log.warn(`等不到宿主服务 ${SOURCE_SERVICES.join(" / ")}，`
				+ "侧边栏会是空列表（dsh 版本变动改了服务名？核对 lib/dsh-source.js）");
		}, 10_000);
		sentinel.unref?.();
		ctx.effect(() => () => clearTimeout(sentinel), "dash-sidebar 数据面守望");

		function buildActions(source) {
			return {
				snapshot: () => pushSnapshot(source),
				archive: ({ sessionId }) => source.archiveSession(String(sessionId)),
				renameSession: ({ sessionId, title }) =>
					source.renameSession(String(sessionId), String(title)),
				fork: async ({ sessionId }) => {
					const sourceId = String(sessionId);
					// 先记标题：分叉本身会让列表刷新，之后再读就不一定是同一份了。
					const title = source.titleOf(sourceId);
					const childId = await source.forkSession(sourceId);
					// **分叉标题的递增在这里复刻**（`fork-title.js`）：上游把它放在
					// client runtime 的 `fork(increaseTitle:true)` 里，服务/wire 层
					// 只有 fork + rename 两步，所以谁绕过 runtime 分叉谁就得自己补。
					// 两个界面分叉出来的会话必须同名。
					// 改名失败不该让用户白白丢掉这次分叉——尽力而为。
					if (title) {
						try {
							await source.renameSession(childId, increasedForkTitle(title));
						} catch (error) {
							log.warn(`分叉后改名失败（分叉本身已成功）：${errorText(error)}`);
						}
					}
					push("forked", { sourceId, sessionId: childId });
				},
				createWorkspace: ({ path }) => source.createWorkspace(String(path)),
				renameWorkspace: ({ workspaceId, title }) =>
					source.renameWorkspace(String(workspaceId), String(title)),
				deleteWorkspace: ({ workspaceId }) => source.deleteWorkspace(String(workspaceId)),
			};
		}

		function schedulePush(source, immediate) {
			clearTimeout(timer);
			if (immediate) {
				pushSnapshot(source);
				return;
			}
			timer = setTimeout(() => pushSnapshot(source), COALESCE_MS);
			timer.unref?.();
		}

		function pushSnapshot(source) {
			version += 1;
			const groups = source.groups();
			// 只在第一份有内容的快照上记一行，之后闭嘴——running 每翻一次牌
			// 都推一次，逐条记会把终端刷没。
			if (!announced && groups.length > 0) {
				announced = true;
				const count = groups.reduce((sum, group) => sum + group.sessions.length, 0);
				log.info(`首份投影：${count} 条会话 / ${groups.length} 组`);
			}
			push("snapshot", { version, groups });
		}
	},

	// `expose` 的返回值桥不看（invoke 是单向帧），所以失败只能自己经 error 频道
	// 报回去——原生那边没有控制台，静默失败等于骗人。
	expose: Object.fromEntries(ACTIONS.map((action) => [action, async (payload, api) => {
		const handler = RUNTIME.get(api)?.[action];
		if (handler === undefined) {
			api.push("error", { action, message: "会话数据面尚未就绪" });
			return;
		}
		try {
			await handler(payload ?? {});
		} catch (error) {
			const message = errorText(error);
			api.ctx.logger("dash-sidebar").warn(`${action} 失败：${message}`);
			process.stderr.write(`dash-sidebar: ${action} 失败：${message}\n`);
			api.push("error", { action, message });
		}
	}])),
});

/**
 * cordis logger 在 `dsh web` 下没有 exporter（计划 §1.7），消息只进环形缓冲。
 * 要给蹲在终端的人看的东西必须自己写 stderr——照 dash-bridge 的做法两边都喂。
 */
function reporter(logger) {
	const emit = (level, message) => {
		logger[level](message);
		process.stderr.write(`dash-sidebar: ${message}\n`);
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
