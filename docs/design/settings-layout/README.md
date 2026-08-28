# surfclam 设置窗口 · 版式草图

画布（私有 artifact，可从页面分享菜单发出去）：
<https://claude.ai/code/artifact/b405ba22-c845-492e-a8fd-20db6db15768>

这里是画布的**源文件**。画布本身是 claude.ai 上的一份托管页面，
仓库里留源是为了：改动可 diff、离线也打得开、artifact 没了还能重建。

```
Main.dc.html        通用（纯表单）
Models.dc.html      模型（主从 + 内层分段 + 默认模型组）
Plugins.dc.html     插件 · 插件配置（主从取代手风琴）
PluginList.dc.html  插件 · 插件列表（Table）
Presets.dc.html     智能体预设（主从；设为默认 = 复选框）
Anatomy.dc.html     版式规则本身 + 控件在 SwiftUI 里的真名
canvas.json         画板在画布上的排布、便签
mk.mjs / _parts.mjs 生成上面六张（改版式改这两个，再 `node mk.mjs`）
```

## 主张

**整扇窗只该有两种版式**：

- 「通用」= 纯表单 —— `Form` + `.formStyle(.columns)`，右对齐标签列 + 左对齐控件列。
- 模型 / 插件 / 智能体预设 = 主从 —— 带边框的源列表 + 右边的详情，
  而详情里用的还是同一套表单语法。

改之前的毛病不是内容而是语法：一页表单、一页灰色圆角列表、一页手风琴、
一页两列卡片网格，四种排版没一种是从 macOS 偏好设置那套语法来的。

## 三条最容易漏的细节

1. **分隔线只跨控件列**，不是整窗横线。它分的是控件的组，不是页面。
2. **复选框没有左标签**，文案本身就是它的标签，紧贴控件列起点。
3. **单位、量词一律甩到控件右边**，绝不进标签列——列宽是整张表共享的，
   一个长标题顶歪一整页。

## 别自己搭清单：原生大控件都在

macOS 27 SDK 的 `SwiftUI.swiftinterface` 里逐条核过：

| 用途 | API |
|---|---|
| 插件列表 | `Table(of:selection:sortOrder:)` + `TableColumn`，`.tableStyle(.bordered(alternatesRowBackgrounds: true))` |
| 主从的源列表 | `List(selection:)` + `.listStyle(.bordered(alternatesRowBackgrounds:))` |
| `+ −` 页脚 | `.safeAreaInset(edge: .bottom)` |
| 搜索框 | `.searchable(text:placement:prompt:)` |
| 任意容器隔行底色 | `.alternatingRowBackgrounds()` |

`Table` 白送的正是手搓 `LazyVGrid` 一样都没有的：表头点一下排序、⌘/⇧ 多选、
键盘上下走行、列宽拖拽，以及 `TableColumnCustomization` + `customizationID`
（用户自己增删列并记住）。171 条的清单，这些不是锦上添花。
