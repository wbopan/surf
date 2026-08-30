import ClamSDK
import Observation
import SwiftUI

/// 连接偏好在设置窗口这一侧的持有者：**盘上那份**（下次打开时生效）与
/// **壳此刻正跑着的那份**（粘性投影）并排放着，两者不一致就是"改了还没重启"。
///
/// **为什么不直接调壳的 `ConnectionController`**：clam-settings 的 swift 半边虽然
/// 与壳同进程，但它是运行时编出来的 dylib，`import` 不到壳里的类型（壳是预编译
/// 产物，不导出 module）。所以这一栏的数据面只有两种东西：
///
/// - **偏好**：`UserDefaults` 直接读写（键名字面量，权威在
///   `clam-app/host/Sources/Native/ConnectionController.swift`，登记在
///   `docs/clam-contracts.md` §10.2）；
/// - **状态**：订粘性主题 `clam.connection.state`（§4），只读。
///
/// 写偏好**不会当场切后端**（§11.2 裁决③）：这一栏说的是"打开 App 时"，
/// 当场把用户正在用的连接换掉不是他按那几个段控的意思。
@Observable
final class ConnectionPrefs {

    // MARK: - 契约字面量

    static let modeKey = "clam.connection.mode"
    static let fixedURLKey = "clam.connection.fixedURL"
    static let stateTopic = "clam.connection.state"
    /// 请壳重启自己。**瞬间消息**（壳订阅，spawn 一个等本进程死透再 open 的助手）。
    static let relaunchTopic = "clam.app.relaunch"

    /// 三段的稳定标识。**与 `ConnectionMode.rawValue` 逐字相同**——它们是同一个
    /// 字符串写在 UserDefaults 里，不是各写各的。空串 = 未设置。
    enum Mode: String, CaseIterable {
        case managed, fixed, auto
    }

    // MARK: - 盘上那份

    /// 未设置时是 nil：**unset ≠ auto**（§11.1）。
    private(set) var pendingMode: Mode?
    /// 地址输入框里的原文。**坏值只留在这儿，不落盘**——落一个连不上的串等于
    /// 让用户下次打开时对着一屏"无法连接"猜自己敲错了什么。
    var draftURL: String {
        didSet {
            guard draftURL != oldValue else { return }
            if let normalized = Self.normalized(draftURL) {
                UserDefaults.standard.set(normalized, forKey: Self.fixedURLKey)
            }
        }
    }

    /// 地址不成立（空串不算——那只是还没填）。
    var draftInvalid: Bool {
        !draftURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Self.normalized(draftURL) == nil
    }

    // MARK: - 壳此刻跑着的那份（`clam.connection.state`）

    private(set) var phase = ""
    private(set) var effectiveMode = ""
    private(set) var effectiveFixedURL = ""
    private(set) var connectedURL: String?
    private(set) var managed = false

    @ObservationIgnored private let bus: ClamEventBus
    /// **必须有人接住**：`ClamDisposable` 一析构就退订，而这一栏的状态行会
    /// 从此永远停在初值上（不报错、不打日志）。
    @ObservationIgnored private var subscription: ClamDisposable?

    init(bus: ClamEventBus) {
        self.bus = bus
        let raw = UserDefaults.standard.string(forKey: Self.modeKey) ?? ""
        pendingMode = Mode(rawValue: raw)
        draftURL = UserDefaults.standard.string(forKey: Self.fixedURLKey) ?? ""
        // 粘性主题：subscribe 那一刻就会同步回调一次当前值（窗口晚开也拿得到）。
        subscription = bus.subscribe(Self.stateTopic) { [weak self] payload in
            guard let self else { return }
            self.phase = payload["phase"] as? String ?? ""
            self.effectiveMode = payload["mode"] as? String ?? ""
            self.effectiveFixedURL = payload["fixedURL"] as? String ?? ""
            self.connectedURL = payload["url"] as? String
            self.managed = payload["managed"] as? Bool ?? false
        }
    }

    // MARK: - 写偏好

    func setMode(_ next: Mode?) {
        guard next != pendingMode else { return }
        pendingMode = next
        if let next {
            UserDefaults.standard.set(next.rawValue, forKey: Self.modeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.modeKey)
        }
    }

    /// 盘上那份与壳正跑着的那份不一致 = 改了还没重启。
    ///
    /// **判据是"壳在跑什么"而不是"启动时是什么"**：壳自己也会改这两个键
    /// （引导页点「开启托管」就落 managed），拿一份启动快照比对的话，那种情况下
    /// 会冒出一颗永远消不掉的 [立即重启]。
    var needsRestart: Bool {
        let diskMode = pendingMode?.rawValue ?? "unset"
        // 壳还没投影过（连接页都没起来）时不显示按钮：没有可比的对象。
        guard !effectiveMode.isEmpty else { return false }
        if diskMode != effectiveMode { return true }
        guard diskMode == Mode.fixed.rawValue else { return false }
        // 坏值不算"改了"——它根本没落盘。
        guard let normalized = Self.normalized(draftURL) else { return false }
        return normalized != effectiveFixedURL
    }

    func requestRelaunch() {
        bus.emit(Self.relaunchTopic)
    }

    // MARK: - 地址规范化

    /// **与 `ConnectionController.normalizedURL(from:)` 同规则的副本**：裸端口号补成
    /// `http://127.0.0.1:<port>`、没写 scheme 的补 `http://`、只认 http / https。
    ///
    /// 抄一份而不是共用，是因为壳的类型跨不过 dylib 边界（见类型注释）。
    /// **规则改了两处一起改**——不然这一栏会把壳其实认得的地址标成红字。
    static func normalized(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.allSatisfy({ $0.isNumber }), let port = Int(text), (1...65535).contains(port) {
            return "http://127.0.0.1:\(port)"
        }
        let withScheme = text.contains("://") ? text : "http://" + text
        guard let url = URL(string: withScheme),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url.absoluteString
    }
}

/// 「连接」页——第五栏。版式照通用页（`Form(.columns)`、右对齐标签、注解压在
/// 控件下），画板见 `.scratch/design-connection-settings/{Main,Fixed,Auto}.dc.html`。
struct ConnectionPage: View {
    @ObservedObject var model: SettingsModel

    private var prefs: ConnectionPrefs { model.connection }
    private var strings: L { model.strings }

    var body: some View {
        Form {
            startupRow
            if prefs.pendingMode == .fixed { addressRow }
            if prefs.needsRestart { restartRow }
            FormRule()
            currentRow
        }
        .formStyle(.columns)
    }

    /// 「打开 App 时：」三段。
    ///
    /// **未设置时三段都不选中**（tag 对不上任何一段 = 无选中），注解那一行如实
    /// 写"打开时显示连接页面"。把 unset 悄悄画成 auto 会让用户以为自己已经选过了
    /// ——而那正是 §11.1 要拆开的那个误会。
    private var startupRow: some View {
        LabeledContent(strings.labeled(strings.connStartup)) {
            VStack(alignment: .leading, spacing: 5) {
                Picker("", selection: Binding(
                    get: { prefs.pendingMode?.rawValue ?? "" },
                    set: { prefs.setMode(ConnectionPrefs.Mode(rawValue: $0)) })) {
                    ForEach(ConnectionPrefs.Mode.allCases, id: \.self) { mode in
                        Text(strings.connModeLabel(mode)).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.tabs)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("settings.connection.mode")

                Text(strings.connModeNote(prefs.pendingMode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // 限宽同 PresetPickerRow：不限的话这句注解的全长就成了控件列的
                    // 理想宽度，整页会被撑到版心之外。
                    .frame(maxWidth: 300, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var addressRow: some View {
        LabeledContent(strings.labeled(strings.connAddress)) {
            VStack(alignment: .leading, spacing: 3) {
                TextField("", text: Binding(
                    get: { prefs.draftURL },
                    set: { prefs.draftURL = $0 }),
                          prompt: Text(strings.connAddressPlaceholder))
                    .frame(width: 250)
                    .accessibilityIdentifier("settings.connection.fixedURL")
                if prefs.draftInvalid {
                    Text(strings.connAddressInvalid)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    /// 「立即重启」。**这一栏不当场切后端**——改的是"下次打开时"的行为，
    /// 而当前那条连接照常用着（状态行如实显示它连着谁）。
    private var restartRow: some View {
        LabeledContent {
            HStack(spacing: 9) {
                Button(strings.connRestartNow) { prefs.requestRelaunch() }
                    .accessibilityIdentifier("settings.connection.restart")
                Text(strings.connRestartHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } label: {
            // 零尺寸但**真实存在**的 label：`EmptyView()` 会让整行塌成全宽
            // （FormRule 那条踩坑记录同款）。
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private var currentRow: some View {
        LabeledContent(strings.labeled(strings.connCurrent)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(connected ? Color(nsColor: .systemGreen)
                                        : Color(nsColor: .tertiaryLabelColor))
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .accessibilityIdentifier("settings.connection.status")
                }
                Text(strings.connDiagnosticsHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var connected: Bool { prefs.phase == "connected" }

    /// **只说两件事**：连没连上、连着谁。重连轮次、失败分类、候选健康表那些
    /// 全归 ⌥⌘D——设置窗口不是诊断面板（下面那行 caption 就是指路牌）。
    private var statusText: String {
        guard connected else { return strings.connNotConnected }
        if prefs.managed { return strings.connConnectedManaged }
        return strings.connConnectedTo(prefs.connectedURL ?? "")
    }
}
