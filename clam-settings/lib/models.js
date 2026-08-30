/**
 * 模型页的数据面：provider 目录 × 路由活跃状态 × 凭据状态。
 *
 * **整块都是可选的**（计划 §3.1）：`llm` 用运行时 `ctx.inject` 嵌套装载，
 * 缺席时只是这一页不出现，通用页与插件页照常可用——这个 cordis fork 的
 * 静态 `inject` 没有 `{required, optional}` 形态，嵌套是它表达可选依赖的唯一方式。
 * `credentials` 再可选一层：它不在，provider 还是列得出来，只是不知道 key 配没配。
 *
 * @module clam-settings/models
 */

/**
 * 由 provider 路由名推出凭据引用名：`minimax-cn` → `MINIMAX_CN_API_KEY`。
 *
 * **这是 web v1 的产品决定，不是 host 契约**（计划 D4）。跟随它的唯一理由是
 * 不一致会让用户在原生这边设了 key、web 那边显示"未配置"。上游改了命名约定
 * 我们不会收到任何通知，所以它只写在这一处，并注明来源：
 * `dsh-client-ui-settings-models` 的 `deriveKeyRef`。
 *
 * 只在配置里还没有 `apiKeyEnv` 时才用——已经存了的一律以存的为准。
 *
 * @param {string} provider 路由名。
 */
export function deriveKeyRef(provider) {
	return `${provider.toUpperCase().replace(/[^A-Z0-9]+/g, "_")}_API_KEY`;
}

/** 顺着 settingsPath 取出 provider 的 profile 对象（取不到给 undefined）。 */
function profileAt(section, path) {
	let node = section;
	for (const key of path ?? []) {
		if (node === null || typeof node !== "object") return undefined;
		node = node[key];
	}
	return node !== null && typeof node === "object" ? node : undefined;
}

/**
 * 装上模型页的数据面。
 *
 * @param {object} api createSwiftPlugin 给的 {ctx, push}。
 */
export function installModels(api) {
	const { ctx, push } = api;

	// llm 不在场：明确推一条"这一页不可用"，让 Swift 侧知道该隐藏导航项，
	// 而不是显示一个空列表让用户以为一个 provider 都没有。
	push("providers", { available: false, providers: [] });

	ctx.inject(["llm"], (llmCtx) => {
		const pushProviders = async () => {
			try {
				const live = new Set(llmCtx.llm.listProviders().map((p) => p.id));
				const credentials = llmCtx.get?.("credentials");
				const providers = await Promise.all(
					llmCtx.llm.listConfigurableProviders().map(async (entry) => {
						const section = llmCtx.settings.get(entry.settingsNs);
						const profile = profileAt(section, entry.settingsPath);
						// 存过的 apiKeyEnv 永远优先：deriveKeyRef 只是"还没配过"时的猜测。
						const stored = typeof profile?.apiKeyEnv === "string" && profile.apiKeyEnv !== ""
							? profile.apiKeyEnv
							: undefined;
						const keyRef = stored ?? deriveKeyRef(entry.provider);
						let credential = null;
						if (credentials !== undefined) {
							try {
								const info = await credentials.describe(keyRef);
								credential = {
									configured: info.configured === true,
									writable: info.writable === true,
									source: info.source ?? null,
								};
							} catch {
								// 引用名不合语法（用户手写了个奇怪的值）等等——
								// 报 null 而不是抛，一个 provider 的坏配置不该让整页空掉。
								credential = null;
							}
						}
						return {
							provider: entry.provider,
							displayName: entry.displayName ?? entry.provider,
							settingsNs: String(entry.settingsNs),
							settingsPath: [...(entry.settingsPath ?? [])],
							// declared 缺省表示"这个适配器不做这个区分"，照实传 null。
							declared: entry.declared ?? null,
							// 路由活着 = 配置完整到 llm 愿意注册它。上游没有"启停开关"
							// 这个概念，live/dormant 是配置的结果而不是一个可写字段。
							live: live.has(entry.provider),
							keyRef,
							keyRefStored: stored !== undefined,
							credential,
						};
					}));
				push("providers", {
					available: true,
					credentialsAvailable: llmCtx.get?.("credentials") !== undefined,
					providers,
				});
			} catch (error) {
				ctx.logger("clam-settings").warn(`provider 快照失败：${String(error?.message ?? error)}`);
			}
		};

		let scheduled = false;
		const schedule = () => {
			if (scheduled) return;
			scheduled = true;
			queueMicrotask(() => { scheduled = false; void pushProviders(); });
		};

		// 上游明说：适配器拓扑变化要据此重读，别轮询。
		llmCtx.on("llm/adapters-updated", schedule);
		// 凭据变了（可能是别处设的）→ 那几个绿点要跟着变。
		llmCtx.on("credentials/reference-updated", schedule);
		// 配置变了也要重来：新加一个 provider profile、改了 apiKeyEnv 都在这条线上。
		llmCtx.on("settings/document-updated", schedule);

		void pushProviders();
		api.pushProviders = pushProviders;

		return () => { api.pushProviders = undefined; };
	});
}

/**
 * 设置一个凭据。
 *
 * **方向是反的，所以红线不适用**：计划 §5 红线 2 说的是 secret 不往壳那边**下发**
 * （壳只该知道"配没配"）。用户在原生输入框里敲的 key 必须往回走一趟才能存进
 * 凭据库——这一趟走的是本机 loopback 上的桥，与 web 那边把 key POST 给 dsh
 * 是同一条路。
 */
export async function setCredential(api, ref, value) {
	const credentials = api.ctx.get?.("credentials");
	if (credentials === undefined) throw missingCredentials();
	await credentials.set(ref, value);
	await api.pushProviders?.();
}

/** 清掉一个凭据。清一个本来就没有的是 no-op（上游语义）。 */
export async function unsetCredential(api, ref) {
	const credentials = api.ctx.get?.("credentials");
	if (credentials === undefined) throw missingCredentials();
	await credentials.unset(ref);
	await api.pushProviders?.();
}

/**
 * "凭据服务不在场"——**我们自己认领的失败，带稳定 `code`**。
 *
 * 上游抛的错原样往上走（那是 dsh 说的话，按它自己的 locale 出）；自己合成的这一条
 * 没有原话，就只能给一个机器码，让 Swift 用自家文案表出字
 * （`L.failureMessage`，计划 §8-4 的断根办法，与 clam-sidebar 同一套）。
 * `message` 留着只为进日志，**界面不显示它**。
 */
function missingCredentials() {
	const error = new Error("credentials service unavailable");
	error.code = "CREDENTIALS_UNAVAILABLE";
	return error;
}
