import Foundation

enum PanelModuleID: String, Codable, CaseIterable, Identifiable {
    case media, calendar, notes, tray, currentTask, recentTasks

    var id: Self { self }

    var localizedName: String {
        switch self {
        case .media: return L10n.localized(zh: "媒体", en: "Media")
        case .calendar: return L10n.localized(zh: "日历", en: "Calendar")
        case .notes: return L10n.localized(zh: "笔记", en: "Notes")
        case .tray: return L10n.localized(zh: "文件托盘", en: "File Tray")
        case .currentTask: return L10n.localized(zh: "当前任务", en: "Current Task")
        case .recentTasks: return L10n.localized(zh: "最近任务", en: "Recent Tasks")
        }
    }

    var icon: String {
        switch self {
        case .media: return "music.note"
        case .calendar: return "calendar"
        case .notes: return "note.text"
        case .tray: return "tray"
        case .currentTask: return "timer"
        case .recentTasks: return "clock.arrow.circlepath"
        }
    }

    var minimumRows: Int {
        switch self {
        case .media, .calendar, .notes: return 4
        case .tray, .currentTask, .recentTasks: return 3
        }
    }
}

struct PanelModulePlacement: Codable, Equatable, Identifiable {
    var id: PanelModuleID
    var column: Int
    var row: Int
    var columns: Int
    var rows: Int
    var isVisible: Bool
}

struct PanelLayoutConfiguration: Codable, Equatable {
    static let currentVersion = 1
    static let columnCount = 12
    static let maximumRows = 64
    static let allowedColumns = [4, 6, 8, 12]
    static let allowedRows = [3, 4, 6, 8]
    static let defaultWidgetIDs: Set<String> = ["media", "calendar", "notes", "tray"]

    var version: Int = currentVersion
    var items: [PanelModulePlacement]
    /// 旧版已保存布局缺少此字段，仍按固定网格显示；模板显式启用内容适配。
    var fitsContent: Bool? = nil

    static var factoryDefault: Self {
        legacy(enabledWidgetIDs: defaultWidgetIDs,
               showHistory: SettingsDefaults.bool(for: "showNookFlowHistory", fallback: true))
    }

    static func legacy(enabledWidgetIDs: Set<String>, showHistory: Bool) -> Self {
        let primary: [PanelModuleID] = [.media, .calendar, .tray, .notes]
        let enabled = primary.filter { enabledWidgetIDs.contains($0.rawValue) }
        var placements = primary.map {
            PanelModulePlacement(id: $0, column: 0, row: 0, columns: 4,
                                 rows: 4, isVisible: enabled.contains($0))
        }

        if enabled.count == 4 {
            for (index, id) in primary.enumerated() {
                let itemIndex = placements.firstIndex { $0.id == id }!
                placements[itemIndex].column = (index % 2) * 6
                placements[itemIndex].columns = 6
                placements[itemIndex].row = (index / 2) * 4
            }
        } else if !enabled.isEmpty {
            let columns = columnCount / enabled.count
            for (index, id) in enabled.enumerated() {
                let itemIndex = placements.firstIndex { $0.id == id }!
                placements[itemIndex].column = index * columns
                placements[itemIndex].columns = columns
                placements[itemIndex].rows = 4
            }
        }

        let taskColumn = 0
        let taskColumns = 12
        let taskRow = enabled.count == 4 ? 8 : (enabled.isEmpty ? 0 : 4)
        placements.append(.init(id: .currentTask, column: taskColumn, row: taskRow,
                                columns: taskColumns, rows: 3, isVisible: true))
        placements.append(.init(id: .recentTasks, column: taskColumn, row: taskRow + 3,
                                columns: taskColumns, rows: 3, isVisible: showHistory))
        return Self(items: placements).normalized()
    }

    var visibleItems: [PanelModulePlacement] {
        items.filter(\.isVisible).sorted(by: Self.visualOrder)
    }

    /// 起始行错开的模块仍可能并排占位，需要一起计入自动宽度。
    var maximumModulesPerRow: Int {
        let visible = visibleItems
        return visible.map { item in
            visible.filter { $0.row <= item.row && item.row < $0.row + $0.rows }.count
        }.max() ?? 0
    }

    var signature: String {
        let components = items.sorted { $0.id.rawValue < $1.id.rawValue }.map {
            "\($0.id.rawValue):\($0.column),\($0.row),\($0.columns),\($0.rows),\($0.isVisible)"
        }
        return "\(version)|" + components.joined(separator: "|") + (fitsContent == true ? "|fitsContent=1" : "")
    }

    /// 持久化边界严格拒绝非法布局；编辑操作才会进行尺寸修正和避碰。
    func validate() throws {
        guard version == Self.currentVersion else {
            throw PanelLayoutError.unsupportedVersion(version)
        }
        guard items.count == PanelModuleID.allCases.count,
              Set(items.map(\.id)).count == PanelModuleID.allCases.count else {
            throw PanelLayoutError.invalidConfiguration
        }
        for item in items {
            guard Self.allowedColumns.contains(item.columns),
                  Self.allowedRows.contains(item.rows), item.rows >= item.id.minimumRows,
                  (0...(Self.columnCount - item.columns)).contains(item.column),
                  (0...(Self.maximumRows - item.rows)).contains(item.row) else {
                throw PanelLayoutError.invalidConfiguration
            }
        }
        let visible = visibleItems
        for index in visible.indices {
            for other in visible.dropFirst(index + 1) where Self.overlaps(visible[index], other) {
                throw PanelLayoutError.invalidConfiguration
            }
        }
    }

    mutating func move(_ id: PanelModuleID, column: Int, row: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].column = column
        items[index].row = row
        self = normalized(priority: id)
    }

    mutating func resize(_ id: PanelModuleID, columns: Int, rows: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].columns = columns
        items[index].rows = rows
        fitsContent = false
        self = normalized(priority: id)
    }

    mutating func setVisible(_ id: PanelModuleID, visible: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isVisible != visible else { return }
        let automatic = hiddenPrimaryItemsUseDefaultPlacements && visibleItems == Self.legacy(
            enabledWidgetIDs: Set(visibleItems.map { $0.id.rawValue }),
            showHistory: visibleItems.contains { $0.id == .recentTasks }).visibleItems
        items[index].isVisible = visible
        // 默认排列随组件开关收拢；已定制布局和隐藏模块的原尺寸仍原样保留。
        if automatic, id != .currentTask {
            let defaults = Self.legacy(enabledWidgetIDs: Set(items.filter(\.isVisible).map { $0.id.rawValue }),
                showHistory: items.contains { $0.id == .recentTasks && $0.isVisible })
            for replacement in defaults.visibleItems {
                if let replacementIndex = items.firstIndex(where: { $0.id == replacement.id }) {
                    items[replacementIndex] = replacement
                }
            }
            return
        }
        self = normalized(priority: visible ? id : nil)
        if !visible {
            for replacement in Self.packed(visibleItems) {
                if let itemIndex = items.firstIndex(where: { $0.id == replacement.id }) {
                    items[itemIndex] = replacement
                }
            }
        }
    }

    private var hiddenPrimaryItemsUseDefaultPlacements: Bool {
        let primary: [PanelModuleID] = [.media, .calendar, .tray, .notes]
        let hidden = items.filter { !$0.isVisible && primary.contains($0.id) }
        return hidden.allSatisfy { item in
            (0..<16).contains { mask in
                let enabled = Set(primary.enumerated().compactMap { index, id in
                    mask & (1 << index) == 0 ? nil : id.rawValue
                })
                return Self.legacy(enabledWidgetIDs: enabled, showHistory: true).items.contains {
                    $0.id == item.id && $0.column == item.column && $0.row == item.row
                        && $0.columns == item.columns && $0.rows == item.rows
                }
            }
        }
    }

    mutating func reorder(_ id: PanelModuleID, offset: Int) {
        var ordered = normalized().visibleItems
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return }
        let boundedOffset = min(max(offset, -ordered.count), ordered.count)
        let destination = min(max(index + boundedOffset, 0), ordered.count - 1)
        guard index != destination else { return }
        let item = ordered.remove(at: index)
        ordered.insert(item, at: destination)
        let packed = Self.packed(ordered)
        for replacement in packed {
            if let itemIndex = items.firstIndex(where: { $0.id == replacement.id }) {
                items[itemIndex] = replacement
            }
        }
        self = normalized()
    }

    func normalized(priority: PanelModuleID? = nil) -> Self {
        var unique: [PanelModulePlacement] = []
        for id in PanelModuleID.allCases {
            var item = items.first { $0.id == id }
                ?? .init(id: id, column: 0, row: 0, columns: 4,
                         rows: max(4, id.minimumRows), isVisible: false)
            item.columns = Self.allowedColumns.first { $0 >= item.columns } ?? 12
            item.rows = Self.allowedRows.first { $0 >= max(item.rows, id.minimumRows) } ?? 8
            item.column = min(max(item.column, 0), Self.columnCount - item.columns)
            item.row = min(max(item.row, 0), Self.maximumRows - item.rows)
            unique.append(item)
        }
        let ordered = unique.filter(\.isVisible).sorted {
            if $0.id == priority, $1.id != priority { return true }
            if $1.id == priority, $0.id != priority { return false }
            return Self.visualOrder($0, $1)
        }
        var placed: [PanelModulePlacement] = []
        for var item in ordered {
            if placed.contains(where: { Self.overlaps(item, $0) }) {
                guard let available = Self.firstAvailable(item, occupied: placed) else {
                    placed = Self.stacked(ordered, priority: priority)
                    break
                }
                item = available
            }
            placed.append(item)
        }
        for item in placed {
            let index = unique.firstIndex { $0.id == item.id }!
            unique[index] = item
        }
        return Self(version: version, items: unique, fitsContent: fitsContent)
    }

    /// 按视觉顺序投影时，后续模块不能回填到前一模块起点之前。
    static func packed(_ ordered: [PanelModulePlacement]) -> [PanelModulePlacement] {
        var result: [PanelModulePlacement] = []
        var start = 0
        for item in ordered {
            guard let placed = firstAvailable(item, occupied: result, startingAt: start) else {
                return stacked(ordered)
            }
            result.append(placed)
            start = placed.row * columnCount + placed.column + 1
        }
        return result
    }

    private static func firstAvailable(_ item: PanelModulePlacement,
                                       occupied: [PanelModulePlacement],
                                       startingAt: Int = 0) -> PanelModulePlacement? {
        for position in startingAt..<(maximumRows * columnCount) {
            var candidate = item
            candidate.column = position % columnCount
            candidate.row = position / columnCount
            guard candidate.column + candidate.columns <= columnCount,
                  candidate.row + candidate.rows <= maximumRows else { continue }
            if !occupied.contains(where: { overlaps(candidate, $0) }) { return candidate }
        }
        return nil
    }

    /// 分散占位可能没有足够长的连续空行；此时保留编辑目标，其余模块按整行排放。
    private static func stacked(_ ordered: [PanelModulePlacement],
                                priority: PanelModuleID? = nil) -> [PanelModulePlacement] {
        let fixed = ordered.first { $0.id == priority }
        var result = fixed.map { [$0] } ?? []
        for var item in ordered where item.id != priority {
            for row in 0...(maximumRows - item.rows) {
                let fits = !result.contains { row < $0.row + $0.rows && $0.row < row + item.rows }
                if fits {
                    item.row = row
                    result.append(item)
                    break
                }
            }
        }
        return result
    }

    private static func visualOrder(_ lhs: PanelModulePlacement, _ rhs: PanelModulePlacement) -> Bool {
        if lhs.row != rhs.row { return lhs.row < rhs.row }
        if lhs.column != rhs.column { return lhs.column < rhs.column }
        return lhs.id.rawValue < rhs.id.rawValue
    }

    private static func overlaps(_ lhs: PanelModulePlacement, _ rhs: PanelModulePlacement) -> Bool {
        lhs.column < rhs.column + rhs.columns && rhs.column < lhs.column + lhs.columns
            && lhs.row < rhs.row + rhs.rows && rhs.row < lhs.row + lhs.rows
    }
}

enum PanelLayoutError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case invalidConfiguration
    case unreadableStorage
    case recoveryRequired
    case changedSincePreview

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return L10n.localized(zh: "布局版本 \(version) 暂不受支持，原配置已保留。",
                                  en: "Layout version \(version) is unsupported. The saved layout is preserved.")
        case .invalidConfiguration:
            return L10n.localized(zh: "布局配置无效，原配置已保留。", en: "The layout is invalid. The saved layout is preserved.")
        case .unreadableStorage:
            return L10n.localized(zh: "无法读取布局配置，原配置已保留。", en: "The saved layout could not be read and is preserved.")
        case .recoveryRequired:
            return L10n.localized(zh: "请先显式恢复默认布局，再保存新配置。", en: "Explicitly restore the default layout before saving changes.")
        case .changedSincePreview:
            return L10n.localized(zh: "布局已在其他窗口中更改。请关闭并重新打开布局方案库，避免覆盖最新改动。",
                                  en: "The layout changed in another window. Close and reopen the layout library to preserve the latest changes.")
        }
    }
}
