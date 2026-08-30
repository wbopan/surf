/**
 * 「插件列表」的数据面——对齐 dsh Web 的 Plugins → Plugin list。
 *
 * 数据来自 `ctx.pluginInventory`（`dsh-host-plugin-inventory` 注册的服务），
 * 它自己的包描述就一句话：**"Read-only Remote projection of current Cordis
 * Loader plugin state"**。整个服务只有一个 `list()`，没有任何写入口。
 *
 * **所以这一栏没有启停开关，Web 那边也没有**——它显示的「已启用/已停用」是
 * Loader 配置的**投影**，不是一个可点的开关。上游 README 的 Known Limitations
 * 把这条写死了："Read-only Loader view — local search does not add … plugin
 * mutation controls."。真要启停得去改编排表（`cordis.patch.yml` / profile 的
 * 配置文件）然后重启，那是另一个层面的动作，不该混在设置窗口里。
 *
 * **整块可选**，跟 models / presets 一样走运行时 `ctx.inject` 嵌套。
 *
 * **不缓存、也不订阅**：`list()` 每次直接读 Loader（上游注释说 Cordis 自己的
 * plugin/status 事件已经在维护 Entry.fiber，再加一层缓存只是多一份要同步的真相）。
 * 上游 Web 是"每次打开设置读一次"，我们跟着来——`refresh` 时重推一次就够。
 *
 * @module surf-settings/inventory
 */

/**
 * 装上插件列表的数据面。
 *
 * @param {object} api createSwiftPlugin 给的 {ctx, push}。
 */
export function installInventory(api) {
	const { ctx, push } = api;

	// 服务不在场：说清楚"读不到"，而不是显示一个空列表让人以为一个插件都没装。
	push("inventory", { available: false, entries: [] });

	ctx.inject(["pluginInventory"], (inventoryCtx) => {
		const pushInventory = () => {
			try {
				const snapshot = inventoryCtx.pluginInventory.list();
				push("inventory", {
					available: true,
					// **保持 Loader 顺序**：上游明说 `list()` 按 Loader 序返回，
					// 那个顺序就是编排表里的装载顺序，本身有信息量。别在这儿排序。
					entries: (snapshot.entries ?? []).map((entry) => ({
						entryId: String(entry.entryId),
						moduleName: String(entry.moduleName ?? ""),
						enabled: entry.enabled === true,
						// null = 根本没有活着的 root Fiber（停用的必然如此）。
						fiberPhase: entry.fiberPhase ?? null,
					})),
				});
			} catch (error) {
				const message = String(error?.message ?? error);
				ctx.logger("surf-settings").warn(`插件列表失败：${message}`);
				push("inventory", { available: true, entries: [], error: message });
			}
		};

		pushInventory();
		api.pushInventory = pushInventory;
	});
}
