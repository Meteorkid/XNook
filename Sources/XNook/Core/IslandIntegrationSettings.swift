import AppKit

enum IslandApp: String, CaseIterable, Identifiable {
    case xnook
    case xisland

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .xnook:
            return "X Nook"
        case .xisland:
            return "X Island"
        }
    }
}

enum IslandSwitchSensitivity: String, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var threshold: CGFloat {
        switch self {
        case .low:
            return 60
        case .medium:
            return 45
        case .high:
            return 30
        }
    }

    var axisRatio: CGFloat {
        switch self {
        case .low:
            return 1.8
        case .medium:
            return 1.5
        case .high:
            return 1.2
        }
    }
}

enum IslandStartupDisplayMode: String, CaseIterable, Identifiable {
    case lastUsed
    case xnook
    case xisland

    var id: String { rawValue }
}

enum IslandIntegrationSettings {
    /// 当前共享配置协议版本号，双方应用同步升级时递增
    static let protocolVersion = 1

    enum Key {
        static let protocolVersion = "island.integration.protocolVersion"
        static let swipeSwitchEnabled = "island.integration.swipeSwitchEnabled"
        static let swipeSensitivity = "island.integration.swipeSensitivity"
        static let startupDisplayMode = "island.integration.startupDisplayMode"
        static let lastShownIsland = "island.integration.lastShownIsland"
    }

    static let suiteName = "dev.xisland.integration"
    static let sharedDefaults = UserDefaults(suiteName: suiteName) ?? .standard

    static func registerDefaults() {
        sharedDefaults.register(defaults: [
            Key.protocolVersion: protocolVersion,
            Key.swipeSwitchEnabled: true,
            Key.swipeSensitivity: IslandSwitchSensitivity.medium.rawValue,
            Key.startupDisplayMode: IslandStartupDisplayMode.lastUsed.rawValue,
        ])
    }

    /// 检查对方应用的协议版本是否兼容（版本号相同或更高才兼容）
    static func isPeerProtocolCompatible() -> Bool {
        let peerVersion = sharedDefaults.integer(forKey: Key.protocolVersion)
        // peerVersion == 0 表示对方未写入版本号（旧版应用），视为兼容
        return peerVersion == 0 || peerVersion >= protocolVersion
    }

    static var isSwipeSwitchEnabled: Bool {
        get { sharedDefaults.bool(forKey: Key.swipeSwitchEnabled) }
        set { sharedDefaults.set(newValue, forKey: Key.swipeSwitchEnabled) }
    }

    static var swipeSensitivity: IslandSwitchSensitivity {
        get {
            IslandSwitchSensitivity(
                rawValue: sharedDefaults.string(forKey: Key.swipeSensitivity)
                    ?? IslandSwitchSensitivity.medium.rawValue
            )
            ?? .medium
        }
        set {
            sharedDefaults.set(newValue.rawValue, forKey: Key.swipeSensitivity)
        }
    }

    static var startupDisplayMode: IslandStartupDisplayMode {
        get {
            IslandStartupDisplayMode(
                rawValue: sharedDefaults.string(forKey: Key.startupDisplayMode)
                    ?? IslandStartupDisplayMode.lastUsed.rawValue
            )
            ?? .lastUsed
        }
        set {
            sharedDefaults.set(newValue.rawValue, forKey: Key.startupDisplayMode)
        }
    }

    static var lastShownIsland: IslandApp? {
        get {
            guard let rawValue = sharedDefaults.string(forKey: Key.lastShownIsland) else {
                return nil
            }
            return IslandApp(rawValue: rawValue)
        }
        set {
            sharedDefaults.set(newValue?.rawValue, forKey: Key.lastShownIsland)
        }
    }

    static func markVisible(_ app: IslandApp) {
        lastShownIsland = app
    }

    static func preferredStartupIsland(
        currentApp: IslandApp,
        otherAppInstalled: Bool
    ) -> IslandApp {
        switch startupDisplayMode {
        case .lastUsed:
            if let lastShownIsland {
                return lastShownIsland
            }
            return otherAppInstalled ? .xnook : currentApp
        case .xnook:
            return .xnook
        case .xisland:
            return .xisland
        }
    }

    static func shouldShowOnLaunch(
        currentApp: IslandApp,
        preferredApp: IslandApp,
        preferredAppRunning: Bool
    ) -> Bool {
        currentApp == preferredApp || !preferredAppRunning
    }
}
