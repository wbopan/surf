import ClamSDK
import Foundation

/// zh / en 并排的一对文案。
///
/// **给 `FieldNotes` / `NamespaceNotes` 那两张表用**：那两张表的每一条是数据
/// （放在 `static let table` 里、语言未知时就已存在），没法像 `L` 那样按 locale
/// 现算，所以两种语言都存下来、取用时再挑一份。
///
/// 构造器**必须给两个参数**，漏写 en 编译不过——这就是那两张表的完备性检查
/// （`docs/clam-i18n-plan.md` §5「typed struct 就是完备性检查」）。
/// 两种语言写法真的相同时用 `.same(_:)` 显式声明，而不是把同一个串抄两遍。
struct LocalizedText {
    let zh: String
    let en: String

    init(_ zh: String, _ en: String) {
        self.zh = zh
        self.en = en
    }

    /// 两种语言下写法相同的条目：语言自述名（「中文」/「English」）、
    /// 产品与机器标识（`API key`、`px`）。**不是"还没翻"的占位**，是"不该翻"。
    static func same(_ text: String) -> LocalizedText { LocalizedText(text, text) }

    subscript(_ locale: ClamLocale) -> String { locale == .zh ? zh : en }
}

/// clam-settings 的全部**用户可见**文案，zh 与 en 并排写在同一行（审校时一眼对照）。
///
/// ## 纪律（`docs/clam-i18n-plan.md` §4/§5/§8，与壳、clam-sidebar、clam-header 同一套）
///
/// - **只收用户看得见的字**。`host.log(...)` 与 node 半边的日志一律留在原地、
///   保持中文：日志的读者是蹲在终端前的开发者与 agent，跟着界面语言变只会让
///   排错时对不上账。
/// - **一条文案都不进 ClamSDK**：SDK 只有 `ClamLocale` 这个词汇。
/// - **带插值的条目写成方法**，不搞 `{name}` 模板替换。
/// - **漏写 en 编译不过**：typed struct 就是完备性检查。
/// - 全是 `String`，没有 `LocalizedStringKey`——`TableColumn(_:value:)` 那个隐式
///   重载歧义坑（README「四条踩过的坑」最后一条）在这种形态下自动消失，
///   **但别顺手把中文字面量写回视图里**，那条坑会立刻回来。
/// - **定位标识与文案彻底解耦**：`settings.*` 那些 accessibilityIdentifier、
///   `SettingsTab.rawValue`、`fiberPhase` 的原始值都是稳定英文串，不随语言变。
///
/// ## 取值的地方
///
/// `SettingsModel.strings` **现算一份 `L`**（读 `ClamLocaleStore.current`，不存快照）。
/// SwiftUI 视图在 body 里读 `model.strings`（或 `model.locale`）就建立了对那个
/// `@Observable` 的观察依赖，语言一变整扇窗自动重渲——**不用
/// `withObservationTracking`**（观察者没人强持有就静默死，CLAUDE.md 记过案）。
///
/// **窗框那半边不在 SwiftUI 里**（`.preference` 工具栏的四个标签、窗口标题由
/// `NSTabViewController` 与 `NSWindow` 拿着），所以 `SettingsPlugin` 另订一次
/// `clam.locale`，回调里让 `SettingsWindowController.relocalize()` 重贴标签。
///
/// ## 数据不翻，只翻兜底词
///
/// provider 显示名、preset 名与描述、模块名、条目 id、上游报回来的错误原话
/// 都是 dsh 给的原样字符串（dsh 自己说中文还是英文由它的 locale 决定），
/// 这里只管我们自己造的词。
///
/// ## 打磨过的条目带 `// 原：…` 注释
///
/// zh 按 Apple 简体中文风格正式化（不用"改不动/填不了"这类口语，句末带句号），
/// en 按钮与标签 Title Case、说明句 Sentence case。改动较大的在行尾标出原文，
/// 供 i6 汇总成审校表交用户裁决。
struct L {

    let locale: ClamLocale

    init(_ locale: ClamLocale) { self.locale = locale }

    /// 二选一。写成函数只为让 zh / en 挤在同一行——没有任何查表逻辑。
    private func t(_ zh: String, _ en: String) -> String { locale == .zh ? zh : en }

    /// 「<数字> <量词>」。zh 只有一种形态，en 分单复数。
    private func count(_ n: Int, zh: String, one: String, many: String) -> String {
        locale == .zh ? "\(n) \(zh)" : "\(n) \(n == 1 ? one : many)"
    }

    /// `Form` 左列那个带冒号的标签。**冒号跟着语言走**（全角 / 半角）——
    /// 一整页右对齐的标签里混进一个半角冒号，对齐会差半个字宽。
    func labeled(_ title: String) -> String { t("\(title)：", "\(title):") }

    // MARK: - 通用按钮

    var ok: String { t("好", "OK") }
    var cancel: String { t("取消", "Cancel") }
    var save: String { t("保存", "Save") }
    var add: String { t("添加", "Add") }
    var remove: String { t("移除", "Remove") }
    var clear: String { t("清除", "Clear") }
    var retry: String { t("重试", "Try Again") }

    // MARK: - 窗框（不在 SwiftUI 里，见类型注释）

    /// 没有选中页时的窗口标题。正常情况下标题是当前那一栏的名字。
    var settingsWindow: String { t("设置", "Settings") }

    /// 四栏的名字——**工具栏标签、hosting controller 的 title、窗口标题共用一份**。
    func tabTitle(_ tab: SettingsTab) -> String {
        switch tab {
        case .general: return t("通用", "General")
        case .models: return t("模型", "Models")
        case .plugins: return t("插件", "Plugins")
        case .presets: return t("智能体预设", "Agent Presets")
        }
    }

    /// 用默认编辑器打开配置文件失败。路径是机器串，不翻。
    func openFailed(_ path: String) -> String {
        t("打开失败：\(path)", "Could not open \(path)")
    }

    // MARK: - 页面外壳

    /// 首帧还没到。**不能说"没有设置"**：没到跟真的没有是两回事。
    var connecting: String { t("正在连接 dsh…", "Connecting to dsh…") }
    var readOnlyBanner: String {
        t("配置文档为只读，此处无法修改。", "The settings document is read-only and cannot be edited here.")
    }  // 原：配置文档是只读的，这里改不了。

    // MARK: - 写入与提示条（SettingsModel）

    var readOnlyNotice: String {
        t("配置文档为只读，无法修改。", "The settings document is read-only.")
    }  // 原：配置文档只读，改不动
    /// host 没给原因时的兜底。**有原话就用原话**（那是 dsh 说的，不归我们翻）。
    var writeFailed: String { t("写入失败。", "The write failed.") }
    var clearFailed: String { t("清除失败。", "Clearing it failed.") }
    /// 桥上等回执超时。**这一条是我们自己合成的**，上游根本没回话。
    var timedOut: String { t("没有响应，dsh 可能已断开。", "No response — dsh may have disconnected.") }
    /// `credentials` 服务不在场（node 半边认领的失败，code `CREDENTIALS_UNAVAILABLE`）。
    var credentialsUnavailable: String {
        t("凭据服务未在场，无法保存 key。", "The credentials service is absent, so the key cannot be saved.")
    }

    /// 一条失败回执翻成给人看的一句话。
    ///
    /// 顺序是**先查 code、再用原话、最后兜底**：
    /// - `code` 认得出 = 这条失败是**我们自己合成的**（超时、服务不在场），
    ///   它的 `message` 只是给日志看的英文，界面该说自家表里那句。
    /// - 认不出的 code（`SETTINGS_CONFLICT` 这类上游给的）走原话：那是 dsh 说的，
    ///   按它自己的 locale 出，不归我们翻。
    /// - 两者都没有才用调用点给的兜底。
    func failureMessage(error: String?, code: String?, fallback: String) -> String {
        switch code {
        case "TIMEOUT": return timedOut
        case "CREDENTIALS_UNAVAILABLE": return credentialsUnavailable
        default: break
        }
        if let error, !error.isEmpty { return error }
        return fallback
    }
    var conflictNotice: String {
        t("设置已在别处修改，已重新读取，请确认后再试。",
          "The settings changed elsewhere and have been reloaded. Check them and try again.")
    }  // 原：设置在别处被改过，已重新读取——请确认后再改一次
    var noDocument: String {
        t("此配置源没有可打开的文件。", "This settings source has no file to open.")
    }  // 原：这个配置源没有可打开的文件

    // MARK: - 字段行

    var saving: String { t("保存中…", "Saving…") }
    /// 悬停提示的末段：这一项被用户覆盖过。
    var overridden: String { t("已覆盖默认值", "Overrides the default") }
    /// 重置按钮的 tooltip。退回去的值不知道是什么时用这句。
    var resetToInherited: String { t("重置（退回继承）", "Reset to Inherited") }
    func resetTo(_ value: String) -> String { t("重置为 \(value)", "Reset to \(value)") }
    /// 数字框里敲了非数字。**本地判定，不往返一趟**。
    var mustBeNumber: String { t("请输入数字。", "Enter a number.") }  // 原：要一个数字
    /// 非必填字段的下拉框里那一项"退回继承"。
    var unsetOption: String { t("（未设置）", "(Not set)") }
    /// secret 的占位符。语义反直觉但照抄上游：空输入 = 保留现有 key。
    var secretConfigured: String { t("已配置（留空 = 不变）", "Configured (leave empty to keep)") }
    var secretUnset: String { t("未配置", "Not configured") }
    /// schema 约束里的步长。`≥` / `≤` 那两段是符号，不进表。
    func step(_ value: String) -> String { t("步长 \(value)", "step \(value)") }

    // MARK: - 值摘要（JSONValue.summary，「重置为 X」也复用它）

    var on: String { t("开", "On") }
    var off: String { t("关", "Off") }
    /// 空字符串的显示形态。**不是"没有值"**（那是 `—`）。
    var emptyString: String { t("（空）", "(Empty)") }
    func itemCount(_ n: Int) -> String { count(n, zh: "项", one: "item", many: "items") }
    func fieldCount(_ n: Int) -> String { count(n, zh: "个字段", one: "field", many: "fields") }

    // MARK: - 标量数组 / 字典编辑器

    var emptyList: String { t("空", "Empty") }
    var newItemKey: String { t("键", "Key") }
    var newItemValue: String { t("值", "Value") }
    /// 折叠区里那个"追加一条"的按钮，紧挨输入框，所以短。
    var appendItem: String { t("加", "Add") }
    func shapeMismatch(isDict: Bool) -> String {
        t("当前值不是\(isDict ? "字典" : "数组")，无法修改。",
          "The current value is not \(isDict ? "a dictionary" : "an array") and cannot be edited.")
    }  // 原：当前值的形状不是字典/数组，改不了

    // MARK: - 通用页

    var configFile: String { t("配置文件", "Settings File") }
    var openInEditor: String { t("在编辑器中打开…", "Open in Editor…") }
    var configFileHint: String {
        t("schema 无法表达的字段在这里修改。", "Fields the schema cannot express are edited here.")
    }  // 原：schema 表达不了的字段在这里改。
    /// 外观那一行的重置 tooltip（那一行没有"继承"的说法，它总有一个默认值）。
    var resetToDefault: String { t("退回默认", "Reset to Default") }
    /// 配置里写着一个已经删掉的预设 id 时，下拉框照样显示它并标出来。
    func presetNotInList(_ id: String) -> String {
        t("\(id)（清单里没有）", "\(id) (not in the list)")
    }

    // MARK: - 模型页

    var modelsUnavailable: String {
        t("llm 服务未在场，这一页暂时不可用。", "The llm service is absent, so this tab is unavailable.")
    }  // 原：llm 服务不在场，这一页填不了。
    var modelsUnavailableHint: String {
        t("默认模型仍可在配置文件中修改。", "The default model can still be changed in the settings file.")
    }  // 原：默认模型仍可在配置文件里改。
    var addProvider: String { t("添加 provider", "Add Provider") }
    /// `−` 的 tooltip。**它清的是 key，不是 provider**，所以说清楚。
    var clearProviderKey: String { t("清除这个 provider 的 API key", "Clear this provider's API key") }
    var noProviders: String {
        t("尚未配置任何 provider。点按 + 添加。", "No provider is configured yet. Click + to add one.")
    }  // 原：还没有配好的 provider。点 + 添加一个。
    var facetCredential: String { t("凭据", "Credential") }
    var facetSettings: String { t("自定义设置", "Custom Settings") }
    /// **状态只在异常时说话**：路由活着的时候详情栏一个字都不写（左列的绿点已经说过了）。
    var routeUnregistered: String { t("路由未注册", "Route not registered") }
    /// 左列状态点的 tooltip：凭据 + 路由两件事，正常与否都报。
    func providerStatus(configured: Bool?, live: Bool) -> String {
        let credential: String
        switch configured {
        case true: credential = t("凭据已配置", "Credential configured")
        case false: credential = t("没有 key", "No key")
        default: credential = t("凭据状态未知", "Credential status unknown")
        }
        return credential + " · " + (live ? t("路由已注册", "Route registered") : routeUnregistered)
    }
    /// 「API key」是机器名词，两种语言同一个写法。
    var apiKey: String { "API key" }
    var apiKeyPrompt: String { t("填入 API key", "Enter the API key") }
    /// 已经配过 key 时的占位符。语义同 `secretConfigured`，但这一格旁边就写着
    /// 「凭据」，不必再说一遍"已配置"。
    var apiKeyKeep: String { t("留空 = 保留现有的", "Leave empty to keep the current key") }
    var credentialReadOnly: String {
        t("由只读来源（环境变量或 .env）提供，此处无法修改。",
          "Supplied by a read-only source (an environment variable or .env) and cannot be edited here.")
    }  // 原：由只读来源提供（环境变量或 .env），这里改不了。
    /// key 存在凭据库里的哪个名下。`derived` = 这个名字是按 web 的约定推出来的，
    /// 配置里并没有写。
    func keyReference(_ ref: String, derived: Bool) -> String {
        let head = t("引用名 \(ref)", "Reference name \(ref)")
        guard derived else { return head }
        return head + t("（按约定推出来的）", " (derived by convention)")
    }
    func willWriteKeyReference(_ ref: String) -> String {
        t("会写到引用名 \(ref)", "Will be stored under the reference name \(ref)")
    }
    var providerPicker: String { "Provider" }
    var catalogExhausted: String {
        t("目录里的 provider 都已经配置过了。", "Every provider in the catalog is already configured.")
    }  // 原：目录里的 provider 都已经配过了。

    // MARK: - 插件页

    var sectionConfiguration: String { t("插件配置", "Plugin Configuration") }
    var sectionInventory: String { t("插件列表", "Plugin List") }
    var noConfigurablePlugins: String { t("没有可配置的插件。", "No plugin exposes any settings.") }
    /// 左列里"Web 没手工登记过的那些 ns"那一组的组头。**排在后面，不是藏起来**。
    var otherNamespaces: String { t("其余", "Others") }
    var restartRequired: String {
        t("修改后需重新启动 dsh 才会生效。", "Changes take effect after dsh restarts.")
    }  // 原：改完需要重启 dsh 才生效。

    // MARK: - 插件列表（只读）

    var inventoryUnavailable: String {
        t("无法读取插件清单（pluginInventory 服务未在场）。",
          "The plugin list is unavailable (the pluginInventory service is absent).")
    }  // 原：读不到插件清单（pluginInventory 服务不在场）。
    var inventoryUnreadable: String { t("暂时无法读取插件。", "The plugin list could not be read.") }
    var searchPlugins: String { t("搜索插件", "Search plugins") }
    var columnName: String { t("名称", "Name") }
    var columnEntry: String { t("条目", "Entry") }
    var columnStatus: String { t("状态", "Status") }
    /// 表底那行计数。**「默认顺序即装载顺序」是这张表唯一的使用说明**：
    /// 不点表头时的行序是 Loader 序，它本身有信息量。
    func inventorySummary(total: Int, disabled: Int) -> String {
        t("\(total) 个插件 · \(disabled) 个已停用 · 默认顺序即装载顺序",
          "\(total) plugins · \(disabled) disabled · default order is load order")
    }
    func inventoryMatches(shown: Int, total: Int) -> String {
        t("匹配 \(shown) / \(total)", "\(shown) of \(total) match")
    }
    /// Cordis 生命周期相位。**zh 照抄上游 `dsh-client-ui-settings-plugin-inventory`
    /// 的 locales**——两边说的是同一件事就该用同一个词。
    func pluginPhase(_ phase: String?) -> String {
        switch phase {
        case "pending": return t("等待依赖", "Pending")
        case "loading": return t("加载中", "Loading")
        case "active": return t("已挂载", "Active")
        case "failed": return t("挂载失败", "Failed")
        case "unloading": return t("卸载中", "Unloading")
        default: return t("未挂载", "Not mounted")
        }
    }
    /// 状态列显示什么。停用的条目没有 root Fiber，相位无从谈起。
    func pluginStatus(enabled: Bool, phase: String?) -> String {
        enabled ? pluginPhase(phase) : t("已停用", "Disabled")
    }

    // MARK: - 智能体预设页

    var presetsUnavailable: String {
        t("agentPresets 服务未在场，这一页暂时不可用。",
          "The agentPresets service is absent, so this tab is unavailable.")
    }  // 原：agentPresets 服务不在场，这一页填不了。
    var presetsBuiltIn: String { t("内建", "Built-in") }
    var presetsCustom: String { t("自定义", "Custom") }
    /// 「自定义」那组一条都没有时的占位。
    var presetsNone: String { t("暂无", "None") }  // 原：还没有
    /// 已经是默认预设时的**陈述**（不是按钮——那一格没有可做的动作）。
    var isDefaultPreset: String {
        t("新会话默认用这个预设", "New sessions use this preset by default")
    }
    var setAsDefault: String { t("设为默认", "Set as Default") }
    var presetLocation: String { t("位置", "Location") }
    var revealInFinder: String { t("在访达中显示", "Reveal in Finder") }  // 原：在 Finder 中显示（对齐 macOS 简中的「访达」）
}
