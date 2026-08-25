# dash-nativeify

dash（macOS 壳应用）专用的 dsh Web UI 原生化插件。**双面包**：

- `dsh.bundle`（`cordis.patch.yml`）：安装进 profile 后自动加入 `dsh.profile.bundles`，patch 层插入自己的浏览器插件 row（`ui-dash-nativeify`），无需手改 profile 的 `cordis.patch.yml`。
- `dsh.client`（`lib/client.js`）：浏览器半边，dsh-client-modules 的 node 半边扫描后经 `/plugins/dash-nativeify/client.js` 送达页面。

## 职责边界

**只做「让 dsh Web UI 摸起来像原生 macOS App」这一件事**，实现是注入一段 CSS，
零服务依赖、零跨插件契约、无配置项。门控只有一条：`navigator.userAgent` 含
`Dash/`（带斜杠，防普通子串误命中；壳经 `applicationNameForUserAgent` 声明）。
终端 `dsh web` / 普通浏览器共用同一 web profile 时零影响。

功能：

1. **禁掉 document 橡皮筋**：`overflow:hidden` 在 WebKit 里不禁用 elastic 滚动——
   内层滚动容器滚到底后惯性仍会链到 document，把整页拉走。`overscroll-behavior:none`
   禁 document 橡皮筋，内层元素 `contain` 切断滚动链（自身仍可滚、边界仍有原生回弹）。
2. **UI 文本不可选中**：全局关掉 `user-select`，输入类控件（composer 等）与
   会话消息流 / trajectory 内容列 / `pre`·`code` 恢复可选，对话历史照常可复制。

## 不在这里的

- **`window.__dash` 动作桥、收起 web 侧边栏、rail 轨道抵消**：那些是原生分栏接管
  排版的一部分，住在 dash-layout 的 client 半边（协议两端同包：Swift 侧
  `WebViewConversationSurface` 是它们唯一的调用方）。
- **网页侧边栏的任何外观调整**（顶部让位 `topInset`、把 `sidebarCol` 刷成透明
  以透出壳的 `NSGlassEffectView`）。这是「网页侧边栏坐在原生玻璃上」那个旧世界的
  产物，已随原生侧边栏落地作废——现在只有两种形态：

  | 形态 | 谁在画侧边栏 | WebView 位置 |
  |---|---|---|
  | 原生侧边栏（常态） | dash-sidebar 占 sidebar 槽 | `NSSplitViewItem` 右侧，够不着侧边栏那一栏 |
  | 完整网页模式（逃生舱） | dsh 自己 | 全出血铺满窗口，**原样展示，不修** |

  「用网页侧边栏、但把它打扮成原生」这个中间态不存在，别再往回加。

## 安装（web profile）

```bash
# 装了 pnpm 的话，用官方入口（自动 reconcile 进 bundles）：
dsh plugin --profile web add link:~/.dsh/profiles/plugins/dash-nativeify

# 没有 pnpm：在 profile 目录手动等价操作
cd ~/.dsh/profiles/web
npx pnpm add link:~/.dsh/profiles/plugins/dash-nativeify
# 然后把 "dash-nativeify" 追加进 package.json 的 dsh.profile.bundles
```

装/删/改后重启 harness（壳应用菜单 ⌘⇧R）。

## 已知脆弱点

- 选择器 `[class*="_flowItem"]` / `[class*="_contentColumn"]` 依赖 dsh Web UI 的
  CSS module 语义类名后缀（hash 会变、后缀通常稳定）。升级 dsh 后若对话历史突然
  不能复制，先核对 `@deepseek-ai/dsh-client-ui-conversation` / `-ui-trajectory` 的类名。
- `overflow:hidden` 强加于 html/body：与全屏/滚动类未来特性可能冲突。
- 完整网页模式（逃生舱）下红绿灯会压在网页侧边栏顶部——**这是刻意接受的**：
  逃生舱的定位是「dash-layout 挂了也还能用」的降级路径，不为它做外观修补。
