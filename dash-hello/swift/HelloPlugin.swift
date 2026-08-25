import DashSDK
import SwiftUI

/// 插件 dylib 的唯一导出符号。`@_cdecl` 保证名字不被修饰，
/// 壳按 image handle `dlsym` 取它（每个插件都叫这个名字，见 docs/native-abi.md §1）。
@_cdecl("dash_plugin_entry")
public func dash_plugin_entry() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(HelloPlugin()).toOpaque()
}

final class HelloPlugin: DashPlugin {
    func activate(host: DashHost) -> AnyObject? {
        let handle = DashPluginHandle()
        let model = HelloModel()

        host.bridge.onMessage { channel, payload in
            guard channel == "tick" else { return }
            model.lastTick = payload["at"] as? String ?? "?"
        }.kept(by: handle)

        host.register(slot: "root") {
            AnyView(HelloView(model: model, host: host))
        }.kept(by: handle)

        host.log("hello 上线")
        // 上行 invoke 通路的冒烟：装载即给 TS 半身报一次到（dsh 终端能看见）。
        host.bridge.send(action: "ping", payload: ["generation": host.generation])
        return handle
    }
}

@Observable
final class HelloModel {
    var clicks = 0
    var lastTick = "（等待 TS 半身推送…）"
}

struct HelloView: View {
    @Bindable var model: HelloModel
    let host: DashHost

    var body: some View {
        VStack(spacing: 16) {
            Text("HOT RELOAD ✅")
                .font(.system(size: 32, weight: .bold, design: .rounded))
            Text("第 \(host.generation) 代 · 改 swift/HelloPlugin.swift 试试")
                .foregroundStyle(.secondary)
            Button("点了 \(model.clicks) 次") { model.clicks += 1 }
                .buttonStyle(.borderedProminent)
            Button("给 TS 半身发一个 ping") {
                host.bridge.send(action: "ping", payload: ["clicks": model.clicks])
            }
            Text(model.lastTick)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.90, green: 0.45, blue: 0.10))
    }
}
