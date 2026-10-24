import CoreGraphics
import Foundation

struct PanelGridGeometry {
    static let spacing: CGFloat = 8
    static let rowHeight: CGFloat = 40

    static func frames(for configuration: PanelLayoutConfiguration, width: CGFloat, isEditing: Bool = false) -> [PanelModuleID: CGRect] {
        guard width.isFinite, width > 0 else { return [:] }
        var visible = configuration.normalized().visibleItems
        if width < 752 {
            for index in visible.indices {
                visible[index].columns = width <= 504 ? 12 : max(6, visible[index].columns)
            }
            visible = PanelLayoutConfiguration.packed(visible)
        }
        let cell = max(0, (width - spacing * 11) / 12)
        var needsPacking = false
        for index in visible.indices where !isEditing && visible[index].id == .media {
            let cardWidth = CGFloat(visible[index].columns) * cell + CGFloat(visible[index].columns - 1) * spacing
            let contentWidth = cardWidth - ExpandedPanelLayout.cardPadding * 2
            let minimumRows = contentWidth < 111 ? 8 : (contentWidth < 223 ? 6 : 4)
            if visible[index].rows < minimumRows {
                visible[index].rows = minimumRows
                needsPacking = true
            }
        }
        // 正文为100pt封面只读增高；编辑占位卡保留原行数，使拖动坐标与保存坐标一致。
        if needsPacking { visible = PanelLayoutConfiguration.packed(visible) }
        return Dictionary(uniqueKeysWithValues: visible.map { item in
            let x = CGFloat(item.column) * (cell + spacing)
            let y = CGFloat(item.row) * (rowHeight + spacing)
            let frameWidth = CGFloat(item.columns) * cell + CGFloat(item.columns - 1) * spacing
            let frameHeight = CGFloat(item.rows) * rowHeight + CGFloat(item.rows - 1) * spacing
            let frame = CGRect(x: x, y: y, width: min(width, frameWidth), height: frameHeight)
            return (item.id, frame)
        })
    }

    static func height(for configuration: PanelLayoutConfiguration, width: CGFloat, isEditing: Bool = false) -> CGFloat {
        frames(for: configuration, width: width, isEditing: isEditing).values.map(\.maxY).max() ?? 0
    }
}
