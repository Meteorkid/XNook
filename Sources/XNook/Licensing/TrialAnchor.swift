import Foundation

/// 试用期锚点：记录软件的首次启动时间与最近一次启动时间。
struct AnchorRecord: Codable, Equatable {
    /// 首次观测到的启动时间。这是试用期的起点。
    var firstSeen: Date
    /// 最近一次启动时间。用于检测系统时钟回拨。
    var lastSeen: Date
}

/// 试用期锚点存储。
///
/// ## 为什么不用单一存储点
///
/// 如果只把首次启动时间写进 `UserDefaults`，一条
/// `defaults delete com.meteorkid.xnook` 就能重置 14 天试用。
/// 因此这里采用**双位置冗余 + 单调时间校验**：
///
/// 1. 位置一：`UserDefaults`（用户最先想到去清理的地方）
/// 2. 位置二：应用支持目录下的隐藏文件
///    `~/Library/Application Support/XNook/.state/install-anchor`
///
/// 读取时对两处记录取**包络**：`firstSeen` 取更早者，`lastSeen` 取更晚者。
/// 于是删除其中任意一处都无法回退试用起点——剩下那处仍保留原始值。
///
/// ## 时间回拨防护
///
/// 每次启动刷新 `lastSeen`。计算已用天数时取
/// `effectiveNow = max(系统当前时间, lastSeen)`，
/// 因此把系统时钟往前调不会缩短已用天数。
///
/// ## 防护上限（须知）
///
/// 本机制的目标是**提高随手重置的门槛**，不是提供密码学强度的防篡改。
/// 用户拥有自己机器的完全控制权：同时删除两处记录、或修改系统时间后
/// 手动改写文件，仍可重置试用。这是所有纯本地试用方案的共同上限。
/// 若需要严格防护，必须引入服务端校验——但代价是断网不可用。
enum TrialAnchor {

    /// 试用期长度
    static let trialDays = 14

    private static let defaultsKey = "xnook.trial.anchor"

    /// 隐藏状态文件所在目录。
    ///
    /// 测试通过 `stateDirectoryOverride` 指向临时目录，避免污染真实安装目录。
    nonisolated(unsafe) static var stateDirectoryOverride: URL?

    private static var stateDirectory: URL? {
        if let stateDirectoryOverride { return stateDirectoryOverride }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("XNook", isDirectory: true)
            .appendingPathComponent(".state", isDirectory: true)
    }

    private static var anchorFileURL: URL? {
        stateDirectory?.appendingPathComponent("install-anchor")
    }

    // MARK: - 读写

    /// 读取锚点记录，必要时初始化。
    ///
    /// - Returns: 合并后的锚点，以及本次读取是否发现记录缺失（用于诊断）。
    static func loadOrCreate(defaults: UserDefaults = .standard,
                             now: Date = Date()) -> (anchor: AnchorRecord, wasReset: Bool) {
        let fromDefaults = readFromDefaults(defaults)
        let fromFile = readFromFile()

        var merged: AnchorRecord
        switch (fromDefaults, fromFile) {
        case let (.some(a), .some(b)):
            // 两处都在：取包络，任一处被删都不影响
            merged = AnchorRecord(
                firstSeen: min(a.firstSeen, b.firstSeen),
                lastSeen: max(a.lastSeen, b.lastSeen)
            )
        case let (.some(a), .none):
            merged = a
        case let (.none, .some(b)):
            merged = b
        case (.none, .none):
            // 两处都无：视为全新安装
            merged = AnchorRecord(firstSeen: now, lastSeen: now)
            persist(merged, defaults: defaults)
            return (merged, true)
        }

        // 单调推进 lastSeen
        if now > merged.lastSeen {
            merged.lastSeen = now
        }
        persist(merged, defaults: defaults)
        return (merged, false)
    }

    /// 已使用的天数（向上取整）。
    ///
    /// 取 `effectiveNow = max(now, lastSeen)` 以抵御系统时钟回拨。
    static func elapsedDays(of anchor: AnchorRecord, now: Date = Date()) -> Int {
        let effectiveNow = max(now, anchor.lastSeen)
        let interval = effectiveNow.timeIntervalSince(anchor.firstSeen)
        guard interval > 0 else { return 0 }
        // 向上取整：不足一天也算一天，避免最后一刻被"多送"几小时
        return Int(ceil(interval / 86_400))
    }

    /// 剩余天数（可为负，表示已超期）
    static func remainingDays(of anchor: AnchorRecord, now: Date = Date()) -> Int {
        trialDays - elapsedDays(of: anchor, now: now)
    }

    // MARK: - 持久化

    private static func persist(_ anchor: AnchorRecord, defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(anchor) {
            defaults.set(data, forKey: defaultsKey)
        }
        writeToFile(anchor)
    }

    private static func readFromDefaults(_ defaults: UserDefaults) -> AnchorRecord? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(AnchorRecord.self, from: data)
    }

    private static func writeToFile(_ anchor: AnchorRecord) {
        guard let directory = stateDirectory, let fileURL = anchorFileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(anchor)
            try data.write(to: fileURL, options: .atomic)
            // 隐藏文件：降低被随手发现并删除的概率
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            // 写入失败不影响主流程——UserDefaults 那一份仍然有效
        }
    }

    private static func readFromFile() -> AnchorRecord? {
        guard let fileURL = anchorFileURL,
              let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(AnchorRecord.self, from: data)
    }

    // MARK: - 诊断

    /// 仅供测试与故障排查：抹除两处记录。
    static func resetForTesting(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
        if let fileURL = anchorFileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// 两处记录的当前状态描述，用于「关于」页诊断。
    static func storageReport(defaults: UserDefaults = .standard) -> String {
        let hasDefaults = readFromDefaults(defaults) != nil
        let hasFile = readFromFile() != nil
        switch (hasDefaults, hasFile) {
        case (true, true):   return "both"
        case (true, false):  return "defaults-only"
        case (false, true):  return "file-only"
        case (false, false): return "none"
        }
    }
}
