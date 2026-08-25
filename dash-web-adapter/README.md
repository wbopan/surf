# dash-web-adapter

dash（macOS 壳应用）专用的 dsh Web UI 适配插件。**双面包**：

- `dsh.bundle`（`cordis.patch.yml`）：安装进 profile 后自动加入 `dsh.profile.bundles`，patch 层插入自己的浏览器插件 row（`ui-dash-adapter`），无需手改 profile 的 `cordis.patch.yml`。
- `dsh.client`（`lib/client.js`）：浏览器半边，dsh-client-modules 的 node 半边扫描后经 `/plugins/dash-web-adapter/client.js` 送达页面。

## 功能（v2，verified against harness 0.1.1-rc.2）

均 UA 门控：只在 `navigator.userAgent` 含 `Dash/` 时生效（带斜杠，防普通子串误命中）（壳应用经 `applicationNameForUserAgent` 声明）。终端 `dsh web` / 普通浏览器共用同一 web profile 时零影响。

1. **侧边栏顶部让位**（v1）：给 ui-layout 的侧边栏列加 `padding-top`（默认 24px），为 macOS 窗口红绿灯留位。
2. **侧边栏透出原生玻璃**（v1）：dsh UI 给 sidebarCol 画了不透明 `--dsw-specific-sidebar-fill`，会把壳应用的原生 NSGlassEffectView（Liquid Glass）完全盖住；插件将其改为 `background: transparent`，玻璃得以透出。
3. **「隐藏侧边栏」模式**（v2，额外要求 URL 查询参数 `dash-native-sidebar=1`）：
   - 经 ui-layout 公开服务 `ctx.layout.toggleSidebar()`（LayoutController 面板动作面）把侧边栏收起，用 AppFrame 根元素的 `data-sidebar-collapsed` 属性作反馈信号（MutationObserver 维持收起，视图/偏好重新展开时自动再收）。
   - 折叠后 `computeColumns` 仍给 sidebar 轨道保留 56px rail：插件实时测量 sidebarCol 占位写入 CSS 变量 `--dash-sidebar-occupancy`，把整帧向左平移该宽度（rail 移出视口、`overflow:hidden` 裁掉），会话列从窗口左缘起排；sidebarCol 同时 `visibility:hidden; pointer-events:none` 双保险。
4. **页内动作桥 `window.__dash`**（v2，凡 dash UA 即装，与 URL 参数无关；内部不可用时安全缺省、绝不抛）：
   - `selectSession(sessionId)` → `ctx.sessions.open(id)`（与 ui-workspace 会话行点击完全同款公开动作）。
   - `startSession(workspaceId?)` → `ctx.workspaces.startSession(workspaceId?)`（与 ui-sidebar New Session 按钮同款；省略时 runtime 自行推导目标 workspace）。
   - `openSettings()` → **无公开服务可用**（ui-settings-general 的开合是组件局部 React `useState`），回退为点击侧边栏 settings 座内的 `button[aria-haspopup="dialog"]` 触发按钮（DOM 合成 click，React 合成事件正常触发）。
   - 反向通道：订阅 `ctx.sessions.list` 快照 store（渲染同款数据源，订阅方式与 ui-agent-preset 一致），当前会话变化（含会话内子代理导航 `currentAddress` 变化）时 `window.webkit.messageHandlers.dash.postMessage({type:'currentSession', id, address})`（普通浏览器静默跳过）。
   - 就绪上报：桥安装后约 1.5s `postMessage({type:'ready', capabilities:[...]})`，capabilities 只列实际接通的函数（服务缺席时该项静默缺失）。
   - 服务获取方式：`ctx.inject(["sessions"], cb)` 等（cordis 标准动态注入，服务可用即触发、随本插件 fiber 卸载），因此 web app 内部服务改名/缺席时仅对应能力缺失，插件不崩。

## 安装（web profile）

```bash
# 装了 pnpm 的话，用官方入口（自动 reconcile 进 bundles）：
dsh plugin --profile web add link:~/.dsh/profiles/plugins/dash-web-adapter

# 没有 pnpm：在 profile 目录手动等价操作
cd ~/.dsh/profiles/web
npx pnpm add link:~/.dsh/profiles/plugins/dash-web-adapter
# 然后把 "dash-web-adapter" 追加进 package.json 的 dsh.profile.bundles
```

装/删/改后重启 harness（壳应用菜单 ⌘⇧R）。

## 配置

Profile 的 `cordis.patch.yml` 里覆盖 row config：

```yaml
- id: ui-dash-adapter
  config:
    topInset: 24   # px，0–200；壳内红绿灯经微调后纵向约占 24–38pt，24 让内容落在下缘附近
```

## 已知脆弱点

- 选择器 `[class*="_sidebarCol"]` / `[class*="_frame"]` 依赖 ui-layout CSS module 的语义类名后缀（hash 会变、后缀通常稳定）。dsh 升级后若 gap 消失，先核对 `@deepseek-ai/dsh-client-ui-layout` 的 `AppFrame.module.css` 类名。
- 全屏模式下红绿灯隐藏，但 gap 仍在（v1 接受；后续可由壳应用在全屏切换时翻转 CSS 变量）。
- **隐藏侧边栏模式**：
  - `ctx.layout` 只有 `toggleSidebar`（切换而非设定）；插件靠 `data-sidebar-collapsed` 属性反馈收敛到「收起」态。若 ui-layout 改用别的信号属性或 LayoutController 面貌变化，收起会失效（CSS 平移仍生效，只是多出 56px 空档在视口外，视觉无恙但 rail 不可达）。
  - 轨道平移假设 sidebar 轨道之外没有其它左缘元素；`computeColumns` 的 rail 常量 56px 由实时测量兜底，但若 AppFrame 结构改为非 grid 布局则需重写。
  - `overflow:hidden` 强加于 html/body：与全屏/滚动类未来特性可能冲突。
- **动作桥**：
  - `openSettings` 是 DOM 点击回退（无公开 API），依赖 ui-settings-general 触发按钮 `aria-haspopup="dialog"` 且位于 sidebarCol 内；若触发按钮搬家/换标记则点击落空（静默无效果）。隐藏侧边栏模式下设置面板渲染在被平移出视口的 sidebarCol 内，即使触发成功也看不见——原生侧边栏应自带设置入口。
  - `selectSession`/`startSession` 依赖 `sessions` / `workspaces` 反射服务名与 `open` / `startSession` 方法名（0.1.1-rc.2 的公开面，ui-workspace / ui-sidebar 同款调用）；服务缺席时对应能力静默缺失并在 ready capabilities 里如实反映。
  - `ready` 上报延时 1.5s 是经验值：服务 provision 若更慢，capabilities 可能缺项；壳侧亦可直接特征检测 `window.__dash.selectSession` 等。
