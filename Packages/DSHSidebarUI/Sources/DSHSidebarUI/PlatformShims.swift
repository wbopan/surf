import SwiftUI

// 平台分支集中地：DSHSidebarUI 只允许 import SwiftUI（+DSHKit），
// 禁止 AppKit/UIKit。确需平台差异时写在这里。

/// macOS 有 hover，iOS 没有；用统一 modifier 包一层。
struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    let selected: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering && !selected
                          ? Color.primary.opacity(0.08)
                          : Color.clear)
            )
            .onHover { hovering = $0 }
        #else
        content
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
        #endif
    }
}

extension View {
    func hoverHighlight(selected: Bool) -> some View {
        modifier(HoverHighlight(selected: selected))
    }
}
