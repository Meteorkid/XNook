import SwiftUI

/// 悬停区域固定在外层，内部图标只做位移和缩放，避免重绘遮罩造成闪烁。
struct PanelHeaderButton: View {
    let icon: String
    let title: String
    let reduceMotion: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: IslandTokens.Font.body, weight: .medium))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(PanelHeaderButtonStyle(isHovering: isHovering, reduceMotion: reduceMotion))
        .frame(width: 26, height: 26)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onDisappear { isHovering = false }
        .help(title)
        .accessibilityLabel(title)
    }
}

struct PanelHeaderButtonStyle: ButtonStyle {
    let isHovering: Bool
    let reduceMotion: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let hovered = isHovering && isEnabled
        let pressed = configuration.isPressed && isEnabled
        let animates = !reduceMotion && isEnabled
        configuration.label
            .scaleEffect(animates ? (pressed ? 0.94 : hovered ? 1.08 : 1) : 1)
            .offset(y: animates && hovered && !pressed ? -1 : 0)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(animates ? .easeOut(duration: 0.14) : nil, value: hovered)
            .animation(animates ? .easeOut(duration: 0.10) : nil, value: pressed)
    }
}
