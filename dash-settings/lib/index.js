/**
 * dash-settings，node 半边。
 *
 * 眼下只是给 Loader 一个可挂载的 host row（浏览器半边经 `exports["./client"]`
 * 交付）。原生窗口那一半是 Swift 载荷，M2 起由 createSwiftPlugin 接管本文件。
 */
function apply() {}

export { apply };
