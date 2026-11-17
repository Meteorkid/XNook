import XCTest
import CryptoKit
@testable import XNook
import XNookLicenseCore

/// 授权管理器测试。
///
/// 覆盖状态机转换、激活流程、凭证防伪。
@MainActor
final class LicenseManagerTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var tempDirectory: URL!
    private var privateKey: Curve25519.Signing.PrivateKey!

    override func setUp() {
        super.setUp()
        suiteName = "xnook.tests.license.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xnook-license-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        TrialAnchor.stateDirectoryOverride = tempDirectory

        // 注入临时密钥，使激活路径可被真实测试
        privateKey = Curve25519.Signing.PrivateKey()
        LicenseManager.publicKeyOverride = privateKey.publicKey
    }

    override func tearDown() {
        LicenseManager.publicKeyOverride = nil
        TrialAnchor.stateDirectoryOverride = nil
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDirectory)
        privateKey = nil
        defaults = nil
        super.tearDown()
    }

    private func makeCode(serial: UInt32 = 1,
                          flags: LicenseFlags = [.perpetual]) throws -> String {
        try LicenseSigning.issue(
            payload: LicensePayload(serial: serial, flags: flags),
            privateKey: privateKey
        ).encoded
    }

    // MARK: - 初始状态

    func testFreshInstallStartsInTrial() {
        let manager = LicenseManager(defaults: defaults, now: Date())
        guard case .trial(let days) = manager.state else {
            return XCTFail("全新安装应处于试用状态，实际为 \(manager.state)")
        }
        XCTAssertEqual(days, 14)
    }

    func testTrialWithoutPublicKeyIsUnconfigured() {
        LicenseManager.publicKeyOverride = nil
        // 同时确保真实的占位公钥也不可用
        let manager = LicenseManager(defaults: defaults, now: Date())
        if LicensePublicKey.isPlaceholder {
            XCTAssertEqual(manager.state, .unconfigured)
        }
    }

    // MARK: - 试用期推进

    func testTrialCountsDown() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let manager = LicenseManager(defaults: defaults, now: start)

        manager.refresh(now: start.addingTimeInterval(3 * 86_400))
        guard case .trial(let days) = manager.state else {
            return XCTFail("第 3 天应仍在试用，实际为 \(manager.state)")
        }
        XCTAssertEqual(days, 11)
    }

    func testTrialExpiresAfterFourteenDays() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let manager = LicenseManager(defaults: defaults, now: start)

        manager.refresh(now: start.addingTimeInterval(14 * 86_400))
        XCTAssertEqual(manager.state, .expired)
        XCTAssertFalse(manager.state.allowsFullAccess)
    }

    func testExpiredStateLocksFullAccess() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let manager = LicenseManager(defaults: defaults, now: start)
        manager.refresh(now: start.addingTimeInterval(20 * 86_400))

        XCTAssertEqual(manager.state, .expired)
        XCTAssertFalse(manager.state.allowsFullAccess)
        XCTAssertFalse(manager.state.isLicensed)
    }

    // MARK: - 激活成功

    func testValidCodeActivates() async throws {
        let manager = LicenseManager(defaults: defaults, now: Date())
        let code = try makeCode(serial: 42)

        let outcome = await manager.activate(input: code)

        guard case .success(let serial, let flags) = outcome else {
            return XCTFail("有效邀请码激活失败：\(outcome)")
        }
        XCTAssertEqual(serial, 42)
        XCTAssertTrue(flags.contains(.perpetual))
        XCTAssertTrue(manager.state.isLicensed)
        XCTAssertTrue(manager.state.allowsFullAccess)
    }

    func testActivationSurvivesRestart() async throws {
        let code = try makeCode(serial: 77)

        let first = LicenseManager(defaults: defaults, now: Date())
        _ = await first.activate(input: code)

        // 模拟重启：新建实例读取同一份 defaults
        let second = LicenseManager(defaults: defaults, now: Date())
        XCTAssertTrue(second.state.isLicensed, "重启后授权丢失")
        if case .licensed(let serial, _) = second.state {
            XCTAssertEqual(serial, 77)
        }
        XCTAssertEqual(second.activatedCode, code)
    }

    func testActivationFromExpiredStateRestoresAccess() async throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let manager = LicenseManager(defaults: defaults, now: start)
        manager.refresh(now: start.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(manager.state, .expired)

        let outcome = await manager.activate(input: try makeCode(serial: 5))
        guard case .success = outcome else {
            return XCTFail("到期后激活应成功：\(outcome)")
        }
        XCTAssertTrue(manager.state.allowsFullAccess)
    }

    func testRefreshDoesNotDowngradeLicensedState() async throws {
        let manager = LicenseManager(defaults: defaults, now: Date())
        _ = await manager.activate(input: try makeCode(serial: 8))

        // 即使过了很久，已激活状态也不能被 refresh 降级
        manager.refresh(now: Date().addingTimeInterval(1000 * 86_400))
        XCTAssertTrue(manager.state.isLicensed)
    }

    // MARK: - 激活失败

    func testForgedCodeIsRejected() async {
        // 用另一把密钥签发——模拟伪造者
        let attackerKey = Curve25519.Signing.PrivateKey()
        let forged = try! LicenseSigning.issue(
            payload: LicensePayload(serial: 1),
            privateKey: attackerKey
        ).encoded

        let manager = LicenseManager(defaults: defaults, now: Date())
        let outcome = await manager.activate(input: forged)

        guard case .failure = outcome else {
            return XCTFail("他人密钥签发的码不应激活成功")
        }
        XCTAssertFalse(manager.state.isLicensed)
    }

    func testGarbageInputIsRejected() async {
        let manager = LicenseManager(defaults: defaults, now: Date())
        for garbage in ["", "hello", "XNK1-AAAA-BBBB", String(repeating: "Z", count: 200)] {
            let outcome = await manager.activate(input: garbage)
            guard case .failure = outcome else {
                return XCTFail("无效输入「\(garbage.prefix(20))」不应激活成功")
            }
        }
        XCTAssertFalse(manager.state.isLicensed)
    }

    func testTamperedCodeIsRejected() async throws {
        var code = try LicenseSigning.issue(
            payload: LicensePayload(serial: 1),
            privateKey: privateKey
        )
        // 翻转签名一位
        code.signature[10] ^= 0x01

        let manager = LicenseManager(defaults: defaults, now: Date())
        let outcome = await manager.activate(input: code.encoded)

        guard case .failure = outcome else {
            return XCTFail("签名被篡改的码不应激活成功")
        }
        XCTAssertFalse(manager.state.isLicensed)
    }

    // MARK: - 凭证防伪

    func testHandWrittenCredentialIsRejected() {
        // 模拟用户手工往 defaults 里塞一条伪造凭证
        let fake = """
        {"code":"XNK1-0000","serial":999999,"flags":1,"activatedAt":0}
        """
        defaults.set(Data(fake.utf8), forKey: "xnook.license.credential")

        let manager = LicenseManager(defaults: defaults, now: Date())
        XCTAssertFalse(
            manager.state.isLicensed,
            "手工写入的凭证通过了验证——验签环节被绕过"
        )
    }

    func testCredentialWithInvalidCodeIsRejected() {
        // 落盘凭证里的邀请码本身非法时，恢复必须失败
        let badCredential = """
        {"code":"XNK1-NOT-A-REAL-CODE","serial":3,"flags":1,"activatedAt":0}
        """
        defaults.set(Data(badCredential.utf8), forKey: "xnook.license.credential")

        let reloaded = LicenseManager(defaults: defaults, now: Date())
        XCTAssertFalse(
            reloaded.state.isLicensed,
            "落盘凭证中的非法邀请码未被拒绝"
        )
    }

    // MARK: - 解除激活

    func testDeactivateRestoresTrial() async throws {
        let manager = LicenseManager(defaults: defaults, now: Date())
        _ = await manager.activate(input: try makeCode(serial: 1))
        XCTAssertTrue(manager.state.isLicensed)

        manager.deactivate()
        XCTAssertFalse(manager.state.isLicensed)
        // 试用期内应回到试用状态
        guard case .trial = manager.state else {
            return XCTFail("解除激活后应回到试用状态，实际为 \(manager.state)")
        }
    }

    // MARK: - 状态摘要

    func testStatusSummaryIsNonEmpty() async throws {
        let manager = LicenseManager(defaults: defaults, now: Date())
        XCTAssertFalse(manager.statusSummary.isEmpty)

        _ = await manager.activate(input: try makeCode(serial: 1))
        XCTAssertFalse(manager.statusSummary.isEmpty)
    }
}
