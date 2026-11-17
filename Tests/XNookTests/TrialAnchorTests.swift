import XCTest
import CryptoKit
@testable import XNook
import XNookLicenseCore

/// 试用锚点测试。
///
/// 覆盖双位置冗余与时钟回拨防护——这两点是防重置机制的核心。
final class TrialAnchorTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        suiteName = "xnook.tests.trial.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xnook-trial-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        TrialAnchor.stateDirectoryOverride = tempDirectory
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDirectory)
        TrialAnchor.stateDirectoryOverride = nil
        defaults = nil
        super.tearDown()
    }

    // MARK: - 初始化

    func testFirstLoadCreatesAnchorAtNow() {
        let now = Date()
        let (anchor, wasReset) = TrialAnchor.loadOrCreate(defaults: defaults, now: now)

        XCTAssertTrue(wasReset, "首次加载应报告为新建")
        XCTAssertEqual(anchor.firstSeen.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(anchor.lastSeen.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.01)
    }

    func testAnchorPersistsAcrossLoads() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        _ = TrialAnchor.loadOrCreate(defaults: defaults, now: start)

        // 三天后再加载：firstSeen 必须保持不变
        let later = start.addingTimeInterval(3 * 86_400)
        let (anchor, wasReset) = TrialAnchor.loadOrCreate(defaults: defaults, now: later)

        XCTAssertFalse(wasReset, "已有记录时不应报告为新建")
        XCTAssertEqual(anchor.firstSeen.timeIntervalSince1970, start.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(anchor.lastSeen.timeIntervalSince1970, later.timeIntervalSince1970, accuracy: 0.01)
    }

    // MARK: - 双位置冗余（防重置的核心）

    func testDeletingDefaultsDoesNotResetTrial() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        _ = TrialAnchor.loadOrCreate(defaults: defaults, now: start)

        // 模拟用户执行 defaults delete：只清掉 UserDefaults 那一份
        defaults.removeObject(forKey: "xnook.trial.anchor")

        let later = start.addingTimeInterval(5 * 86_400)
        let (anchor, _) = TrialAnchor.loadOrCreate(defaults: defaults, now: later)

        XCTAssertEqual(
            anchor.firstSeen.timeIntervalSince1970,
            start.timeIntervalSince1970,
            accuracy: 0.01,
            "删除 UserDefaults 后试用起点被重置——冗余保护失效"
        )
    }

    func testDeletingStateFileDoesNotResetTrial() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        _ = TrialAnchor.loadOrCreate(defaults: defaults, now: start)

        // 模拟用户删除隐藏文件：只清掉文件那一份
        let anchorFile = tempDirectory.appendingPathComponent("install-anchor")
        try? FileManager.default.removeItem(at: anchorFile)

        let later = start.addingTimeInterval(5 * 86_400)
        let (anchor, _) = TrialAnchor.loadOrCreate(defaults: defaults, now: later)

        XCTAssertEqual(
            anchor.firstSeen.timeIntervalSince1970,
            start.timeIntervalSince1970,
            accuracy: 0.01,
            "删除状态文件后试用起点被重置——冗余保护失效"
        )
    }

    func testDeletingBothResetsTrial() {
        // 已知上限：两处都删即可重置。这是纯本地方案的固有边界，
        // 本测试把它显式记录下来，避免日后误以为能防住。
        let start = Date(timeIntervalSince1970: 1_000_000)
        _ = TrialAnchor.loadOrCreate(defaults: defaults, now: start)

        defaults.removeObject(forKey: "xnook.trial.anchor")
        try? FileManager.default.removeItem(
            at: tempDirectory.appendingPathComponent("install-anchor")
        )

        let later = start.addingTimeInterval(100 * 86_400)
        let (anchor, wasReset) = TrialAnchor.loadOrCreate(defaults: defaults, now: later)

        XCTAssertTrue(wasReset)
        XCTAssertEqual(
            anchor.firstSeen.timeIntervalSince1970,
            later.timeIntervalSince1970,
            accuracy: 0.01,
            "两处均删除时应从当前时间重新开始（这是已知且可接受的上限）"
        )
    }

    func testMergeTakesEarliestFirstSeen() {
        // 构造"两处记录不一致"的局面，验证取包络
        let early = Date(timeIntervalSince1970: 1_000_000)
        let late = Date(timeIntervalSince1970: 2_000_000)

        // 文件里写较早的起点
        let anchorFile = tempDirectory.appendingPathComponent("install-anchor")
        let fileRecord = AnchorRecord(firstSeen: early, lastSeen: early)
        try? JSONEncoder().encode(fileRecord).write(to: anchorFile)

        // UserDefaults 里写较晚的起点（模拟用户篡改 defaults 想重置）
        let defaultsRecord = AnchorRecord(firstSeen: late, lastSeen: late)
        defaults.set(try? JSONEncoder().encode(defaultsRecord), forKey: "xnook.trial.anchor")

        let (merged, _) = TrialAnchor.loadOrCreate(defaults: defaults, now: late)

        XCTAssertEqual(
            merged.firstSeen.timeIntervalSince1970,
            early.timeIntervalSince1970,
            accuracy: 0.01,
            "应取更早的 firstSeen——否则篡改 defaults 即可重置试用"
        )
    }

    // MARK: - 时钟回拨防护

    func testClockRollbackDoesNotReduceElapsedDays() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let day5 = start.addingTimeInterval(5 * 86_400)

        _ = TrialAnchor.loadOrCreate(defaults: defaults, now: start)
        let (anchor, _) = TrialAnchor.loadOrCreate(defaults: defaults, now: day5)

        // 用户把系统时钟调回起点之前
        let rolledBack = start.addingTimeInterval(-10 * 86_400)
        let elapsed = TrialAnchor.elapsedDays(of: anchor, now: rolledBack)

        XCTAssertEqual(
            elapsed, 5,
            "时钟回拨后已用天数被缩短——回拨防护失效"
        )
    }

    func testElapsedDaysRoundsUp() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let anchor = AnchorRecord(firstSeen: start, lastSeen: start)

        // 刚过 1 秒也应算作 1 天，避免"最后一刻多送几小时"
        XCTAssertEqual(TrialAnchor.elapsedDays(of: anchor, now: start.addingTimeInterval(1)), 1)
        XCTAssertEqual(TrialAnchor.elapsedDays(of: anchor, now: start.addingTimeInterval(86_400)), 1)
        XCTAssertEqual(TrialAnchor.elapsedDays(of: anchor, now: start.addingTimeInterval(86_401)), 2)
        XCTAssertEqual(TrialAnchor.elapsedDays(of: anchor, now: start.addingTimeInterval(14 * 86_400)), 14)
        XCTAssertEqual(TrialAnchor.elapsedDays(of: anchor, now: start.addingTimeInterval(14 * 86_400 + 1)), 15)
    }

    func testElapsedDaysIsZeroAtExactStart() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let anchor = AnchorRecord(firstSeen: start, lastSeen: start)
        XCTAssertEqual(TrialAnchor.elapsedDays(of: anchor, now: start), 0)
    }

    // MARK: - 剩余天数

    func testRemainingDays() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let anchor = AnchorRecord(firstSeen: start, lastSeen: start)

        XCTAssertEqual(TrialAnchor.remainingDays(of: anchor, now: start), 14)
        XCTAssertEqual(TrialAnchor.remainingDays(of: anchor, now: start.addingTimeInterval(86_400)), 13)
        XCTAssertEqual(TrialAnchor.remainingDays(of: anchor, now: start.addingTimeInterval(13 * 86_400)), 1)
        XCTAssertEqual(TrialAnchor.remainingDays(of: anchor, now: start.addingTimeInterval(14 * 86_400)), 0)
        XCTAssertEqual(TrialAnchor.remainingDays(of: anchor, now: start.addingTimeInterval(15 * 86_400)), -1)
    }

    // MARK: - 存储状态报告

    func testStorageReport() {
        XCTAssertEqual(TrialAnchor.storageReport(defaults: defaults), "none")

        _ = TrialAnchor.loadOrCreate(defaults: defaults, now: Date())
        XCTAssertEqual(TrialAnchor.storageReport(defaults: defaults), "both")

        defaults.removeObject(forKey: "xnook.trial.anchor")
        XCTAssertEqual(TrialAnchor.storageReport(defaults: defaults), "file-only")
    }
}
