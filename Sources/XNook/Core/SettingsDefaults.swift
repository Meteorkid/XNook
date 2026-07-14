import Foundation

enum SettingsDefaults {
    static let values: [String: Any] = [
        "showOnAllSpaces": true,
        "hideInFullscreen": true,
        "expandedInactivityAutoHideDelay": 1.0,
        "hoverExitCollapseDelay": 0.2,
        "panelWidth": 800.0,
        "panelBaseHeight": 400.0,
        "islandWidth": 253.0,
        "islandHeight": 40.0,
        "islandWidthWithLyrics": 263.0,
        "islandHeightWithLyrics": 36.0,
        "hoverToExpandPanel": false,
        "scrollDownToExpandPanel": true,
        "reduceMotion": false,
        "jellyIntensity": "medium",
        "launchAtLogin": false,
        "showTickerLine": true,
        "showLyrics": true,
        "tickerSpeed": 25.0,
        "quietHoursEnabled": false,
        "quietHoursStart": "22:00",
        "quietHoursEnd": "07:00",
        "calendarReminderSoundEnabled": false,
        "calendarReminderLeadMinutes": 5.0,
        "calendarReminderSoundName": "Glass",
        "showNookFlowHistory": true,
        "nookFlowHistoryDisplayLimit": 3,
    ]

    static func register(on defaults: UserDefaults = .standard) {
        defaults.register(defaults: values)
    }

    static func bool(for key: String, fallback: Bool = false) -> Bool {
        values[key] as? Bool ?? fallback
    }

    static func double(for key: String, fallback: Double = 0) -> Double {
        values[key] as? Double ?? fallback
    }

    static func int(for key: String, fallback: Int = 0) -> Int {
        values[key] as? Int ?? fallback
    }

    static func string(for key: String, fallback: String = "") -> String {
        values[key] as? String ?? fallback
    }
}
