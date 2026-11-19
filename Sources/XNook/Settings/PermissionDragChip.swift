import AppKit
import SwiftUI

/// 浮动在系统设置旁的拖拽板。
///
/// 取这个版式的原因：用户已经知道「授权 = 把应用拖进列表」这件事，
/// 缺的只是「拖什么」和「往哪拖」。所以一行说明 + 一行可拖的整块，
/// 箭头指向列表所在的方向，拖拽目标从 56×56 的图标放大成整行。
struct PermissionDragChip: View {

    /// 列表相对本面板的方向。面板可能在系统设置的左侧、右侧或下方。
    enum ArrowDirection {
        case right, left, up

        var symbol: String {
            switch self {
            case .right: "arrow.right"
            case .left: "arrow.left"
            case .up: "arrow.up"
            }
        }

        var phrase: String {
            switch self {
            case .right: L10n.localized(zh: "右侧", en: "on the right")
            case .left: L10n.localized(zh: "左侧", en: "on the left")
            case .up: L10n.localized(zh: "上方", en: "above")
            }
        }
    }

    /// 目标分页名（「屏幕录制」「语音识别」…），让用户知道该往哪个列表里拖。
    let target: String
    let direction: ArrowDirection
    let onDragEnded: () -> Void
    let onClose: () -> Void

    private var appName: String {
        let url = Bundle.main.bundleURL
        if url.pathExtension == "app" { return url.lastPathComponent }
        // 测试宿主里 `Bundle.main` 是 xctest 进程，拿不到 .app 名字时退回可读的应用名。
        let base = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "X Nook"
        return "\(base).app"
    }

    private var appIcon: NSImage {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app"
            ? NSWorkspace.shared.icon(forFile: url.path)
            : NSApp.applicationIconImage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                arrow
                instruction
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.localized(zh: "关闭", en: "Close"))
            }

            dragRow
        }
        .padding(14)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        )
    }

    private var arrow: some View {
        Image(systemName: direction.symbol)
            .font(.system(size: 25, weight: .heavy))
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.36, green: 0.57, blue: 1.0),
                        Color(red: 0.16, green: 0.35, blue: 0.92)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)
    }

    /// 说明句：应用名加粗，服务名加引号。拼接用 `Text` 相加，换行时才不会断在奇怪的位置。
    private var instruction: Text {
        let prefix = L10n.localized(zh: "将 ", en: "Drag ")
        let middle = L10n.localized(zh: " 拖到", en: " ")
        let suffix = L10n.localized(
            zh: "\(direction.phrase)列表以允许\(unbreakable("「\(target)」"))",
            en: "\(direction.phrase) to allow “\(target)”"
        )
        return Text(prefix)
            + Text(appName).fontWeight(.semibold)
            + Text(middle + suffix)
    }

    /// 中文词不能被断行拆开：早先「屏幕录制」被排成「屏」/「幕录制」，
    /// 读起来像错字。用 U+2060（word joiner）把字粘住，宽度不够时整词换行。
    private func unbreakable(_ text: String) -> String {
        guard text.count > 1, text.count <= 12,
              text.allSatisfy({ !$0.isWhitespace && !$0.isASCII }) else { return text }
        let joiner = "\u{2060}"
        return text.map(String.init).joined(separator: joiner)
    }

    /// 整行都是拖拽源：比只拖图标好按，视觉上也更明确「这一块可以拿走」。
    private var dragRow: some View {
        HStack(spacing: 9) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 26, height: 26)
            Text(appName)
                .font(.system(size: 13, weight: .semibold))
            Text(L10n.localized(zh: "（点我拖动）", en: "(drag me)"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
        // 透明句柄铺满整行，负责真正的拖拽；SwiftUI 只负责长相。
        .overlay(AppDragHandle(onDragEnded: onDragEnded))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
