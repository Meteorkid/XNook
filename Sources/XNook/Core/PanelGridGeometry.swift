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

    /// 自动展示高度不属于用户保存的网格；模式切换后不再接受另一模式的旧测量。
    static func measurementSignature(for configuration: PanelLayoutConfiguration, fitsContent: Bool) -> String {
        configuration.signature + (fitsContent ? "|contentFit=1" : "")
    }

    /// 默认网格按原行带收拢；只投影 CGRect，不改变任何保存的列、行或组件顺序。
    static func contentFittedFrames(
        for configuration: PanelLayoutConfiguration,
        width: CGFloat,
        measuredHeights: [PanelModuleID: CGFloat]
    ) -> [PanelModuleID: CGRect] {
        let fallback = frames(for: configuration, width: width)
        let base = frames(for: configuration, width: width, isEditing: true)
        let bands = Dictionary(grouping: base, by: { $0.value.minY }).sorted { $0.key < $1.key }
        var previousBottom: CGFloat = 0
        for band in bands {
            // 跨行的定制形状没有单一行高；不对这种布局进行内容投影。
            guard band.key >= previousBottom else { return fallback }
            previousBottom = band.value.map { $0.value.maxY }.max() ?? band.key
        }

        var result: [PanelModuleID: CGRect] = [:]
        var y: CGFloat = 0
        for band in bands {
            let height = band.value.map { id, frame -> CGFloat in
                guard let measured = measuredHeights[id], measured.isFinite, measured > 0 else {
                    return fallback[id]?.height ?? frame.height
                }
                return max(44, ceil(measured))
            }.max() ?? 44
            guard height.isFinite, (y + height + spacing).isFinite else { return fallback }
            for (id, frame) in band.value {
                result[id] = CGRect(x: frame.minX, y: y, width: frame.width, height: height)
            }
            y += height + spacing
        }
        return result
    }

    static func height(for configuration: PanelLayoutConfiguration, width: CGFloat, isEditing: Bool = false) -> CGFloat {
        frames(for: configuration, width: width, isEditing: isEditing).values.map(\.maxY).max() ?? 0
    }
}
