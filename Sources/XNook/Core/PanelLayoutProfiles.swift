import Foundation
import Observation

enum PanelLayoutTemplate: String, CaseIterable, Identifiable {
    case standard, focus, media

    var id: Self { self }

    var localizedName: String {
        switch self {
        case .standard: return L10n.localized(zh: "标准三组件", en: "Standard Trio")
        case .focus: return L10n.localized(zh: "专注任务", en: "Task Focus")
        case .media: return L10n.localized(zh: "轻量媒体", en: "Lightweight Media")
        }
    }

    var summary: String {
        switch self {
        case .standard:
            return L10n.localized(zh: "媒体、日历与文件托盘并排，任务放在下方。",
                                  en: "Media, calendar, and file tray side by side, with tasks below.")
        case .focus:
            return L10n.localized(zh: "当前任务与笔记并排，最近任务放在下方。",
                                  en: "Current task and notes side by side, with recent tasks below.")
        case .media:
            return L10n.localized(zh: "全宽媒体组件，集中查看播放内容。",
                                  en: "A full-width media widget for your playback.")
        }
    }

    var configuration: PanelLayoutConfiguration {
        var items = PanelModuleID.allCases.map {
            PanelModulePlacement(id: $0, column: 0, row: 0, columns: 4, rows: 4, isVisible: false)
        }
        let visible: [PanelModulePlacement]
        switch self {
        case .standard:
            visible = [
                .init(id: .media, column: 0, row: 0, columns: 4, rows: 4, isVisible: true),
                .init(id: .calendar, column: 4, row: 0, columns: 4, rows: 4, isVisible: true),
                .init(id: .tray, column: 8, row: 0, columns: 4, rows: 4, isVisible: true),
                .init(id: .currentTask, column: 0, row: 4, columns: 12, rows: 3, isVisible: true),
                .init(id: .recentTasks, column: 0, row: 7, columns: 12, rows: 3, isVisible: true),
            ]
        case .focus:
            visible = [
                .init(id: .currentTask, column: 0, row: 0, columns: 6, rows: 4, isVisible: true),
                .init(id: .notes, column: 6, row: 0, columns: 6, rows: 4, isVisible: true),
                .init(id: .recentTasks, column: 0, row: 4, columns: 12, rows: 3, isVisible: true),
            ]
        case .media:
            visible = [.init(id: .media, column: 0, row: 0, columns: 12, rows: 4, isVisible: true)]
        }
        for placement in visible {
            if let index = items.firstIndex(where: { $0.id == placement.id }) {
                items[index] = placement
            }
        }
        return PanelLayoutConfiguration(items: items, fitsContent: true)
    }
}

struct SavedPanelLayout: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var configuration: PanelLayoutConfiguration
}

@Observable @MainActor
final class PanelLayoutProfileStore {
    static let storageKey = "panelLayoutProfiles.v1"
    static let currentVersion = 1
    static let maximumProfiles = 50
    static let maximumNameLength = 40
    static let maximumStoredBytes = 512 * 1_024

    private let defaults: UserDefaults
    private(set) var profiles: [SavedPanelLayout] = []
    private(set) var loadError: String?

    var canEdit: Bool { loadError == nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    func reload() {
        guard let stored = defaults.object(forKey: Self.storageKey) else {
            profiles = []
            loadError = nil
            return
        }
        do {
            guard let data = stored as? Data else { throw PanelLayoutProfileError.unreadableStorage }
            guard data.count <= Self.maximumStoredBytes else { throw PanelLayoutProfileError.storageTooLarge }
            let header = try JSONDecoder().decode(VersionHeader.self, from: data)
            guard header.version == Self.currentVersion else {
                throw PanelLayoutProfileError.unsupportedVersion(header.version)
            }
            let library = try JSONDecoder().decode(Library.self, from: data)
            try Self.validate(library.profiles)
            profiles = library.profiles
            loadError = nil
        } catch {
            loadError = (error as? PanelLayoutProfileError ?? .unreadableStorage).localizedDescription
        }
    }

    @discardableResult
    func saveNew(configuration: PanelLayoutConfiguration, name: String? = nil) throws -> SavedPanelLayout {
        try prepareToWrite()
        guard profiles.count < Self.maximumProfiles else { throw PanelLayoutProfileError.tooManyProfiles }
        let name = try validatedName(name ?? nextDefaultName())
        try configuration.validate()
        let profile = SavedPanelLayout(id: UUID(), name: name, configuration: configuration)
        try persist(profiles + [profile])
        return profile
    }

    func rename(id: UUID, name: String) throws {
        try prepareToWrite()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw PanelLayoutProfileError.notFound
        }
        let name = try validatedName(name, excluding: id)
        guard profiles[index].name != name else { return }
        var updated = profiles
        updated[index].name = name
        try persist(updated)
    }

    func update(id: UUID, configuration: PanelLayoutConfiguration) throws {
        try prepareToWrite()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw PanelLayoutProfileError.notFound
        }
        try configuration.validate()
        guard profiles[index].configuration != configuration else { return }
        var updated = profiles
        updated[index].configuration = configuration
        try persist(updated)
    }

    func delete(id: UUID) throws {
        try prepareToWrite()
        guard profiles.contains(where: { $0.id == id }) else { throw PanelLayoutProfileError.notFound }
        try persist(profiles.filter { $0.id != id })
    }

    private func prepareToWrite() throws {
        // 多个窗口各持有一个 store 时，先合入其他窗口最近保存的方案。
        reload()
        guard canEdit else { throw PanelLayoutProfileError.unavailable }
    }

    private func validatedName(_ name: String, excluding id: UUID? = nil) throws -> String {
        let trimmed = try Self.trimmedName(name)
        guard !profiles.contains(where: { $0.id != id && Self.nameKey($0.name) == Self.nameKey(trimmed) }) else {
            throw PanelLayoutProfileError.duplicateName
        }
        return trimmed
    }

    private func nextDefaultName() -> String {
        let names = Set(profiles.map { Self.nameKey($0.name) })
        var number = 1
        while names.contains(Self.nameKey("自定义布局 \(number)"))
            || names.contains(Self.nameKey("Custom Layout \(number)")) {
            number += 1
        }
        return L10n.localized(zh: "自定义布局 \(number)", en: "Custom Layout \(number)")
    }

    private func persist(_ profiles: [SavedPanelLayout]) throws {
        try Self.validate(profiles)
        let data = try JSONEncoder().encode(Library(version: Self.currentVersion, profiles: profiles))
        guard data.count <= Self.maximumStoredBytes else { throw PanelLayoutProfileError.storageTooLarge }
        defaults.set(data, forKey: Self.storageKey)
        self.profiles = profiles
        loadError = nil
    }

    private static func validate(_ profiles: [SavedPanelLayout]) throws {
        guard profiles.count <= maximumProfiles else { throw PanelLayoutProfileError.invalidLibrary }
        guard Set(profiles.map(\.id)).count == profiles.count else { throw PanelLayoutProfileError.invalidLibrary }
        var names: Set<String> = []
        for profile in profiles {
            do {
                guard try trimmedName(profile.name) == profile.name,
                      names.insert(nameKey(profile.name)).inserted else { throw PanelLayoutProfileError.invalidLibrary }
                try profile.configuration.validate()
            } catch {
                throw PanelLayoutProfileError.invalidLibrary
            }
        }
    }

    private static func trimmedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PanelLayoutProfileError.emptyName }
        guard trimmed.count <= maximumNameLength else { throw PanelLayoutProfileError.nameTooLong }
        guard !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw PanelLayoutProfileError.invalidName
        }
        return trimmed
    }

    private static func nameKey(_ name: String) -> String { name.lowercased() }

    private struct VersionHeader: Decodable {
        let version: Int
    }

    private struct Library: Codable {
        let version: Int
        let profiles: [SavedPanelLayout]
    }
}

enum PanelLayoutProfileError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case unreadableStorage, invalidLibrary, storageTooLarge, unavailable
    case emptyName, nameTooLong, invalidName, duplicateName, tooManyProfiles, notFound

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return L10n.localized(zh: "布局方案版本 \(version) 暂不受支持，原数据已保留。",
                                  en: "Layout library version \(version) is unsupported. The saved data is preserved.")
        case .unreadableStorage:
            return L10n.localized(zh: "无法读取布局方案库，原数据已保留。",
                                  en: "The layout library could not be read. The saved data is preserved.")
        case .invalidLibrary:
            return L10n.localized(zh: "布局方案库含无效或重复数据，原数据已保留。",
                                  en: "The layout library contains invalid or duplicate data. The saved data is preserved.")
        case .storageTooLarge:
            return L10n.localized(zh: "布局方案库超过大小限制，原数据已保留。",
                                  en: "The layout library exceeds the size limit. The saved data is preserved.")
        case .unavailable:
            return L10n.localized(zh: "布局方案库无法读取，暂不能保存更改；原数据已保留。",
                                  en: "Changes cannot be saved while the layout library is unreadable. The saved data is preserved.")
        case .emptyName:
            return L10n.localized(zh: "请输入布局方案名称。", en: "Enter a layout name.")
        case .nameTooLong:
            return L10n.localized(zh: "布局方案名称不能超过 40 个字符。", en: "Layout names must be 40 characters or fewer.")
        case .invalidName:
            return L10n.localized(zh: "布局方案名称不能包含换行或控制字符。",
                                  en: "Layout names cannot contain line breaks or control characters.")
        case .duplicateName:
            return L10n.localized(zh: "已有同名布局方案，请换一个名称。", en: "A layout with this name already exists. Choose another name.")
        case .tooManyProfiles:
            return L10n.localized(zh: "最多保存 50 套布局方案，请先删除不需要的方案。",
                                  en: "You can save up to 50 layouts. Delete an unused layout first.")
        case .notFound:
            return L10n.localized(zh: "此布局方案已不存在，请重新选择。", en: "This layout no longer exists. Select another layout.")
        }
    }
}
