/**
 * clam-sidebar —— 原生会话侧边栏（计划 §7.2）。
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
 * `inject`/`swiftDeps` 里的 `clam-layout` 一份声明两层消费：Cordis 据此保证
 * "layout 未挂好本插件不挂载、layout 换代时本插件级联重载"，桥据此排编译拓扑序
 * （Swift 侧 `import ClamLayout` 拿 `ClamConversationSurface`）。
 *
 * ## 桥协议
 *
 * 下行（`push(channel, payload)`）：
 *
 * | 频道 | 载荷 | 什么时候 |
 * |---|---|---|
 * | `snapshot` | `{version, groups:[{id, workspaceId, title, sessions:[…]}]}` | 数据变化时（见 `schedulePush`），以及被 `snapshot` 动作请求时 |
 * | `forked` | `{sourceId, sessionId}` | `fork` 完成，供 Swift 切到子会话 |
 * | `error` | `{action, code?, message}` | 任一写动作抛错（Swift 弹一次 alert） |
 *
 * **`error` 帧里一个显示文案都没有**（计划 §8-4）：`action` 是动作 id、`code` 是
 * 我们自己认领得了的失败原因码（`notReady` / `apiMissing` / `forkNoChild`，
 * 见 `dsh-source.js` 的 `SourceError`），`message` 是上游那句原话。
 * 「归档会话失败：<原因>」这句是 Swift 那边按界面语言组的
 * （`swift/Strings.swift`）——node 不知道界面是哪种语言，也不该知道。
 *
 * 会话行的字段：`{id, title, preview, status, updatedAt, blank, isSubagent, archived}`。
 * `preview` 是副行摘要（尾部一条消息的文本，取不到时为 null，见 `dsh-source.js`
 * 的「预览行从哪来」）；`archived` 是归档标记——**归档不再在数据层滤掉**，
 * 侧边栏有了「显示已归档」开关之后，显不显示成了 UI 政策。
 * `status` 是字符串而不是数字枚举（加新状态时旧壳解码不会失败，只会当成 idle），
 * 取值 `running` / `pendingApproval` / `pendingQuestion` / `failed` / `done` / `idle`。
 * **后四个里有三个不是这一侧算出来的**：`pendingQuestion` / `failed` / `done` 来自
 * clam-notify 供出来的 `clamPending`（见 `withPending`），clam-notify 缺席时
 * 就只剩 `running` / `pendingApproval` / `idle` 这三个老取值。
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
 * @module clam-sidebar
 */
import { createSwiftPlugin } from "../../clam-bridge/lib/plugin.js";
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
 * 归档不再在数据层滤除（新增 `archived`），v4 = `status` 多了 `pendingQuestion`
 * / `failed` / `done` 三个取值（经 `clamPending`，见 `withPending`），
 * v5 = `error` 帧结构化（`message` 不再带中文前缀，改配 `code`；i2 文案双语化）。
 */
const SCHEMA_VERSION = 5;

/**
 * `clamPending` 的原因 → 投影里的 `status`。
 *
 * 键就是 clam-notify 那份待办的 `kind`；它没供出来的类别（将来新加的）在这里
 * 查不到就被忽略，不会把一个 Swift 不认得的字符串推下去。
 */
const REASON_STATUS = {
	approval: "pendingApproval",
	question: "pendingQuestion",
	error: "failed",
	done: "done",
};

/**
 * 一个会话同时占好几种状态时，画哪一个。**越小越该管。**
 *
 * `running` 排在两个"等你"之后、两个"已经发生"之前：正在跑是过程，欠着的事
 * 比过程重要，而看一眼就完的事没有过程重要。认不出的字符串排到最后。
 */
const STATUS_RANK = ["pendingApproval", "pendingQuestion", "running", "failed", "done", "idle"];

function rank(status) {
	const index = STATUS_RANK.indexOf(status);
	return index === -1 ? STATUS_RANK.length : index;
}

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
	name: "clam-sidebar",
	provide: "clam-sidebar",
	inject: ["clam-layout"],
	swiftDir: new URL("../swift/", import.meta.url),
	swiftDeps: ["clam-layout"],
	schemaVersion: SCHEMA_VERSION,
	// 没有 sharedModules：Swift 半身只 import ClamSDK（无条件）与 ClamLayout。
	// 曾经声明的 DSHKit 随本次迁移整体退役。

	// 壳菜单里那些会话命令（形状见 clam-bridge/lib/plugin.js 的 CommandDeclaration）。
	// 执行端全在 `swift/SidebarShortcuts.swift`——顺序、选中态、筛选状态都只有这边有。
	// **本插件缺席时这些菜单项干脆不出现**（而不是灰着或按下去没反应）。
	commands: [
		{
			id: "renameSession",
			menu: "file",
			order: 20,
			separatorBefore: true,
			label: { zh: "重命名会话…", en: "Rename Session…" },
			key: "cmd+alt+r",
			description: { zh: "重命名当前会话。", en: "Rename the current session." },
		},
		{
			id: "archiveSession",
			menu: "file",
			order: 30,
			label: { zh: "归档会话", en: "Archive Session" },
			key: "cmd+shift+backspace",
			description: { zh: "归档当前会话。", en: "Archive the current session." },
		},
		{
			id: "focusSearch",
			menu: "view",
			order: 10,
			separatorBefore: true,
			label: { zh: "聚焦搜索", en: "Focus Search" },
			key: "cmd+alt+f",
			description: {
				zh: "把光标送进侧边栏搜索框。",
				en: "Move the cursor to the sidebar search field.",
			},
		},
		// 「会话」是壳没有的菜单，由本插件造：标题取首个声明者的 menuLabel，
		// 位置夹在「显示」与「窗口」之间（menuOrder 只在多个自定义菜单之间比大小）。
		{
			id: "prevSession",
			menu: "session",
			menuLabel: { zh: "会话", en: "Session" },
			menuOrder: 50,
			order: 10,
			label: { zh: "上一个会话", en: "Previous Session" },
			key: "cmd+shift+[",
			description: {
				zh: "切到上一个会话（顺序与侧边栏列表当前显示的一致）。",
				en: "Go to the previous session, in the order the sidebar is showing.",
			},
		},
		{
			id: "nextSession",
			menu: "session",
			order: 20,
			label: { zh: "下一个会话", en: "Next Session" },
			key: "cmd+shift+]",
			description: {
				zh: "切到下一个会话（顺序与侧边栏列表当前显示的一致）。",
				en: "Go to the next session, in the order the sidebar is showing.",
			},
		},
		{
			id: "nextPendingSession",
			menu: "session",
			order: 30,
			label: { zh: "下一个待处理会话", en: "Next Pending Session" },
			key: "cmd+alt+a",
			description: {
				zh: "跳到下一个待处理会话（有东西在等你回答的那些）。",
				en: "Jump to the next session that is waiting for you.",
			},
		},
		{
			// ⌘1…⌘9：**一个设置键装九个菜单项**。九项全隐藏——九行「会话 N」占满菜单
			// 却什么信息都不给，而快捷键照常生效（壳负责 allowsKeyEquivalentWhenHidden）。
			// `key` 这里只写修饰键；`off` = 九个都不装（数字键在页面里是正常输入，
			// 这一条比别的更该留一个关掉的口子）。
			id: "sessionDigits",
			menu: "session",
			order: 40,
			separatorBefore: true,
			hidden: true,
			label: { zh: "会话 {n}", en: "Session {n}" },
			key: "cmd",
			keyChoices: ["cmd", "cmd+alt", "off"],
			digits: { count: 9, command: "selectSessionAt", argKey: "index" },
			description: {
				zh: "用数字键直接跳到第 1～9 个会话时按的修饰符；off = 不装这组快捷键。",
				en: "The modifier held with 1–9 to jump straight to that session; "
					+ "off installs no such shortcuts.",
			},
		},
	],

	subscribe: (api) => {
		const { ctx, push } = api;
		const log = reporter(ctx.logger("clam-sidebar"));
		let version = 0;
		let timer;
		/** 首份有内容的投影是否已经记过日志。 */
		let announced = false;
		/** @type {ReturnType<typeof createSessionSource>|undefined} */
		let source;
		/** clam-notify 供出来的「有什么在等着你」。缺席时是 undefined。 */
		let pending;

		// 宿主服务走**作用域 inject**，不写进插件顶层的 `inject` 数组：写上去就是
		// 硬依赖，dsh 换版本改了服务名会让整个侧边栏（连同 Swift 半身）安静地不挂载。
		// 放这里的话，最坏情况是壳里一个空列表 + 终端一行 warn，而不是白屏。
		ctx.inject(SOURCE_SERVICES, (inner) => {
			source = createSessionSource(inner, log);
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
				source?.dispose();
				source = undefined;
			}, "clam-sidebar 会话数据源");
		});

		// 「待处理」那枚胶囊要列的不止待批准——待回答、出错、跑完了都算。
		// 后三样这一侧**推不出来**（`ask_user_question` 不发 cordis 事件也不落
		// session log，见 dsh-source.js 的 `statusOf`），而 clam-notify 那边为了发
		// 通知已经养着一条 mux 帧流、维护着一份权威的待办表。真相只该有一份，
		// 所以订它，而不是在这儿再养一条。
		//
		// **运行时嵌套 inject**：clam-notify 是可选的，缺席时侧边栏退回自己那份
		// approval-only 的状态点，一切照旧。
		ctx.inject(["clamPending"], (scoped) => {
			pending = scoped.clamPending;
			const off = pending.subscribe(() => {
				// 状态翻牌，用户正等着那个点亮/熄灭——不压拍。
				if (source !== undefined) schedulePush(source, true);
			});
			scoped.effect(() => () => {
				off();
				pending = undefined;
			}, "clam-sidebar 待处理订阅");
			if (source !== undefined) schedulePush(source, true);
		});

		// 服务名对不上时不会有任何异常，只是回调永远不跑——所以主动查一次哨。
		const sentinel = setTimeout(() => {
			if (RUNTIME.has(api)) return;
			log.warn(`等不到宿主服务 ${SOURCE_SERVICES.join(" / ")}，`
				+ "侧边栏会是空列表（dsh 版本变动改了服务名？核对 lib/dsh-source.js）");
		}, 10_000);
		sentinel.unref?.();
		ctx.effect(() => () => clearTimeout(sentinel), "clam-sidebar 数据面守望");

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
			const groups = withPending(source.groups());
			// 只在第一份有内容的快照上记一行，之后闭嘴——running 每翻一次牌
			// 都推一次，逐条记会把终端刷没。
			if (!announced && groups.length > 0) {
				announced = true;
				const count = groups.reduce((sum, group) => sum + group.sessions.length, 0);
				log.info(`首份投影：${count} 条会话 / ${groups.length} 组`);
			}
			push("snapshot", { version, groups });
		}

		/**
		 * 把 `clamPending` 的原因叠进投影的 `status`。
		 *
		 * **只升不降**：两边各自看到的都是真事实，取更该管的那一个（`STATUS_RANK`）。
		 * clam-notify 缺席时原样返回——这条路径必须存在，它是侧边栏的独立性。
		 */
		function withPending(groups) {
			const map = pending?.snapshot();
			if (map === undefined) return groups;
			return groups.map((group) => ({
				...group,
				sessions: group.sessions.map((session) => {
					const reasons = map[session.id];
					if (reasons === undefined || reasons.length === 0) return session;
					const status = [session.status, ...reasons.map((r) => REASON_STATUS[r])]
						.filter((value) => value !== undefined)
						.sort((a, b) => rank(a) - rank(b))[0];
					return status === session.status ? session : { ...session, status };
				}),
			}));
		}
	},

	// `expose` 的返回值桥不看（invoke 是单向帧），所以失败只能自己经 error 频道
	// 报回去——原生那边没有控制台，静默失败等于骗人。
	expose: Object.fromEntries(ACTIONS.map((action) => [action, async (payload, api) => {
		const handler = RUNTIME.get(api)?.[action];
		if (handler === undefined) {
			// 这一条没有上游原话可转，只有我们自己的原因码；`message` 是给日志
			// 与万一 Swift 不认得这个码时兜底用的技术串，不是给用户看的句子。
			api.push("error", { action, code: "notReady",
				message: "session data plane is not ready" });
			return;
		}
		try {
			await handler(payload ?? {});
		} catch (error) {
			const message = errorText(error);
			// 日志照旧中文（读它的是蹲在终端前的人，不跟界面语言走）。
			api.ctx.logger("clam-sidebar").warn(`${action} 失败：${message}`);
			process.stderr.write(`clam-sidebar: ${action} 失败：${message}\n`);
			const code = typeof error?.clamCode === "string" ? error.clamCode : undefined;
			api.push("error", code === undefined
				? { action, message }
				: { action, code, message });
		}
	}])),
});

/**
 * cordis logger 在 `dsh web` 下没有 exporter（计划 §1.7），消息只进环形缓冲。
 * 要给蹲在终端的人看的东西必须自己写 stderr——照 clam-bridge 的做法两边都喂。
 */
function reporter(logger) {
	const emit = (level, message) => {
		logger[level](message);
		process.stderr.write(`clam-sidebar: ${message}\n`);
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
