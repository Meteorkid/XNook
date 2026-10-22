import AppKit
import Darwin

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
        static func protocolVersion(for app: IslandApp) -> String {
            "island.integration.protocolVersion.\(app.rawValue)"
        }
        static let swipeSwitchEnabled = "island.integration.swipeSwitchEnabled"
        static let swipeSensitivity = "island.integration.swipeSensitivity"
        static let startupDisplayMode = "island.integration.startupDisplayMode"
        static let lastShownIsland = "island.integration.lastShownIsland"
    }

    static let suiteName = "dev.xisland.integration"
    // 回归测试注入独立 suite，不修改正在运行的两款应用的联动偏好。
    static var sharedDefaults = UserDefaults(suiteName: suiteName) ?? .standard

    static func registerDefaults() {
        sharedDefaults.register(defaults: [
            Key.protocolVersion: protocolVersion,
            Key.swipeSwitchEnabled: true,
            Key.swipeSensitivity: IslandSwitchSensitivity.medium.rawValue,
            Key.startupDisplayMode: IslandStartupDisplayMode.lastUsed.rawValue,
        ])
    }

    static func markProtocolAvailable(for app: IslandApp) {
        sharedDefaults.set(protocolVersion, forKey: Key.protocolVersion(for: app))
    }

    /// 仅在对方已明确声明兼容版本时显示为就绪，避免把旧版误判为可联动。
    static func isPeerProtocolCompatible(_ peer: IslandApp) -> Bool {
        sharedDefaults.integer(forKey: Key.protocolVersion(for: peer)) >= protocolVersion
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

    /// 原子仲裁：用文件锁包装 read-then-write，确保跨进程互斥
    /// - Parameter currentApp: 当前应用
    /// - Parameter isInstalled: 检查某个 IslandApp 是否已安装的闭包
    /// - Parameter isVisible: 检查某个 IslandApp 的岛窗口是否已显示的闭包
    /// - Returns: true 表示获得了显示权，false 表示应隐藏
    /// 等待跨进程锁的最长时间。对方正常只持锁几毫秒执行读改写；超过这个时间
    /// 说明对方被挂起或卡死，此时降级放行，不能让调用方（主线程）无限等待。
    private static let lockWaitTimeout: TimeInterval = 0.1
    /// 每次重试之间的等待间隔
    private static let lockRetryInterval: TimeInterval = 0.005

    static func claimVisibility(
        currentApp: IslandApp,
        isInstalled: (IslandApp) -> Bool,
        isVisible: (IslandApp) -> Bool
    ) -> Bool {
        let lockPath = NSTemporaryDirectory() + "xnook_island_visibility.lock"
        // O_NOFOLLOW：锁文件位于所有人可写的临时目录，绝不能跟随符号链接。
        // O_CLOEXEC：不要把描述符泄漏给子进程。0600：同机其他用户不应接触。
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            // 文件锁失败时的降级：直接标记并显示
            markVisible(currentApp)
            return true
        }
        defer { close(fd) }

        guard acquireLock(fd, timeout: lockWaitTimeout) else {
            // 拿不到锁时按自己的意愿处理，宁可短暂双岛也不能让启动流程卡死。
            markVisible(currentApp)
            return true
        }
        defer { flock(fd, LOCK_UN) }

        // 在锁内读取，确保与写入的原子性
        if let lastApp = lastShownIsland {
            // lastShownIsland 指向的应用如果已安装且窗口可见，才继续保留它的显示权
            if lastApp != currentApp && isInstalled(lastApp) && isVisible(lastApp) {
                return false
            }
            // lastShownIsland 指向的应用未安装，忽略其仲裁权
        }

        // 自己声明显示权
        markVisible(currentApp)
        return true
    }

    /// 以非阻塞方式反复尝试加锁，直到超时。返回 false 表示超时或遇到不可恢复错误。
    private static func acquireLock(_ fd: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var delay = timespec(tv_sec: 0, tv_nsec: Int(lockRetryInterval * 1_000_000_000))
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
            let failure = errno
            // EWOULDBLOCK / EAGAIN 表示对方持锁，可以重试；其他错误无法恢复。
            guard failure == EWOULDBLOCK || failure == EAGAIN else { return false }
            guard Date() < deadline else { return false }
            nanosleep(&delay, nil)
        }
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
        preferredAppVisible: Bool
    ) -> Bool {
        currentApp == preferredApp || !preferredAppVisible
    }
}
