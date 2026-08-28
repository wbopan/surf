/**
 * 智能体预设页的数据面——对齐 dsh Web 的 Agent presets。
 *
 * **它不走 `ctx.settings`**，这是我先前误判的地方：预设画廊的数据来自
 * `ctx.agentPresets`（`dsh-agent-presets` 注册的服务），settings 里只有
 * `agent-presets.default` 那一个"默认用哪个"的字段。当时没查就下了
 * "没有数据面"的结论，于是整整一栏被跳过了。
 *
 * **整块可选**，跟 models 一样走运行时 `ctx.inject` 嵌套：服务不在只是这一页
 * 不出现，别的页照常。
 *
 * **每次都重新 list()**：上游明说 discovery 是不记忆的（"a preset authored
 * while the process runs is visible immediately"），所以我们也不缓存——
 * 用户在外面新建一个预设目录，刷新一下就该看见。
 *
 * @module clam-settings/presets
 */

/**
 * 装上预设页的数据面。
 *
 * @param {object} api createSwiftPlugin 给的 {ctx, push}。
 */
export function installPresets(api) {
	const { ctx, push } = api;

	// 服务不在场：明确说"这一页不可用"，Swift 侧据此隐藏导航项——
	// 而不是显示一个空画廊让用户以为一个预设都没有。
	push("presets", { available: false, presets: [] });

	ctx.inject(["agentPresets"], (presetCtx) => {
		const pushPresets = async () => {
			try {
				const rows = await presetCtx.agentPresets.list();
				push("presets", {
					available: true,
					// `defaultId` 是 getter，每次读都重算（settings 文档热重载）。
					defaultId: presetCtx.agentPresets.defaultId ?? null,
					presets: rows.map((preset) => ({
						id: preset.id,
						// 'system' = 随部署附带的，'user' = 用户自己写的。
						// Web 分成 BUILT-IN / CUSTOM 两段就是按这个。
						trust: preset.trust,
						path: preset.path,
						name: preset.name ?? null,
						description: preset.description ?? null,
						order: typeof preset.order === "number" ? preset.order : null,
						// 坏掉的预设**照样列出来**（上游 resolve 也照样返回它）：
						// 它就是用户要来修的那个，藏起来只会让人查不出为什么起不来。
						broken: preset.broken ?? null,
					})),
				});
			} catch (error) {
				ctx.logger("clam-settings").warn(`预设列表失败：${String(error?.message ?? error)}`);
				push("presets", { available: true, defaultId: null, presets: [], error: String(error?.message ?? error) });
			}
		};

		// 默认预设改了要重推：`defaultId` 是从 settings 用户层读的。
		presetCtx.on("settings/document-updated", () => { void pushPresets(); });
		void pushPresets();

		api.pushPresets = pushPresets;
	});
}
