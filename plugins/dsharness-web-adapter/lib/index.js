/**
 * DSHarness 适配插件，node 半边。空 apply 给 Loader 一个可挂载的 host row；
 * 浏览器半边经 `exports["./client"]` 交付（与 dsh-client-ui-brand-official 同构）。
 */
function apply() {}

export { apply };
