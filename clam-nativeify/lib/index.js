/**
 * clam-nativeify，node 半边。
 *
 * 原本是个空 apply（只为给 Loader 一个可挂载的 host row，浏览器半边经
 * `exports["./client"]` 交付，与 dsh-client-ui-brand-official 同构）。现在多了
 * 一件事：注册 `clam-nativeify` 这个设置命名空间，让「对话区字号」成为一个用户
 * 可改的设置项。**注册完就没了**——值由浏览器半边经 `ctx.settingsScope` 自己读，
 * 这半边从不碰它，也不需要 push 给谁。
 *
 * 注册一个 ns 就等于同时点亮了两个界面，两边都不用改一行：
 * clam-settings 那扇原生窗口（「插件 → 插件配置」把 `describe()` 里的每个 ns
 * 一视同仁地列出来），以及 dsh 自己的页内设置对话框。
 *
 * @module clam-nativeify
 */
import z from "@deepseek-ai/schemastery";

/**
 * `settings` 走**运行时嵌套 inject**，不是静态 `export const inject`。
 *
 * 静态 inject 的语义是"服务不在就整个插件不挂载"，而这个插件的全部价值是 client
 * 半边那段 CSS——绝不能因为一个可选的设置项就让整个原生化消失。缺席时字号退到
 * 默认值，其余一切照旧。（这个 cordis fork 的 `inject` 没有 `{required, optional}`
 * 形态，嵌套是它表达可选依赖的唯一方式。）
 *
 * 字段与范围的取值理由写在 client 半边 `BODY_DEFAULT` 那段注释里——**范围是被
 * 那边一张实测行高表的边界卡死的**，改这里之前先读那段。
 *
 * @param {import('@deepseek-ai/cordis').Context} ctx
 */
function apply(ctx) {
	ctx.inject(["settings"], (scoped) => {
		scoped.settings.register("clam-nativeify", z.object({
			// role('slider') + min/max 让原生设置窗口给出滑杆而不是一个让人手敲
			// 数字的文本框；认不出 role 的界面退化成数字输入，仍然可用。
			bodyFontSize: z.number().min(12).max(22).step(1).default(15).role("slider"),
		}), {
			// 改完立刻重画，不需要重启：client 半边订着这个 ns，值一变就重写
			// 字体那张 style。界面据此标注"立即生效"。
			applies: "live",
		});
	});
}

export { apply };
