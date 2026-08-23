/*
 * DSHarness —— 侧边栏 vibrancy 注入脚本（documentEnd 注入）
 *
 * 策略：
 *  1. 注入 SidebarInjection.css（内容由 Swift 侧读取并拼入 __CSS__ 占位符）。
 *  2. 结构启发式：在 #root 下寻找"窄宽(40–420px) + 近全高 + 非 fixed/absolute"的左栏容器，
 *     把该容器及其到 body 的祖先链背景清成透明，让原生 vibrancy 透出。
 *  3. 把检测到的侧边栏宽度通过 webkit.messageHandlers.sidebar 回传 Swift，
 *     用于同步原生 NSVisualEffectView 宽度（v1 以固定宽度兜底）。
 *
 * 全程防御式：任何异常都被吞掉，绝不影响页面本身功能。
 */
(() => {
    "use strict";

    // CSS 内容由 Swift 侧 base64 编码后嵌入（避免转义问题）
    const CSS = atob("__CSS_B64__");

    function injectCSS() {
        try {
            const style = document.createElement("style");
            style.id = "dsharness-vibrancy-style";
            style.textContent = CSS;
            (document.head || document.documentElement).appendChild(style);
        } catch (_) { /* 忽略 */ }
    }

    function isRail(el) {
        const s = getComputedStyle(el);
        const w = parseFloat(s.width);
        const h = parseFloat(s.height);
        if (!Number.isFinite(w) || !Number.isFinite(h)) return false;
        if (w < 40 || w > 420) return false;
        if (h < window.innerHeight * 0.55) return false;
        if (s.position === "fixed" || s.position === "absolute") return false; // 弹层/抽屉不算
        if (el.closest('[role="dialog"]')) return false;
        const rect = el.getBoundingClientRect();
        if (rect.left > 16) return false; // 必须贴左
        return true;
    }

    function reportWidth(width) {
        try {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sidebar) {
                window.webkit.messageHandlers.sidebar.postMessage({ type: "width", width: Math.round(width) });
            }
        } catch (_) { /* 忽略 */ }
    }

    function apply() {
        try {
            // 文档级透明
            document.documentElement.style.backgroundColor = "transparent";
            document.body.style.backgroundColor = "transparent";

            const root = document.getElementById("root");
            if (!root) return;

            let best = null;
            for (const el of root.querySelectorAll("div")) {
                if (!isRail(el)) continue;
                const rect = el.getBoundingClientRect();
                if (best === null || rect.width > best.width) best = { el: el, width: rect.width };
            }
            if (best === null) return;

            // 把 rail 及其祖先链清透明（右侧内容区保留页面自带背景）
            let node = best.el;
            while (node && node !== document.documentElement) {
                node.style.backgroundColor = "transparent";
                node = node.parentElement;
            }
            reportWidth(best.width);
        } catch (_) { /* 忽略 */ }
    }

    injectCSS();
    apply();

    const target = document.getElementById("root") || document.body;
    try {
        new MutationObserver(() => { apply(); }).observe(target, { childList: true, subtree: true });
    } catch (_) { /* 忽略 */ }

    window.addEventListener("load", () => apply());
    if (document.readyState === "complete") apply();
})();
