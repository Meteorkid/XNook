import SwiftUI

/// 灵动岛尺寸计算器 - 与 X Island 保持一致
enum IslandSizeCalculator {

    // MARK: - 常量

    /// 展开面板头部高度
    static let expandedPanelHeaderHeight: CGFloat = 48

    /// 展开面板底部间距
    static let expandedPanelBottomInset: CGFloat = 16

    /// 收起状态的默认高度（胶囊高度）
    static let defaultCollapsedShapeHeight: CGFloat = 32

    /// 收起状态的默认宽度（胶囊宽度）
    static let defaultCollapsedPillWidth: CGFloat = 180

    /// 收起状态的宽度（胶囊宽度）- Notch 遮挡时
    static let collapsedPillWidthNotched: CGFloat = 276

    // MARK: - 用户配置读取

    /// 读取用户设置的收起高度
    static var collapsedShapeHeight: CGFloat {
        CGFloat(UserDefaults.standard.double(forKey: "islandHeight").clamped(defaultCollapsedShapeHeight))
    }

    /// 读取用户设置的收起宽度
    static var collapsedPillWidth: CGFloat {
        CGFloat(UserDefaults.standard.double(forKey: "islandWidth").clamped(defaultCollapsedPillWidth))
    }

    // MARK: - 胶囊宽度计算

    /// 动态计算胶囊宽度
    static func pillWidth(islandObscuredByNotch: Bool, visibleSessionCount: Int) -> CGFloat {
        // 始终使用用户设置的宽度
        return collapsedPillWidth
    }

    // MARK: - 展开状态

    /// 根据状态计算展开宽度
    static func expandedWidth(for state: IslandState, panelWidth: CGFloat) -> CGFloat {
        switch state {
        case .collapsed:
            return 0
        case .expanded:
            return panelWidth
        }
    }

    /// 根据状态和内容计算展开高度
    static func expandedHeight(
        for state: IslandState,
        visibleSessionCount: Int,
        panelMaxHeight: CGFloat
    ) -> CGFloat {
        switch state {
        case .collapsed:
            return collapsedShapeHeight
        case .expanded:
            return expandedPanelShapeHeight(
                visibleSessionCount: visibleSessionCount,
                panelMaxHeight: panelMaxHeight
            )
        }
    }

    /// 计算展开面板的实际高度
    static func expandedPanelShapeHeight(
        visibleSessionCount: Int,
        panelMaxHeight: CGFloat
    ) -> CGFloat {
        // 头部高度 + 会话列表高度 + 底部间距
        let sessionListHeight = CGFloat(visibleSessionCount) * 80 + 30
        let calculatedHeight = expandedPanelHeaderHeight + sessionListHeight + expandedPanelBottomInset
        return min(calculatedHeight, panelMaxHeight)
    }

    /// 根据状态计算目标尺寸
    static func targetSize(
        for state: IslandState,
        visibleSessionCount: Int,
        panelWidth: CGFloat,
        panelMaxHeight: CGFloat
    ) -> (width: CGFloat, height: CGFloat) {
        let width = expandedWidth(for: state, panelWidth: panelWidth)
        let height = expandedHeight(
            for: state,
            visibleSessionCount: visibleSessionCount,
            panelMaxHeight: panelMaxHeight
        )
        return (width, height)
    }

    // MARK: - 圆角计算

    /// 顶部圆角半径
    static func topCornerRadius(for state: IslandState) -> CGFloat {
        NotchShapeGeometry.topCornerRadius(state: state)
    }

    /// 底部圆角半径
    static func bottomCornerRadius(openProgress: CGFloat) -> CGFloat {
        NotchShapeGeometry.bottomCornerRadius(openProgress: openProgress)
    }

    /// 计算展开进度（0 = 收起，1 = 完全展开）
    static func openProgress(
        shapeHeight: CGFloat,
        cachedExpandedShapeHeight: CGFloat
    ) -> CGFloat {
        NotchShapeGeometry.openProgress(
            shapeHeight: shapeHeight,
            cachedExpandedShapeHeight: cachedExpandedShapeHeight
        )
    }
}

// MARK: - Double 扩展

private extension Double {
    /// 如果值为 0（未设置），返回默认值；否则返回原值
    func clamped(_ defaultValue: Double) -> Double {
        self == 0 ? defaultValue : self
    }
}
