import AppKit

/// 检测 Notch 区域和屏幕信息
struct NotchDetector {
    /// 获取当前屏幕的 Notch 高度
    static func notchHeight(for screen: NSScreen) -> CGFloat {
        if #available(macOS 14.0, *) {
            return screen.safeAreaInsets.top
        }
        return 0
    }

    /// 检查屏幕是否有物理 Notch
    static func hasPhysicalNotch(_ screen: NSScreen) -> Bool {
        notchHeight(for: screen) > 0
    }

    /// 获取 Notch 区域的矩形
    static func notchRect(for screen: NSScreen) -> NSRect {
        let notchHeight = notchHeight(for: screen)
        let screenFrame = screen.frame

        return NSRect(
            x: screenFrame.midX - 80,  // 大约中间 160pt 宽
            y: screenFrame.maxY - notchHeight,
            width: 160,
            height: notchHeight
        )
    }

    /// 检查给定点是否在 Notch 区域内
    static func isPointInNotch(_ point: NSPoint, on screen: NSScreen) -> Bool {
        let notchRect = notchRect(for: screen)
        return notchRect.contains(point)
    }

    /// 获取安全区域（Notch 下方可用区域）
    static func safeArea(for screen: NSScreen) -> NSEdgeInsets {
        if #available(macOS 14.0, *) {
            return screen.safeAreaInsets
        }
        return NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    /// 获取所有显示器信息
    static func allScreensInfo() -> [(screen: NSScreen, hasNotch: Bool, notchHeight: CGFloat)] {
        NSScreen.screens.map { screen in
            let hasNotch = hasPhysicalNotch(screen)
            let height = notchHeight(for: screen)
            return (screen: screen, hasNotch: hasNotch, notchHeight: height)
        }
    }
}
