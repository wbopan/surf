# dash-settings

一扇真正的原生设置窗口：**窗框、导航、控件全是 AppKit/SwiftUI**，不加载任何网页。
数据面由跑在 dsh 进程里的 node 半边直接消费 host 服务（`ctx.settings` / `ctx.llm` /
credentials / `ctx.agentPresets` / `ctx.pluginInventory`），桥上只走 JSON 快照与动作。

权威计划在 [`docs/dash-settings-plan.md`](../docs/dash-settings-plan.md)——
动手前先读它，尤其 §1（三条走不通的路，别重走）、§4（编辑器语义）、§5（三条红线）。

**当前进度：M0～M7 全部完成**，四栏与 Web 逐条对齐。全链路实测过：在原生窗口点一下
「深色」，`~/.dsh/settings.yaml` 当场变、浏览器里的 dsh Web UI 当场跟着换肤；
插件列表 171 条、Loader 顺序与 29 条停用名单都与 Web 逐条比对一致。

```
lib/index.js     快照往下推（describe → 有序 JSON）、单字段 op 往上收、ack 配对
lib/models.js    模型页数据面：llm × credentials，运行时嵌套
lib/presets.js   预设画廊数据面：agentPresets（**不是** ctx.settings）
lib/inventory.js 插件列表数据面：pluginInventory，只读
swift/           SettingsSchema/JSONValue（解码）· SettingsModel（状态）·
                 SettingsChrome（版式公用件：FormRule / 源列表外框 / NSSearchField）·
                 FieldRow/FieldControls/ScalarListEditor（七种编辑器语义）·
                 GeneralPage/ModelsPage/PluginsPage/PresetsPage（四栏）·
                 PluginInventoryList（插件列表）· FieldNotes（注解表）
tools/probe.mjs  不开窗口、不碰屏幕，直接当"壳"连桥验数据面
```

## 版式：两种布局，不许有第三种

草图与依据在 [`docs/design/settings-layout/`](../docs/design/settings-layout/)。
一句话：**能一屏排完的用表单，是一组同类东西的用主从**。

| | 用在哪 | 长相 |
|---|---|---|
| 表单 | 通用 | `Form(.columns)`：右对齐标签列 + 左对齐控件列，组间一条只跨控件列的线 |
| 主从 | 模型 / 插件配置 / 智能体预设 | `List(selection:)` + `.listStyle(.bordered)` 左列，右边详情 |
| 表 | 插件列表 | `Table` + `.tableStyle(.bordered(alternatesRowBackgrounds: true))` |

主从换来的不只是好看：选中、上下键、⌘/⇧ 多选全归系统，而"编辑"这个中间状态
整个消失了。插件页那层「更多设置（N 项）」的折叠因此可以删掉——详情栏一次摊得下
`shell` 全部六个字段，**零遗漏不再需要拿一次点击去换**。

### 四条踩过的坑

- **`Divider()` 放进 `LabeledContent` 会变成竖线。** 它的方向跟父容器布局轴走，
  而 `LabeledContent` 内部是 HStack。要横线就自己画 `Rectangle().frame(height: 1)`。
- **`LabeledContent` 的 label 写 `EmptyView()`，整行会塌成全宽**，线从窗口左边距
  一直画到右边距。给一个零尺寸但真实存在的 label（`Color.clear.frame(width: 0)`），
  它照常占住标签列，线才从控件列起点开始。用红色 3pt 线截一次图就看出来了。
- **`.safeAreaInset` 塞不进 bordered list 的边框里**，只会得到一条没对齐、还比列表
  宽的浮条。macOS 这一代本来就是 `+ −` 在框外下方（用户与群组、Mimestream 都是）。
- **`.searchable` 在这扇窗里一个像素都画不出来**（不报错）。它要把搜索框塞进导航
  容器的工具栏，而我们的工具栏是 `NSTabViewController(tabStyle: .toolbar)` 建的，
  SwiftUI 够不着。包一层 `NSSearchField` 是拿到这个原生控件的唯一路子。
- **`TableColumn` 的排序键必须是 `String` 或别的有专属重载的类型。** 中文字面量在
  `value:` 是非 String `Comparable` 时会在 `LocalizedStringKey` 与
  `LocalizedStringResource` 两个重载间歧义；换成 `Text` 标签又会解析到
  `SortDescriptor` 那一族，和 `Table(sortOrder:)` 的 `KeyPathComparator` 不兼容。
  办法是给 model 加一个 `String` 计算属性（`statusText`）按它排——顺带保证
  **排的和显示的是同一个东西**。

### 窗口宽度是常量

`SettingsTab.windowWidth = 720`，四页共用。让每页各报各的宽度看着合理，实际效果是
**切一次标签窗口就横着抽一下**——macOS 上没有一个偏好设置窗口这么干：高度跟着内容
变，宽度钉死在最宽那页需要的宽度上。纯表单的通用页在 720 里取自己的理想宽度再居中
（`fixedSize(horizontal:)` + 居中 frame），前提是每条 hint 都有 `maxWidth` 上限，
否则"理想宽度"就成了最长那句注解的全长。

### Liquid Glass 是浮层的材质，不是控件的材质

表单里的按钮和分段控件"没有玻璃效果"**不是没启用**。玻璃属于浮在内容之上那一层
——工具栏、sidebar、sheet、浮动控件条——自动获得；嵌在 `Form` 里的控件按设计拿不到。
同一个 `Picker(.segmented)` 放进工具栏是玻璃胶囊，放进 `Form` 就是扁平方角、选中态
一块实心 accent 色。对照台在 [`docs/spikes/liquid-glass/`](../docs/spikes/liquid-glass/)，
`run.sh` 一跑就看得见。

推论有两条：窗口工具栏那四个标签本来就是玻璃，不用管；页内该用玻璃的地方只有导航层，
也就是下面这条。

### 页内分栏用 `TabView`，不用 `Picker(.segmented)`

分段控件的选中态是**一整块实心 accent 色**，在一屏灰白里非常刺眼，而且它本来是
"选一个值"的控件，不是"切一个视图"的。macOS 切视图的控件是 `NSTabView`——SwiftUI
这边就是 `TabView` 的默认样式：标签是玻璃凸起的一枚，**没有 accent 色**，骑在内容
面板的上沿，面板自己带圆角和浅色底。参考图里 Accounts 那三个标签就是它。

换过来之后不只是颜色变了：内容区自动获得那块圆角面板，于是「插件」整页、以及
「模型」页的详情栏，形状和参考图对上了。面板是 tab 的内容区，所以**没有 tab 的页
就没有面板**（通用、智能体预设）——这是系统的规则，不是我们随手定的。

代价是面板的边框和标签条要占高度：插件页的定高因此从 480 提到 520，不然底部那行
计数会被面板下沿压掉半个字。

### 别自己画系统控件

源列表底下那对 `+ −` 是真的 `NSSegmentedControl`（`.smallSquare` + momentary），
不是两个 `Button` 加一条 `Divider()`。参考图里那对加减中间的竖线正是分段控件的段间
线；手搓能画得很像，但按下态、段宽、图标度量、禁用灰度全得自己维护，而且每代 macOS
都在改这些材质。同理状态点用 SF Symbol `circle.fill` 而不是 `Circle()`——符号走系统
字形度量，跟着行内文字的基线和字号走。

`NSViewRepresentable` 记得实现 `sizeThatFits`：不实现它就会吃掉父容器给的全部宽度，
于是那对加减在列表底下**居中**，外面套 `HStack { …; Spacer() }` 也顶不动。

### 选中项要写回 binding

详情栏"选中项没了就回落到第一个"是对的，但**只回落详情不写回 `selection`**，左列就
一行都不高亮——看着像坏了。三页都在 `.onAppear` / `.onChange(of:)` 里把它补上。

### 定高页与自量高页

`SettingsTab.height` 非空的页是定高的（模型 430 / 插件 480 / 预设 360），只有纯表单
的通用页走 `SelfSizingScroll` 量内容。**两者不能叠**：`List` / `Table` 要一个确定
高度才肯布局，外面再套一层量高度的滚动容器就互相等死。

## 为什么数据面在 node 半边而不是 Swift 直连 HTTP

`/api/*` 那套 wire 是给远程浏览器准备的窄面，host 服务面更宽。我们本来就在 dsh
进程里，没理由从窄的那头进；附带好处是进程内事件（`settings/document-updated`、
`llm/adapters-updated`）直接可订，不必再开一条 SSE，Swift 侧连 DSHKit 都不需要。

## 缺席时会发生什么（这是设计好的，不是意外）

`settings` 服务是**硬 inject**：服务不在，整个插件不挂载 → Swift 半边不会去占
`DashObjects.Key.settingsOwner` → dash-layout 见无主，⌘, 回落到 dsh 自己的页内
modal。一个设置界面缺席时的正确姿态是让位给还能用的那个，不是开出一扇空窗。

`llm` / `credentials` 反过来：它们缺席只该让「模型」那一页不出现，不该连累整扇窗口，
所以**不写进静态 inject**，而用 `ctx.inject([...], cb)` 运行时嵌套（M4）。
这个 cordis fork 的 `inject` 只有数组与 intercept-config 两种形态，
没有 `{required, optional}`——嵌套是它表达可选依赖的唯一方式。

## 没有 client 半边

设置的渲染完全在原生这边，页面里什么都不改。顺带白捡一条：不必踩
「`__ModuleLoader__.load({id})` 的 id 必须逐字等于包名」那个坑。

## 编排照抄 Web，外壳照抄 macOS

**内容编排以 dsh Web 设置对话框为准**（General / Models / Plugins / Agent presets 四栏，
逐行同序同文案；Plugins 底下 Plugin configuration 与 Plugin list 两小栏也都在），
**窗框以 macOS 偏好设置为准**（`NSWindow.toolbarStyle = .preference` +
`NSTabViewController(tabStyle: .toolbar)`，切页时窗口动画到该页的尺寸）。
这两件事互不冲突：一致的是"东西在哪儿"，不是"长什么样"。

映射表在 [`swift/SettingsTabs.swift`](swift/SettingsTabs.swift)，**有意的分歧**写在那里：

| | Web | 这里 | 为什么 |
|---|---|---|---|
| 提交 | 每张卡片 Discard / Save | 即时生效 | 计划 D1，macOS 惯例 |
| 字段 | 每个 ns 只露手挑的几个（`shell` 六个只露两个） | 精选照露，其余进「更多设置」折叠 | 零遗漏优先于一致（计划 §2.2） |
| 命名空间 | 没手工登记过的整个藏掉 | 排在后面，不消失 | 同上 |
| 默认预设 | 只在 General 的下拉框里改 | 另加预设卡片上的「设为默认」 | 画廊里选默认比回上一栏顺手 |

三条数据面各有各的宿主服务，**缺一个只塌一页**（运行时 `ctx.inject` 嵌套）：
模型页要 `llm` + `credentials`，预设页要 `agentPresets`，插件列表要 `pluginInventory`。

**插件列表是只读的，Web 那边也是。** `@deepseek-ai/dsh-host-plugin-inventory`
整个服务只有一个 `list()`，它的客户端包 README 把这条写死了——"Read-only Loader view …
does not add plugin mutation controls"。那个「已启用/已停用」是编排表的**投影**，
不是开关；真要启停得改编排表再重启。**给一个点了不动的开关比没有开关糟得多。**

## 字段文案从哪来

**schema 里一个字都没有**——上游 meta 的全集就 `required/default/role/min/max/step`，
没有 description，也没有"该不该给人看"。所以渲染是**纯 schema 驱动**（字段永远齐、
新 ns 自动出现），文案与「通用」页的精选来自一张手写的薄注解表
[`swift/FieldNotes.swift`](swift/FieldNotes.swift)：注解命中就用人话，
没命中就把键名机械美化一下照常渲染。

**不刮上游 web 产物**（计划 §1.3）：那是把别人的构建输出当 API 用，
升一次 dsh 就可能碎，而且碎得很安静。

## 怎么验它

```sh
node dash-settings/tools/probe.mjs              # 快照概览：ns / 字段数 / 覆盖数 / revision
node dash-settings/tools/probe.mjs --ns shell   # 某个 ns 的 schema 与值
node dash-settings/tools/probe.mjs --providers  # 模型页的数据
node dash-settings/tools/probe.mjs --set        # 写入 / 回读 / 乐观锁冲突 / 还原
```

数据面全跑在 dsh 进程里，跟 SwiftUI 没有半点关系——用截图验它等于让 21KB 的 JSON
通过一张 PNG 汇报自己。探针在屏幕锁着时照样能跑，实测已经靠它揪出过一个真 bug
（`refresh` 只重推 settings 不重推 providers，模型页会永远停在"llm 不在场"）。
