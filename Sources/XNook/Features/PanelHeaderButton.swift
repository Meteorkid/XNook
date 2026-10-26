import SwiftUI

/// 头部按钮保持固定的 26pt 命中区，只使用共享的小幅缩放反馈。
struct PanelHeaderButton: View {
    let icon: String
    let title: String
    let reduceMotion: Bool
    let action: () -> Void

    var body: some View {
        ScaleOnlyButton(reduceMotion: reduceMotion, action: action) {
            Image(systemName: icon)
                .font(.system(size: IslandTokens.Font.body, weight: .medium))
                .frame(width: 26, height: 26)
        }
        .frame(width: 26, height: 26)
        .help(title)
        .accessibilityLabel(title)
    }
}
