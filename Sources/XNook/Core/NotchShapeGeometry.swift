import SwiftUI

/// Notch 形状几何计算 - 与 X Island 保持一致
enum NotchShapeGeometry {

    /// 收起状态底部圆角
    static let collapsedBottomCornerRadius: CGFloat = 17

    /// 展开状态圆角
    static let expandedCornerRadius: CGFloat = 22

    /// 顶部圆角（始终为 0，匹配物理 Notch）
    static func topCornerRadius(state: IslandState) -> CGFloat {
        0
    }

    /// 底部圆角（根据展开进度从 17 渐变到 22）
    static func bottomCornerRadius(openProgress: CGFloat) -> CGFloat {
        collapsedBottomCornerRadius + (expandedCornerRadius - collapsedBottomCornerRadius) * openProgress
    }

    /// 计算展开进度（0 = 收起，1 = 完全展开）
    /// 只有当 shapeHeight 超过收起高度一定阈值时才开始计算，避免收起状态下高度变化影响圆角
    static func openProgress(
        shapeHeight: CGFloat,
        cachedExpandedShapeHeight: CGFloat
    ) -> CGFloat {
        let collapsedHeight = IslandSizeCalculator.collapsedShapeHeight
        // 收起状态下始终返回 0，圆角固定为 collapsedBottomCornerRadius
        guard shapeHeight > collapsedHeight + 1,
              cachedExpandedShapeHeight > collapsedHeight else { return 0 }
        let progress = (shapeHeight - collapsedHeight) /
            (cachedExpandedShapeHeight - collapsedHeight)
        return min(max(progress, 0), 1)
    }
}
