/**
 * dash-hello —— 原生插件流水线的冒烟样例（计划 §9 M4 的验收对象）。
 *
 * node 半边就是一段配置，这正是 `createSwiftPlugin` 想证明的事：
 * 八成插件的 TS 半身不需要写逻辑。
 *
 * 它占 `root` 槽，所以**与 dash-layout 互斥**——留在仓库里当冒烟测试，
 * 默认不注册进 profile。要用时：
 *
 *   dsh plugin --profile web add link:~/.dsh/profiles/plugins/dash-hello
 *
 * 然后改 `swift/HelloPlugin.swift` 里的任何一行，界面几秒内自己变。
 *
 * @module dash-hello
 */
import { createSwiftPlugin } from "../../dash-bridge/lib/plugin.js";

export default createSwiftPlugin({
	name: "dash-hello",
	swiftDir: new URL("../swift/", import.meta.url),
	// Swift 半身按 `bridge.send(action:)` 触发；这里回一句给终端，
	// 用来验证上行 invoke 通路。
	expose: {
		ping: (payload, { ctx }) => {
			ctx.logger("dash-hello").info(`Swift 半身 ping：${JSON.stringify(payload)}`);
			process.stderr.write(`dash-hello: Swift 半身 ping ${JSON.stringify(payload)}\n`);
		},
	},
	// 下行 push 通路：每 3s 给 Swift 半身推一个时间戳。
	subscribe: ({ ctx, push }) => {
		const timer = setInterval(() => push("tick", { at: new Date().toISOString() }), 3000);
		timer.unref?.();
		ctx.effect(() => () => clearInterval(timer), "dash-hello tick");
	},
});
