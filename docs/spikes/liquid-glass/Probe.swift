// Liquid Glass 对照台：同一个 SDK 下，把「自动获得玻璃的」和「不会获得玻璃的」
// 并排编出来看一眼。跑法见 README.md。
import SwiftUI
import AppKit

enum Pick: String, CaseIterable, Identifiable {
    case light = "浅色", dark = "深色", auto = "跟随系统"
    var id: String { rawValue }
}

struct ContentView: View {
    @State private var inForm: Pick = .auto
    @State private var inBar: Pick = .auto
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("① Form 里的 Picker：.segmented vs .tabs（macOS 27 新增）") {
                Form {
                    LabeledContent(".segmented：") {
                        Picker("", selection: $inForm) {
                            ForEach(Pick.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    LabeledContent(".tabs：") {
                        Picker("", selection: $inForm) {
                            ForEach(Pick.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.tabs).labelsHidden().fixedSize()
                    }
                    LabeledContent(".segmented + 玻璃：") {
                        Picker("", selection: $inForm) {
                            ForEach(Pick.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .glassEffect()
                    }
                }
                .formStyle(.columns)
            }

            group("② 三种 Button 样式") {
                HStack(spacing: 10) {
                    Button("默认 .bordered") {}
                    Button("glass") {}.buttonStyle(.glass)
                    Button("glassProminent") {}.buttonStyle(.glassProminent)
                }
            }

            group("③ .glassEffect() 手动上玻璃") {
                HStack(spacing: 10) {
                    Text("regular").padding(8).glassEffect()
                    Text("在彩色底上").padding(8).glassEffect()
                        .background(LinearGradient(colors: [.orange, .purple],
                                                   startPoint: .leading, endPoint: .trailing)
                            .frame(width: 220, height: 40).offset(x: -20))
                }
            }

            group("④ TabView（导航层，自动获得新外观）") {
                TabView(selection: $tab) {
                    Text("第一栏").frame(maxWidth: .infinity, maxHeight: .infinity)
                        .tabItem { Text("插件配置") }.tag(0)
                    Text("第二栏").frame(maxWidth: .infinity, maxHeight: .infinity)
                        .tabItem { Text("插件列表") }.tag(1)
                }
                .frame(height: 90)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 560, height: 600, alignment: .topLeading)
        // ⑤ 工具栏里的同一个分段控件——对照组的关键：同样的控件，换个层就换个材质。
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $inBar) {
                    ForEach(Pick.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
        }
    }

    @ViewBuilder
    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

@main
struct GlassProbe: App {
    var body: some Scene {
        Window("Glass Probe", id: "main") { ContentView() }
            .windowResizability(.contentSize)
    }
}
