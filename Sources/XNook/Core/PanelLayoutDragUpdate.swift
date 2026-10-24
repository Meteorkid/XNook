import Foundation
import CoreGraphics

/// 同一套拖动计算用于真实手势与回归，窄视口只改变顺序，不把投影尺寸写回。
enum PanelLayoutDragUpdate {
    static func configuration(from original: PanelLayoutConfiguration, id: PanelModuleID,
                              translation: CGSize, resizing: Bool, width: CGFloat) -> PanelLayoutConfiguration {
        guard width.isFinite, width > 0, translation.width.isFinite, translation.height.isFinite,
              let item = original.items.first(where: { $0.id == id }), item.isVisible else { return original }
        var next = original
        let pitch = max(1, (width + PanelGridGeometry.spacing) / 12)
        let columnDelta = Int(max(-12, min(12, translation.width / pitch)).rounded())
        let rowDelta = Int(max(-64, min(64, translation.height / (PanelGridGeometry.rowHeight + PanelGridGeometry.spacing))).rounded())
        if resizing {
            next.resize(id, columns: width < 752 ? item.columns : item.columns + columnDelta, rows: item.rows + rowDelta)
        } else if width < 752 {
            let frames = PanelGridGeometry.frames(for: original, width: width, isEditing: true)
            let order = original.visibleItems.map(\.id)
            guard let frame = frames[id], let from = order.firstIndex(of: id) else { return original }
            let target = CGPoint(x: frame.midX + translation.width, y: frame.midY + translation.height)
            func distance(_ key: PanelModuleID) -> CGFloat {
                guard let rect = frames[key] else { return .greatestFiniteMagnitude }
                return hypot(rect.midX - target.x, rect.midY - target.y)
            }
            if let nearest = order.min(by: { distance($0) < distance($1) }), let to = order.firstIndex(of: nearest) {
                next.reorder(id, offset: to - from)
            }
        } else {
            next.move(id, column: item.column + columnDelta, row: item.row + rowDelta)
        }
        return next
    }
}
