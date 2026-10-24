import Foundation
import Observation

@Observable @MainActor
final class PanelLayoutStore {
    static let storageKey = "panelLayout.v1"
    static let recoveryBackupKey = "panelLayout.v1.recoveryBackup"

    let defaults: UserDefaults
    private(set) var configuration: PanelLayoutConfiguration
    private(set) var loadError: String?
    private(set) var hasSavedConfiguration = false

    var canEdit: Bool { loadError == nil }

    func shouldFitDefaultContent(
        automaticallyFit: Bool, isEditing: Bool = false, isOverview: Bool = true
    ) -> Bool {
        automaticallyFit && !hasSavedConfiguration && loadError == nil && !isEditing && isOverview
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = .factoryDefault
        reload()
    }

    func reload() {
        let stored = defaults.object(forKey: Self.storageKey)
        hasSavedConfiguration = stored != nil
        guard let stored else {
            let enabled = defaults.data(forKey: "enabledWidgets")
                .flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) }
                ?? PanelLayoutConfiguration.defaultWidgetIDs
            let history = defaults.object(forKey: "showNookFlowHistory") == nil
                ? SettingsDefaults.bool(for: "showNookFlowHistory", fallback: true)
                : defaults.bool(forKey: "showNookFlowHistory")
            configuration = .legacy(enabledWidgetIDs: enabled, showHistory: history)
            loadError = nil
            return
        }
        do {
            guard let data = stored as? Data else { throw PanelLayoutError.unreadableStorage }
            let header = try JSONDecoder().decode(VersionHeader.self, from: data)
            guard header.version == PanelLayoutConfiguration.currentVersion else {
                throw PanelLayoutError.unsupportedVersion(header.version)
            }
            let decoded = try JSONDecoder().decode(PanelLayoutConfiguration.self, from: data)
            try decoded.validate()
            configuration = decoded
            loadError = nil
        } catch {
            loadError = (error as? PanelLayoutError ?? .unreadableStorage).localizedDescription
        }
    }

    func save(_ configuration: PanelLayoutConfiguration) throws {
        guard canEdit else { throw PanelLayoutError.recoveryRequired }
        try persist(configuration)
    }

    /// 仅由用户明确选择恢复默认布局触发，允许替换损坏或未来版本的数据。
    func reset() throws {
        if loadError != nil, defaults.object(forKey: Self.recoveryBackupKey) == nil,
           let original = defaults.object(forKey: Self.storageKey) {
            defaults.set(original, forKey: Self.recoveryBackupKey)
        }
        try persist(.factoryDefault)
    }

    private func persist(_ configuration: PanelLayoutConfiguration) throws {
        try configuration.validate()
        let data = try JSONEncoder().encode(configuration)
        defaults.set(data, forKey: Self.storageKey)
        self.configuration = configuration
        hasSavedConfiguration = true
        loadError = nil
    }

    private struct VersionHeader: Decodable {
        let version: Int
    }
}
