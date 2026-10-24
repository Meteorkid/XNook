import AppKit
import SwiftUI

/// 物理刘海在面板顶部导航中需要预留的居中避让区域。
///
/// 屏幕推导物理刘海大小；窗口横向移动后，扩大居中避让区域以完整包含遮挡。
/// 无刘海屏幕或窗口与刘海不相交时不预留空间。
/// 死区本身不接收点击（`allowsHitTesting(false)`），避免挡住下方内容。
struct NotchDeadZone: Equatable {
    /// 居中避让宽度；窗口偏移时可能大于物理刘海宽度。
    let width: CGFloat
    /// 死区高度（刘海高度）
    let height: CGFloat

    static let none = NotchDeadZone(width: 0, height: 0)

    var isPresent: Bool { width > 0 }

    /// 物理刘海的实际宽度约等于其高度乘以此系数（刘海是圆角矩形，横向比纵向宽）。
    static let widthPerHeight: CGFloat = 6.25

    /// 根据屏幕推导死区。无刘海屏幕返回 `.none`。
    static func resolve(for screen: NSScreen?) -> NotchDeadZone {
        guard let screen, let insets = safeAreaInsets(of: screen), insets.top > 0 else {
            return .none
        }
        return NotchDeadZone(
            width: insets.top * widthPerHeight,
            height: insets.top
        )
    }

    /// 为与物理刘海相交的窗口计算居中避让区域。
    static func resolve(for window: NSWindow?) -> NotchDeadZone {
        guard let window, let screen = window.screen else { return .none }
        let zone = resolve(for: screen)
        return resolve(screenFrame: screen.frame, windowFrame: window.frame, screenZone: zone)
    }

    /// 纯几何入口；对称扩张使现有头部布局无需了解窗口的横向偏移。
    static func resolve(screenFrame: CGRect, windowFrame: CGRect, screenZone zone: NotchDeadZone) -> NotchDeadZone {
        guard zone.isPresent, zone.height > 0 else { return .none }
        let notchFrame = CGRect(
            x: screenFrame.midX - zone.width / 2,
            y: screenFrame.maxY - zone.height,
            width: zone.width,
            height: zone.height
        )
        guard notchFrame.intersects(windowFrame) else { return .none }
        let horizontalOffset = abs(screenFrame.midX - windowFrame.midX)
        return NotchDeadZone(width: zone.width + horizontalOffset * 2, height: zone.height)
    }

    private static func safeAreaInsets(of screen: NSScreen) -> NSEdgeInsets? {
        if #available(macOS 14.0, *) {
            return screen.safeAreaInsets
        }
        return nil
    }
}

/// 顶部导航栏中间为物理刘海预留的空档。
///
/// 死区两侧的内容会自动被推开；死区自身不接收点击，点击穿透到下方。
struct NotchDeadZoneSpacer: View {
    let zone: NotchDeadZone

    var body: some View {
        if zone.isPresent {
            Color.clear
                .frame(width: zone.width, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
