# 文案审校表（i18n 打磨）

`docs/clam-i18n-plan.md` 里程碑 i6 的产物：双语化那一遍**顺手改了中文措辞**的条目，
逐条摆出来交用户裁决语气（设计立场第 3 条：视觉／文案拿不定主意时停下来交裁决）。

**只列改过的**。没改中文的条目不在这里——各插件完整的字符串表在
`clam-app/host/Sources/Strings.swift`、`clam-sidebar/swift/Strings.swift`、
`clam-settings/swift/Strings.swift`、
`clam-notify/lib/strings.js`。判据是计划 §6：zh 对照 macOS 系统 App 用词、菜单项动词开头、
全角标点、不用「您」、不卖萌；en 菜单与按钮 Title Case、描述句 Sentence case、
单复数正确、对齐系统既有英文。

改动理由带 `⚠️` 的是**语气判断而非规则套用**的条目，末尾 [需要裁决的条目](#需要裁决的条目)
单独列了一遍。

## 壳（clam-app）

| 原文 | 新 zh | en | 改动理由 |
|---|---|---|---|
| 知道了（提示条上的关闭按钮，「壳重建失败」那条） | 好 | OK | ⚠️ 对齐系统 alert 的确认按钮用词，「知道了」是口语 |
| 立即重试 | 重试 | Try Again | 按钮只留动作本身，「立即」是多余修饰；en 用系统既有的 Try Again |
| 打开日志目录（应用菜单项） | 打开日志文件夹 | Open Log Folder | macOS 简中说「文件夹」，「目录」是终端用语 |
| 切换侧边栏（显示菜单项） | 切换边栏 | Toggle Sidebar | 对齐系统「边栏」用词（访达 → 显示 → 显示边栏） |
| 正在寻找 dsh…（引导页状态行） | 正在查找 dsh… | Looking for dsh… | 「查找」是系统用词，「寻找」偏文学 |
| 与 dsh 断开连接（引导页标题） | 已与 dsh 断开连接 | Disconnected from dsh | 补「已」，读成状态而不是正在发生的动作 |
| dsh 已退出或不再应答。重新运行下面的命令，X 会自动接回。 | dsh 已退出或停止响应。在终端重新运行下面的命令，X 会自动接回。 | dsh has quit or stopped responding. Run the command below in a terminal and X will reconnect automatically. | 「应答」换成系统词族的「响应」，并补出命令要在**终端**里跑 |
| 未检测到 dsh（引导页标题） | 找不到 dsh | dsh Not Found | 「未检测到」是仪器口吻，系统弹窗说「找不到…」 |
| X 是 dsh 的客户端外设，需要 dsh 先在终端跑起来；启动后本页会自动接入，无需重开 App。 | X 是 dsh 的客户端外设，需要先在终端启动 dsh。启动后本窗口会自动接入，无需重新打开 App。 | X is a client for dsh, which must be running in a terminal first. Once it starts, this window connects automatically — no need to reopen the app. | 「跑起来」「重开」是口语；「本页」不准确，这是一扇窗口不是网页 |
| 出错了（引导页错误标题） | 发生错误 | Something Went Wrong | ⚠️ zh 去口语化没有异议，en 不是系统既有说法 |
| 看日志（壳重建失败提示条上的按钮） | 查看日志 | View Log | 按钮用完整动词，「看」太随意 |
| 停止正在生成的回复（⌘/ 快捷键面板条目） | 停止生成 | Stop Generating | 快捷键面板一行一条，动作名要短到能与键帽并排 |

## clam-sidebar

| 原文 | 新 zh | en | 改动理由 |
|---|---|---|---|
| 删除工作区…（分组头右键菜单项） | 删除工作区… | Remove Workspace… | 只改 en：这个动作不删文件夹、只从列表移除，Delete 会误导 |
| 按时间（筛选胶囊） | 按时间 | By Date | ⚠️ 只改 en：那四段分的是日期；zh 是否跟着改成「按日期」没定 |
| 前 7 天（「按时间」分段头） | 过去 7 天 | Previous 7 Days | 对齐访达最近使用分组的「过去 7 天」 |
| 运行中（会话行状态的 AX label） | 正在运行 | Running | 系统的进行态说法是「正在…」 |
| 出错了（会话行状态） | 已出错 | Failed | ⚠️ 与同组「已归档／已完成」的句式统一，但「失败」也是候选 |
| 已跑完（会话行状态） | 已完成 | Done | 「跑完」是开发者口语 |
| 将把「X」从工作区列表中移除。文件夹与会话记录会保留，其会话将显示在「未分组」下。（删除工作区对话框正文） | 将把「X」从工作区列表中移除。文件夹与会话记录保留，其中的会话会显示在「未分组」下。 | “X” will be removed from the workspace list. The folder and its session history are kept, and its sessions move under “Ungrouped”. | 一句话里两个「会」读着别扭；「其会话」写成「其中的会话」 |
| 选择要作为工作区的文件夹（NSOpenPanel 说明） | 选取要作为工作区的文件夹 | Choose a folder to use as a workspace. | macOS 简中把 choose 译作「选取」 |
| 当前筛选下没有会话（空态） | 当前筛选条件下没有会话 | No sessions match the current filters. | 补「条件」，「筛选」在中文里是动词，直接当名词读不顺 |

## clam-settings

| 原文 | 新 zh | en | 改动理由 |
|---|---|---|---|
| 知道了（提示条上的关闭按钮，`SettingsPage.Banner`） | 好 | OK | ⚠️ 与壳同一处理：对齐系统确认按钮，「知道了」是口语 |
| 配置文档是只读的，这里改不了。（页头横幅） | 配置文档为只读，此处无法修改。 | The settings document is read-only and cannot be edited here. | 「改不了」是口语，说明句用「无法修改」 |
| 配置文档只读，改不动（写入失败提示条） | 配置文档为只读，无法修改。 | The settings document is read-only. | 「改不动」是口语，且句末缺句号 |
| 设置在别处被改过，已重新读取——请确认后再改一次（冲突提示条） | 设置已在别处修改，已重新读取，请确认后再试。 | The settings changed elsewhere and have been reloaded. Check them and try again. | 破折号在系统文案里少见，拆成分句；用户不一定要「再改」，说「再试」 |
| 这个配置源没有可打开的文件 | 此配置源没有可打开的文件。 | This settings source has no file to open. | 说明句用「此」并补句末句号 |
| 要一个数字（数字框的本地校验提示） | 请输入数字。 | Enter a number. | 校验提示用完整祈使句，「要一个数字」不成句 |
| 当前值的形状不是字典/数组，改不了（数组／字典编辑器） | 当前值不是字典，无法修改。 | The current value is not a dictionary and cannot be edited. | 「形状」是数据结构术语，不该出现在界面上 |
| schema 表达不了的字段在这里改。（通用页说明） | schema 无法表达的字段在这里修改。 | Fields the schema cannot express are edited here. | 「表达不了」「在这里改」是口语 |
| llm 服务不在场，这一页填不了。 | llm 服务未在场，这一页暂时不可用。 | The llm service is absent, so this tab is unavailable. | ⚠️ 「填不了」是口语且不准确（整页不可用，不只是填不了）；但「暂时」是否成立要看服务什么时候会回来 |
| 默认模型仍可在配置文件里改。 | 默认模型仍可在配置文件中修改。 | The default model can still be changed in the settings file. | 「里改」→「中修改」，与同页其它说明句一致 |
| 还没有配好的 provider。点 + 添加一个。（模型页空态） | 尚未配置任何 provider。点按 + 添加。 | No provider is configured yet. Click + to add one. | 「配好的」是口语；「点按」是 macOS 简中对 click 的译法 |
| 由只读来源提供（环境变量或 .env），这里改不了。（凭据行） | 由只读来源（环境变量或 .env）提供，此处无法修改。 | Supplied by a read-only source (an environment variable or .env) and cannot be edited here. | 括号限定的是「来源」不是「提供」，位置挪正；「改不了」去口语 |
| 目录里的 provider 都已经配过了。（添加 provider 的空态） | 目录里的 provider 都已经配置过了。 | Every provider in the catalog is already configured. | 「配过」补成「配置过」，与本页其它句子同词 |
| 改完需要重启 dsh 才生效。（插件配置说明） | 修改后需重新启动 dsh 才会生效。 | Changes take effect after dsh restarts. | 「改完」「重启」是口语，系统说「重新启动」 |
| 读不到插件清单（pluginInventory 服务不在场）。 | 无法读取插件清单（pluginInventory 服务未在场）。 | The plugin list is unavailable (the pluginInventory service is absent). | 「读不到」是口语；「不在场」统一成「未在场」 |
| agentPresets 服务不在场，这一页填不了。 | agentPresets 服务未在场，这一页暂时不可用。 | The agentPresets service is absent, so this tab is unavailable. | ⚠️ 同 llm 那条，两条必须一致；「暂时」是否成立同样待定 |
| 还没有（「自定义」预设组的空占位） | 暂无 | None | ⚠️ 「还没有」是半句话，但「暂无」偏公文腔，也可以只写「无」 |
| 在 Finder 中显示（预设的位置行） | 在访达中显示 | Reveal in Finder | 对齐 macOS 简中的「访达」，en 用访达右键菜单原词 Reveal |

## clam-notify

通知正文，两条都在系统通知横幅上。

| 原文 | 新 zh | en | 改动理由 |
|---|---|---|---|
| 有一步操作在等你放行 | 有一项操作等待批准 | An action is waiting for your approval | 「放行」是行话、「在等你」是拟人；量词用「项」与标题的「批准」对上 |
| 有一个问题在等你回答 | 有一个问题等待回答 | A question is waiting for your answer | 同上去掉「在等你」的拟人语气，与上一条句式统一 |

## i6 清查时补上的（原本整块漏了）

这两处不是「改措辞」，是**双语化时整块漏掉**、i6 截图验收时才看见的。
之前的表现不是缺字，而是**露出英文兜底**：`FieldNotes` 查不到就退回
`SettingsFormat.humanize`（真 key 的机械美化），所以中文界面下也写着 `New Session`。

### clam-settings 的「快捷键」栏（ns `clam-shortcuts`，11 条）

`clam-shortcuts` 是我们自己注册的 ns，i4 建表时没把它列进去。
键位名**与壳菜单里那一条逐字对齐**——这一栏改的就是那条菜单项的键。

| 原文（机械美化的兜底） | 新 zh | en | 改动理由 |
|---|---|---|---|
| Clam Shortcuts（栏标题） | 快捷键 | Shortcuts | 包名不是人话，与「原生观感」「通知」同处理 |
| New Session | 新建会话 | New Session | 对齐「文件 → 新建会话」 |
| Prev Session | 上一个会话 | Previous Session | 对齐「会话 → 上一个会话」；en 不用缩写 |
| Next Session | 下一个会话 | Next Session | 同上 |
| Next Pending Session | 下一个待处理会话 | Next Pending Session | 对齐菜单，也对齐侧边栏「待处理」胶囊 |
| Archive Session | 归档会话 | Archive Session | 对齐「文件 → 归档会话」 |
| Rename Session | 重命名会话 | Rename Session | 菜单里是「重命名会话…」，设置行不带省略号——省略号是「还要再问一步」的承诺 |
| Focus Search | 聚焦搜索 | Focus Search | 对齐「显示 → 聚焦搜索」 |
| Open Settings | 打开设置 | Open Settings | 对齐「设置…」 |
| Session Digits | 数字键跳转 | Jump by Number | ⚠️「Session Digits」是字段名不是人话；「数字键跳转」是新造词，没有系统对应 |
| Stop Generating | 停止生成 | Stop Generating | 与壳 ⌘/ 面板里那条同词 |

选项也一起翻了：`cmd` / `cmd+alt` / `off` 在界面上显示成 `⌘1–9` / `⌥⌘1–9` / 「关闭」`Off`
——这一格挑的是修饰键，把配置值 `cmd` 当标签既不像键也不像话。

### 出厂 preset 的名字与说明（clam-settings，4×2 条）

`agentPresets.list` 给的 `name` 是 preset 目录里那份文件写死的字（这台机器上是中文），
**不随语言变**；而 dsh 的网页对 `trust === "system"` 的四个内建 preset 改查自己的词典
（`dsh-client-ui-agent-preset` 的 `presetDisplayText`）。不照做就会出现
「网页写 Standard mode、原生写『标准模式』」——正是不变量 2 禁止的分叉。
所以 i6 把上游那张表**照抄**进 `L.builtInPreset` / `L.builtInPresetSummary`，
**id 与措辞逐字对齐上游**：

| id | zh | en |
|---|---|---|
| `standard` | 标准模式 | Standard mode |
| `code` | PTC 模式 | PTC mode |
| `minimal` | 极简模式 | Minimal mode |
| `cordis` | 创造模式 | Creator mode |

说明句同样照抄。**用户自己写的 preset 不翻**（上游原话：
"without making user-authored metadata translatable"）。
这是"照抄上游规则"而不是"另立一份真相"——与 i0 让 `ClamLocale.resolve`
逐字复刻 `detectBrowserLocale()` 是同一条理由。

## 需要裁决的条目

- **壳 / clam-settings** · 知道了 → 好 / OK ——「好」是 macOS alert 的确认按钮；
  用在提示条的**关闭**按钮上是否合适（「关闭」「忽略」也是候选）。
- **壳** · 出错了 → 发生错误 / Something Went Wrong —— zh 没有异议，
  en 的 "Something Went Wrong" 不是系统既有说法（系统多用 "An error occurred"），
  语气偏消费级 App。
- **clam-sidebar** · 按时间 → 按时间 / By Date —— 只改了 en；那四段分的确实是日期，
  zh 要不要跟着改成「按日期」没定，改了两处胶囊文案都得动。
- **clam-sidebar** · 出错了 → 已出错 / Failed —— 选「已出错」是为了与同组
  「已归档／已完成」句式统一，但状态词用「失败」更常见，二选一。
- **clam-settings** · llm / agentPresets 服务不在场，这一页填不了。→ …未在场，这一页暂时不可用。
  —— 「暂时」暗示等一等就好，而服务不在场通常要重启 dsh 才变；去掉「暂时」也成立。
- **clam-settings** · 还没有 → 暂无 / None ——「暂无」偏公文腔，
  列表空占位写「无」或干脆留破折号也是选项。
- **clam-settings** · Session Digits → 数字键跳转 / Jump by Number ——
  这一格挑的是「按住哪个修饰键 + 1～9」，系统里没有对应说法，两种语言都是新造词。

## 未改动但值得一提

这几处是**刻意不翻**，不是漏译：

- **clam-settings「语言」行的选项 `中文` / `English`**（`FieldNotes.swift` 的 `locale` ns）：
  照抄 dsh 上游 `LOCALES` 的写法。语言选择器列出各门语言时用那门语言自己的自述名是
  通行做法（macOS 的「语言与地区」亦然）；写成「中文／英文」反而会让只认得 English
  的人找不到自己那项。
- **`SettingsFormat.humanize` 的兜底标题两种语言共用一份**（`JSONValue.swift` / `FieldNotes.title`）：
  它出的是 `maxOutputBytes` → `Max Output Bytes` 这种由真 key 机械拆出来的词，
  本来就不是「中文文案的英文版」。zh 界面下露出英文字段名是可接受的——那正是配置文件里
  写着的东西，比编一个中文名更好查。
- **`FieldNotes.swift` 里用 `.same(_:)` 显式声明「不该翻」的值**，眼下共三处：
  `locale/preference` 的选项 `中文` 与 `English`（上一条）、
  `web-search-deepseek/apiKey` 的标题 `API key`（机器名词）、
  `clam-nativeify/bodyFontSize` 的单位 `px`。
  `.same` 是**声明**而不是占位：漏写 en 编译不过，写 `.same` 表示两种语言下写法真的相同。
  （`Strings.swift` 里另有一处同类：`L.apiKey` 与 `L.providerPicker` 直接返回字面量
  `API key` / `Provider`，不走 `t()`。）
- **AppKit 自己塞进菜单的那些项跟的是系统语言，不是 dsh 的 locale**（i6 实测）：
  dsh 设成 en 而系统是简体中文时，「退出并保留窗口」「全部关闭」「自动填充」
  「开始听写」「表情与符号」「移动与调整大小」「全屏幕平铺」以及帮助菜单那条
  反馈项**仍旧是中文**——它们由 AppKit 注入、文案在系统资源里，我们既没有句柄
  也不该去覆盖。同理还有 `NSSearchField` 内建搜索按钮的 AX 名「搜索」、
  窗口红绿灯的「关闭按钮」「最小化按钮」。**这是系统行为，不是漏译**：
  真要一致，用户改的是系统语言而不是 dsh 的设置。
