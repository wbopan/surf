/**
 * dash-settings —— 原生设置窗口（计划 docs/dash-settings-plan.md）。
 *
 * node 半边登记 Swift 载荷，并在 dsh 进程里**直接消费 host 服务**：
 * `ctx.settings.describe()` 出快照往下推，`mutate` 的单字段 op 往上收。
 * 桥上只走 JSON，Swift 那半连 DSHKit 都不需要。
 *
 * **`settings` 是硬 inject，有意为之**（计划 §3.1）：服务不在就整个插件不挂载，
 * 于是 Swift 半边不会去占 `settingsOwner`，⌘, 干净地回落到 dsh 自己的页内 modal
 * ——一个设置界面缺席时的正确姿态是"让位给还能用的那个"，不是"开出一扇空窗"。
 *
 * `llm` / `credentials` **不在这里**：它们缺席只该让「模型」那一页不出现，
 * 不该连累整扇窗口，所以走运行时 `ctx.inject([...], cb)` 嵌套（见 ./models.js）
 * ——这个 cordis fork 的 `inject` 没有 `{required, optional}` 形态。
 *
 * **不 inject `dash-layout`**：设置是自己的窗口，不占任何槽，也不需要会话展示面
 * ——完整网页模式（layout 缺席的逃生舱）下 ⌘, 照样该开出原生设置窗口。
 *
 * @module dash-settings
 */
import { createSwiftPlugin } from "../../dash-bridge/lib/plugin.js";
import { installModels, setCredential, unsetCredential } from "./models.js";

/**
 * schemastery 的序列化壳子（`{uid, refs}`，refs 里每项是
 * `{type, meta, dict?|inner?|list?|value?|sKey?}`）转成**有序**形状。
 *
 * 只改一处：`object` 节点的 `dict`（键 → refId 的对象）摊成 `fields` 数组。
 *
 * **为什么必须在这半边做**：JS 里对象的键序就是插入序，也就是 schema 的声明序
 * ——而声明序正是设置界面该有的字段顺序。这份 JSON 到了 Swift 会变成
 * `[String: Any]`，键序当场丢光，再想恢复就只剩字母序（`cwd` 排在 `timeoutMs`
 * 前面纯属巧合，`maxOutputBytes` 冒到 `timeoutMs` 前面就不是了）。
 * 顺序是语义，别指望在无序容器里找回来。
 *
 * @param {object} json `schema.toJSON()` 的结果。
 */
function schemaToWire(json) {
	if (json === null || typeof json !== "object") return null;
	const refs = {};
	for (const [id, node] of Object.entries(json.refs ?? {})) {
		if (node === null || typeof node !== "object") continue;
		const { dict, ...rest } = node;
		refs[id] = dict !== undefined && dict !== null && typeof dict === "object"
			? { ...rest, fields: Object.entries(dict).map(([key, ref]) => ({ key, ref })) }
			: rest;
	}
	return { uid: json.uid ?? null, refs };
}

/**
 * 把 `describe()` 的一项摊成 JSON 安全的形状。
 *
 * `describe` 已经给了 detached 拷贝，这里不再深拷；`ns` 是 branded string，
 * 显式 `String()` 一次免得 JSON 里出来个奇怪的东西。
 *
 * @param {object} d 一条 SettingsDescriptor。
 */
function describeToWire(d) {
	return {
		ns: String(d.ns),
		schema: schemaToWire(d.schema),
		value: d.value ?? null,
		base: d.base ?? null,
		user: d.user ?? null,
		revision: d.revision,
		applies: d.applies ?? "live",
		secrets: (d.secrets ?? []).map((s) => ({ path: s.path, set: s.set })),
	};
}

export default createSwiftPlugin({
	name: "dash-settings",
	provide: "dash-settings",
	inject: ["settings"],
	swiftDir: new URL("../swift/", import.meta.url),

	subscribe: (api) => {
		const { ctx, push } = api;

		/** 当前快照推给 Swift 半身。 */
		const pushSettings = () => {
			try {
				push("settings", {
					// **一律 redact**：桥的另一头是另一个进程，凭据明文没有理由去那边
					// （计划 §5 红线 2）。Swift 只会知道"配没配"。
					namespaces: ctx.settings.describe({ redactSecrets: true }).map(describeToWire),
					writable: ctx.settings.writable === true,
					// 非文件型 provider 没有可打开的文档。**别给一个点了没反应的按钮**：
					// 这里报实话，Swift 那边据此隐藏「打开配置文件」。
					hasDocument: typeof ctx.settings.documentPath === "string",
				});
			} catch (error) {
				ctx.logger("dash-settings").warn(`快照失败：${String(error?.message ?? error)}`);
			}
		};

		// 合流：一次外部编辑往往连着改好几个 ns，逐条重算 21KB 的 describe 是浪费。
		// 下一个 tick 推一次就够——设置界面不需要亚毫秒级。
		let scheduled = false;
		const schedulePush = () => {
			if (scheduled) return;
			scheduled = true;
			queueMicrotask(() => { scheduled = false; pushSettings(); });
		};

		// 两个事件都要订：`document-updated` 是"用户层变了"（哪怕解析后的值没变
		// ——从继承变成显式覆盖就是这种情况，而那恰恰改变了界面该显示什么）；
		// `updated` 是"解析后的值变了"（可能来自 base 层或别的写者）。
		ctx.on("settings/document-updated", schedulePush);
		ctx.on("settings/updated", schedulePush);

		// 首推：Swift 半身可能比这里晚就绪，它上来会 invoke 一次 `refresh`，
		// 所以这条首推丢了也不要紧（桥断开时 push 是静默丢弃的）。
		pushSettings();

		// 模型页的数据面：`llm` / `credentials` 到位才装，缺了只是那一页不出现。
		installModels(api);

		api.pushSettings = pushSettings;
	},

	expose: {
		/**
		 * Swift 半身就绪 / 用户手动刷新。
		 *
		 * **两个频道都要重推**。push 是广播、不补发：壳换一代、窗口重开、探针连上来，
		 * 都只能靠这一下把当前状态要回去。只推 settings 的话，模型页会一直停在
		 * "llm 不在场"——直到某个 `llm/adapters-updated` 碰巧发生。
		 * （实测踩到：探针连上来看到的 providers 是 undefined。）
		 */
		refresh: async (payload, api) => {
			api.pushSettings?.();
			await api.pushProviders?.();
			ack(api, payload, { ok: true });
		},

		/**
		 * 写一个字段。
		 *
		 * **只用单字段 op**（计划 §5 红线 1）：读-改-写整段再 `replace` 会把没见过的
		 * 字段——未来 schema 的、用户手写在 settings.yaml 里的、以及**所有被 redact
		 * 掉的 secret**——一起抹掉。上游 `SettingsPathOp` 的注释把这条写死了。
		 */
		set: (payload, api) => mutate(api, payload, [{
			op: "set", path: payload.path ?? [], value: payload.value,
		}]),

		/** 退回继承：删掉用户层的这个键，让 base 与 schema 默认重新生效。 */
		unset: (payload, api) => mutate(api, payload, [{
			op: "unset", path: payload.path ?? [],
		}]),

		/** 设一个 API key。空值不该走到这儿（Swift 侧把"空输入 = 保留现有"挡在前面）。 */
		setCredential: async (payload, api) => {
			try {
				await setCredential(api, String(payload.ref ?? ""), String(payload.value ?? ""));
				ack(api, payload, { ok: true });
			} catch (error) {
				ack(api, payload, { ok: false, error: errorText(error) });
			}
		},

		/** 清掉一个 API key。 */
		unsetCredential: async (payload, api) => {
			try {
				await unsetCredential(api, String(payload.ref ?? ""));
				ack(api, payload, { ok: true });
			} catch (error) {
				ack(api, payload, { ok: false, error: errorText(error) });
			}
		},

		/**
		 * 配置文件路径。`prepareDocument` 会在文件不存在时先把它落地
		 * ——**由壳去 open**：只有 `NSWorkspace` 认用户的默认编辑器。
		 */
		documentPath: async (payload, api) => {
			try {
				const path = await api.ctx.settings.prepareDocument();
				ack(api, payload, { ok: true, value: path ?? null });
			} catch (error) {
				ack(api, payload, { ok: false, error: errorText(error) });
			}
		},
	},
});

/**
 * 执行一次 mutate 并回执。
 *
 * **写完不预测结果**（计划 §4.2）：宿主的 `validate` 回调拥有 schema 表达不了的
 * 跨字段约束，写成功不等于值就是你给的那个。所以这里 mutate 完立刻重推快照，
 * 界面显示的永远是 host 说的话。
 */
async function mutate(api, payload, ops) {
	const ns = String(payload.ns ?? "");
	try {
		await api.ctx.settings.mutate(ns, ops, payload.expectedRevision);
		api.pushSettings?.();
		ack(api, payload, { ok: true });
	} catch (error) {
		// 乐观锁冲突要让界面认得出来：它该重读并告诉用户，而不是覆盖
		// （计划 §4.6）。code 是上游给 wire 层准备的稳定机器码。
		const code = error?.code;
		if (code === "SETTINGS_CONFLICT") api.pushSettings?.();
		ack(api, payload, { ok: false, error: errorText(error), code: code ?? null });
	}
}

/**
 * 回执。
 *
 * **桥本身是单向的**——`invoke` 的返回值被 dash-bridge 丢弃（只在抛错时记一行日志）。
 * 请求/响应语义因此在本插件这一层实现：每个 invoke 带 `id`，回执按 id 配对。
 * 没带 id 的调用（不该有）静默跳过，免得推一堆无主的 ack。
 */
function ack(api, payload, result) {
	const id = payload?.id;
	if (typeof id !== "string" || id === "") return;
	api.push("ack", { id, ...result });
}

/** 错误文案：优先 message，兜底 String()。 */
function errorText(error) {
	return String(error?.message ?? error ?? "未知错误");
}
