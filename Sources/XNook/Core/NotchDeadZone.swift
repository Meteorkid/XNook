import AppKit
import SwiftUI

/// 物理刘海在面板顶部导航中占据的死区。
///
/// 展开面板是居中悬浮在屏幕顶部的，而物理刘海也正好在屏幕顶部居中——
/// 面板的头部区域实际上被刘海切掉一块。此前只是让内容"避开"，但没有显式建模，
/// 于是导航按钮可能被推进刘海下面，既看不见也点不到。
///
/// 这里把死区显式算出来：刘海屏取 `safeAreaInsets` 对应的宽度，无刘海屏为 0。
/// 死区本身不接收点击（`allowsHitTesting(false)`），避免挡住下方内容。
struct NotchDeadZone: Equatable {
    /// 死区宽度
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

    /// 判断窗口是否真的位于刘海正下方。窗口不在屏幕顶部居中时，刘海不构成遮挡。
    static func resolve(for window: NSWindow?) -> NotchDeadZone {
        guard let window, let screen = window.screen else { return .none }
        let zone = resolve(for: screen)
        guard zone.isPresent else { return .none }
        let screenFrame = screen.frame
        let windowFrame = window.frame
        let topAligned = abs(windowFrame.maxY - screenFrame.maxY) < 6
        let horizontallyCentered = abs(windowFrame.midX - screenFrame.midX) < zone.width
        return topAligned && horizontallyCentered ? zone : .none
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
