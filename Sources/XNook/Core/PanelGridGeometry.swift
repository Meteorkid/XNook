import CoreGraphics
import Foundation

struct PanelGridGeometry {
    static let spacing: CGFloat = 8
    static let rowHeight: CGFloat = 40

    static func frames(for configuration: PanelLayoutConfiguration, width: CGFloat) -> [PanelModuleID: CGRect] {
        guard width.isFinite, width > 0 else { return [:] }
        var visible = configuration.normalized().visibleItems
        if width < 752 {
            for index in visible.indices {
                visible[index].columns = width <= 504 ? 12 : max(6, visible[index].columns)
            }
            visible = PanelLayoutConfiguration.packed(visible)
        }
        let cell = max(0, (width - spacing * 11) / 12)
        return Dictionary(uniqueKeysWithValues: visible.map { item in
            let x = CGFloat(item.column) * (cell + spacing)
            let y = CGFloat(item.row) * (rowHeight + spacing)
            let frameWidth = CGFloat(item.columns) * cell + CGFloat(item.columns - 1) * spacing
            let frameHeight = CGFloat(item.rows) * rowHeight + CGFloat(item.rows - 1) * spacing
            let frame = CGRect(x: x, y: y, width: min(width, frameWidth), height: frameHeight)
            return (item.id, frame)
        })
    }

    static func height(for configuration: PanelLayoutConfiguration, width: CGFloat) -> CGFloat {
        frames(for: configuration, width: width).values.map(\.maxY).max() ?? 0
    }
}
