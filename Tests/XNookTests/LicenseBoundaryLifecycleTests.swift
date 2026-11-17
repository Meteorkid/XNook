import XCTest
import CryptoKit
import AppKit
import MeteorLicenseCore
@testable import XNook

@MainActor
final class LicenseBoundaryLifecycleTests: XCTestCase {
    func testStoppedManagerRejectsNewRequestsWithoutNetworkTraffic() async {
        let fixture = LicenseLifecycleFixture()
        let manager = fixture.makeManager()
        manager.stopMonitoring()
        let result = await manager.activate(input: "AUDIT-CODE")
        if case .success = result { XCTFail("停止后不应发起新激活") }
        await manager.connect()
        let count = await fixture.transport.requestCount()
        XCTAssertEqual(count, 0)
        XCTAssertFalse(manager.isWorking)
    }

    func testMonitoringCanRestartAfterCancelledActivation() async throws {
        let fixture = LicenseLifecycleFixture()
        let manager = fixture.makeManager()
        defer { manager.stopMonitoring() }
        let first = Task { await manager.activate(input: "AUDIT-CODE") }
        await fixture.transport.waitUntilRequested()
        manager.stopMonitoring()
        await fixture.transport.complete(data: try fixture.responseData())
        _ = await first.value
        XCTAssertFalse(manager.state.allowsAccess)
        manager.startMonitoring()
        await fixture.transport.waitUntilRequested()
        await fixture.transport.complete(data: try fixture.responseData(kind: "trial", entitlement: fixture.now + 14 * 86_400))
        await waitUntilIdle(manager)
        XCTAssertTrue(manager.state.allowsAccess)
        XCTAssertFalse(manager.isLicensed)
    }

    func testTrialStateDoesNotOfferPaidDeviceUnlink() async throws {
        let fixture = LicenseLifecycleFixture()
        let manager = fixture.makeManager()
        defer { manager.stopMonitoring() }
        let request = Task { await manager.connect() }
        await fixture.transport.waitUntilRequested()
        await fixture.transport.complete(data: try fixture.responseData(kind: "trial", entitlement: fixture.now + 14 * 86_400))
        await request.value
        XCTAssertTrue(manager.state.allowsAccess)
        XCTAssertFalse(manager.isLicensed, "授权视图以此属性控制解绑按钮，试用不能显示")
        XCTAssertEqual(manager.remainingTrialDays, 14)
        XCTAssertNotNil(manager.expirySummary)
    }

    func testPaidTermsOfferDeviceUnlinkAndCorrectExpirySummary() async throws {
        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        for language in ["zh", "en"] {
            var arguments = originalArguments
            arguments["appLanguage"] = language
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            XCTAssertEqual(L10n.licenseEnterCode, language == "zh" ? "激活码" : "Activation code")
            for (kind, chinese, english) in [("monthly", "一个月", "1 month"), ("annual", "一年", "1 year"), ("lifetime", "永久", "Lifetime")] {
                let fixture = LicenseLifecycleFixture()
                let manager = fixture.makeManager()
                defer { manager.stopMonitoring() }
                let request = Task { await manager.activate(input: "AUDIT-CODE") }
                await fixture.transport.waitUntilRequested()
                await fixture.transport.complete(data: try fixture.responseData(kind: kind,
                    entitlement: kind == "lifetime" ? nil : fixture.now + 365 * 86_400))
                let result = await request.value
                XCTAssertEqual(result, .success)
                XCTAssertTrue(manager.isLicensed)
                XCTAssertNil(manager.remainingTrialDays)
                XCTAssertEqual(manager.statusSummary, language == "zh" ? "已激活 · \(chinese)" : "Activated · \(english)")
                let noRenewal = language == "zh" ? "无需续费" : "No renewal"
                XCTAssertEqual(manager.expirySummary?.contains(noRenewal), kind == "lifetime")
            }
        }
    }

    func testWakeLocksExpiredLeaseBeforeWaitingForNetworkRefresh() async throws {
        let fixture = LicenseLifecycleFixture()
        let manager = fixture.makeManager()
        defer { manager.stopMonitoring() }
        let request = Task { await manager.activate(input: "AUDIT-CODE") }
        await fixture.transport.waitUntilRequested()
        let receipt = try fixture.responseData()
        await fixture.transport.complete(data: receipt)
        _ = await request.value
        manager.startMonitoring()
        await fixture.transport.waitUntilRequested()
        await fixture.transport.complete(data: receipt)
        await waitUntilIdle(manager)
        var accessChanges: [Bool] = []
        manager.onAccessChange = { accessChanges.append($0) }
        fixture.simulatedNow = Date(timeIntervalSince1970: fixture.now + 601)
        fixture.notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        await fixture.transport.waitUntilRequested()
        XCTAssertEqual(manager.state, .expired, "唤醒时不能等待网络返回才锁定已过期租约")
        XCTAssertEqual(accessChanges, [false])
        await fixture.transport.complete(data: Data("{\"error\":\"暂不可用\"}".utf8), status: 503)
        await waitUntilIdle(manager)
        XCTAssertFalse(manager.state.allowsAccess)
    }

    func testSuccessfulRefreshOfSameLeaseClearsPreviousError() async throws {
        let fixture = LicenseLifecycleFixture()
        let manager = fixture.makeManager()
        defer { manager.stopMonitoring() }
        let activation = Task { await manager.activate(input: "AUDIT-CODE") }
        await fixture.transport.waitUntilRequested()
        let receipt = try fixture.responseData()
        await fixture.transport.complete(data: receipt)
        _ = await activation.value
        _ = await manager.activate(input: "XNK1-OLD")
        XCTAssertNotNil(manager.lastError)
        let renewal = Task { await manager.connect() }
        await fixture.transport.waitUntilRequested()
        await fixture.transport.complete(data: receipt)
        await renewal.value
        XCTAssertTrue(manager.state.allowsAccess)
        XCTAssertNil(manager.lastError)
    }

    func testStopMonitoringCancelsPendingStartupAndRejectsLateLease() async throws {
        let fixture = LicenseLifecycleFixture()
        let manager = fixture.makeManager()
        defer { manager.stopMonitoring() }
        let unwantedActivation = expectation(description: "停止后不得因迟到响应重新激活")
        unwantedActivation.isInverted = true
        manager.onAccessChange = { allowed in if allowed { unwantedActivation.fulfill() } }
        manager.startMonitoring()
        await fixture.transport.waitUntilRequested()
        manager.stopMonitoring()
        await fixture.transport.complete(data: try fixture.responseData(kind: "trial", entitlement: fixture.now + 14 * 86_400))
        await fulfillment(of: [unwantedActivation], timeout: 0.15)
        XCTAssertFalse(manager.state.allowsAccess)
        XCTAssertNil(try fixture.savedObject()["deviceToken"])
    }

    func testStopMonitoringCancelsPendingManualActivation() async throws {
        let fixture = LicenseLifecycleFixture()
        let manager = fixture.makeManager()
        defer { manager.stopMonitoring() }
        let request = Task { await manager.activate(input: "AUDIT-CODE") }
        await fixture.transport.waitUntilRequested()
        manager.stopMonitoring()
        await fixture.transport.complete(data: try fixture.responseData())
        let result = await request.value
        if case .success = result { XCTFail("停止后不能返回激活成功") }
        XCTAssertFalse(manager.state.allowsAccess)
        XCTAssertNil(try fixture.savedObject()["deviceToken"])
    }

    func testCancellingCallerPropagatesToPendingActivation() async throws {
        let fixture = LicenseLifecycleFixture()
        let manager = fixture.makeManager()
        defer { manager.stopMonitoring() }
        let request = Task { await manager.activate(input: "AUDIT-CODE") }
        await fixture.transport.waitUntilRequested()
        request.cancel()
        await fixture.transport.complete(data: try fixture.responseData())
        let result = await request.value
        if case .success = result { XCTFail("调用者取消后不能接受迟到激活") }
        XCTAssertFalse(manager.state.allowsAccess)
        XCTAssertFalse(manager.isWorking)
        XCTAssertNil(try fixture.savedObject()["deviceToken"])
    }

    func testLegacyCodeErrorRemainsAvailableForDeepLinkAndStatusUI() async {
        let fixture = LicenseLifecycleFixture()
        let manager = fixture.makeManager()
        defer { manager.stopMonitoring() }
        let result = await manager.activate(input: "XNK1-OLD-OFFLINE-CODE")
        guard case .failure(let reason) = result else { return XCTFail("旧码应提示迁移") }
        XCTAssertTrue(reason.contains("迁移"))
        XCTAssertEqual(manager.lastError, reason, "deep link没有局部message，必须保留管理器错误给UI")
        manager.refresh()
        XCTAssertEqual(manager.lastError, reason, "授权页onAppear刷新后也必须保留迁移原因")
        XCTAssertFalse(manager.state.allowsAccess)
    }

    func testEmptyCodeErrorIsNotLostDuringStateRefresh() async {
        let fixture = LicenseLifecycleFixture()
        let manager = fixture.makeManager()
        defer { manager.stopMonitoring() }
        let result = await manager.activate(input: " \n ")
        guard case .failure(let reason) = result else { return XCTFail("空码应失败") }
        XCTAssertEqual(manager.lastError, reason)
        manager.refresh()
        XCTAssertEqual(manager.lastError, reason)
    }

    func testFailedNoteSaveStillAllowsExportOfLatestMemoryContent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xnook-license-note-audit-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("notes.json")
        let original = NotesManager.Note(title: "Audit note", content: "saved before expiry")
        let originalData = try JSONEncoder().encode([original])
        try originalData.write(to: source)
        let manager = NotesManager(storageURL: source, saveDelay: 60, writeData: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        manager.selectNote(original)
        manager.updateCurrentNoteContent("unsaved text at license expiry")
        XCTAssertFalse(manager.flushPendingChanges())
        XCTAssertFalse(manager.prepareForTermination())
        let destination = directory.appendingPathComponent("latest.md")
        try manager.exportNote(id: original.id, to: destination, format: .markdown)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "unsaved text at license expiry")
        XCTAssertEqual(try Data(contentsOf: source), originalData)
        XCTAssertEqual(manager.currentNote?.content, "unsaved text at license expiry")
    }

    private func waitUntilIdle(_ manager: LicenseManager) async {
        let deadline = Date().addingTimeInterval(1)
        while manager.isWorking, Date() < deadline { await Task.yield() }
        XCTAssertFalse(manager.isWorking)
    }
}

private final class LicenseLifecycleStore: LicenseCredentialStore {
    var data: Data?
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
    func delete() throws { data = nil }
}

private actor LicenseLifecycleTransport: SoftwareLicenseTransport {
    private var response: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var observer: CheckedContinuation<Void, Never>?
    private var request: URLRequest?
    private var count = 0
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        count += 1
        return try await withCheckedThrowingContinuation { continuation in
            response = continuation
            observer?.resume(); observer = nil
        }
    }
    func waitUntilRequested() async {
        if response != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func requestCount() -> Int { count }
    func complete(data: Data, status: Int = 200) {
        response?.resume(returning: (data, HTTPURLResponse(url: request!.url!, statusCode: status, httpVersion: nil, headerFields: nil)!))
        response = nil
    }
}

@MainActor
private final class LicenseLifecycleFixture {
    let now = Date().timeIntervalSince1970
    let device = String(repeating: "a", count: 64)
    let key = Curve25519.Signing.PrivateKey()
    let store = LicenseLifecycleStore()
    let transport = LicenseLifecycleTransport()
    let notifications = NotificationCenter()
    var simulatedNow: Date?
    func makeManager() -> LicenseManager {
        LicenseManager(session: SoftwareLicenseSession(productId: "xnook", deviceId: device, deviceName: "Audit fixture",
            publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
            api: SoftwareLicenseAPI(baseURL: URL(string: "https://license-audit.invalid")!, transport: transport), store: store),
            clock: { [self] in simulatedNow ?? Date() }, workspaceNotifications: notifications)
    }
    func savedObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(store.data)) as? [String: Any])
    }
    func responseData(kind: String = "lifetime", entitlement: TimeInterval? = nil) throws -> Data {
        let payload: [String: Any] = ["version": 1, "productId": "xnook", "deviceId": device,
            "licenseId": "audit-license", "kind": kind, "issuedAt": now, "expiresAt": now + 600,
            "entitlementExpiresAt": entitlement as Any? ?? NSNull()]
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let segment = base64URL(try JSONSerialization.data(withJSONObject: payload))
        let lease = "MSL1.\(segment).\(base64URL(try key.signature(for: Data("MSL1.\(segment)".utf8))))"
        return try JSONSerialization.data(withJSONObject: ["lease": lease, "deviceToken": "audit-token"])
    }
}
