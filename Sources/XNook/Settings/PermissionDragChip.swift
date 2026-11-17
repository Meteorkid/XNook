import SwiftUI

/// 浮动在系统设置旁边的小拖拽板：只有一个图标、一句提示。
struct PermissionDragChip: View {
    /// 目标分页名（「屏幕录制」「语音识别」…），让用户知道该往哪个列表里拖。
    let target: String
    let onDragEnded: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.localized(zh: "关闭", en: "Close"))
            }
            .padding(.top, 8)
            .padding(.trailing, 8)

            DraggableAppIcon(side: 56, onDragEnded: onDragEnded)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary.opacity(0.5))
                )

            Text(L10n.localized(zh: "拖到右侧「\(target)」列表", en: "Drag into \(target)"))
                .font(.system(size: 10, weight: .medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("X Nook")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 8)
        .frame(width: 132)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
        )
    }
}
