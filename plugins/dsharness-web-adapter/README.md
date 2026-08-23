# dsharness-web-adapter

DSHarness（macOS 壳应用）专用的 dsh Web UI 适配插件。**双面包**：

- `dsh.bundle`（`cordis.patch.yml`）：安装进 profile 后自动加入 `dsh.profile.bundles`，patch 层插入自己的浏览器插件 row（`ui-dsharness-adapter`），无需手改 profile 的 `cordis.patch.yml`。
- `dsh.client`（`lib/client.js`）：浏览器半边，dsh-client-modules 的 node 半边扫描后经 `/plugins/dsharness-web-adapter/client.js` 送达页面。

## 功能

当前唯一功能：**侧边栏顶部让位**。在 DSHarness 的 WKWebView 内给 ui-layout 的侧边栏列加 `padding-top`（默认 24px），为 macOS 窗口红绿灯留位。

门控：只在 `navigator.userAgent` 含 `DSHarness` 时生效（壳应用经 `applicationNameForUserAgent` 声明）。终端 `dsh web` / 普通浏览器共用同一 web profile 时零影响。

## 安装（web profile）

```bash
# 装了 pnpm 的话，用官方入口（自动 reconcile 进 bundles）：
dsh plugin --profile web add link:/Users/wenbopan/Repos/dsh-mac/plugins/dsharness-web-adapter

# 没有 pnpm：在 profile 目录手动等价操作
cd ~/.dsh/profiles/web
npx pnpm add link:/Users/wenbopan/Repos/dsh-mac/plugins/dsharness-web-adapter
# 然后把 "dsharness-web-adapter" 追加进 package.json 的 dsh.profile.bundles
```

装/删/改后重启 harness（壳应用菜单 ⌘⇧R）。

## 配置

Profile 的 `cordis.patch.yml` 里覆盖 row config：

```yaml
- id: ui-dsharness-adapter
  config:
    topInset: 24   # px，0–200；壳内红绿灯经微调后纵向约占 24–38pt，24 让内容落在下缘附近
```

## 已知脆弱点

- 选择器 `[class*="_sidebarCol"]` 依赖 ui-layout CSS module 的语义类名后缀（hash 会变、后缀通常稳定）。dsh 升级后若 gap 消失，先核对 `@deepseek-ai/dsh-client-ui-layout` 的 `AppFrame.module.css` 类名。
- 全屏模式下红绿灯隐藏，但 gap 仍在（v1 接受；后续可由壳应用在全屏切换时翻转 CSS 变量）。
