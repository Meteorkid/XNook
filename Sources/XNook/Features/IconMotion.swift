import SwiftUI

/// 图标按钮共用固定命中区；动画只缩放内部标签，不改变布局或透明度。
struct ScaleOnlyButton<Label: View>: View {
    let reduceMotion: Bool
    var hitPadding: CGFloat = 0
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isHovering = false

    var body: some View {
        Button(action: action, label: label)
            .buttonStyle(ScaleOnlyButtonStyle(isHovering: isHovering, reduceMotion: reduceMotion))
            .contentShape(Rectangle().inset(by: -hitPadding))
            .onHover { isHovering = $0 }
            .onDisappear { isHovering = false }
    }
}

struct ScaleOnlyButtonStyle: ButtonStyle {
    let isHovering: Bool
    let reduceMotion: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let hovered = isHovering && isEnabled
        let pressed = configuration.isPressed && isEnabled
        let animates = !reduceMotion && isEnabled
        configuration.label
            .scaleEffect(animates ? (pressed ? 0.96 : hovered ? 1.06 : 1) : 1)
            .animation(animates ? .easeOut(duration: 0.12) : nil, value: hovered)
            .animation(animates ? .easeOut(duration: 0.12) : nil, value: pressed)
            // 禁用态静态变暗，不进入上面的动画范围。
            .opacity(isEnabled ? 1 : 0.4)
    }
}
