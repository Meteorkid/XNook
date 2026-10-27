import XCTest
import CryptoKit
import MeteorLicenseCore
@testable import XNook

@MainActor
final class LicenseManagerTests: XCTestCase {
    func testResidentExpiryClosesAccessWithoutRestartOrOpeningSettings() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let device = String(repeating: "a", count: 64)
        let now = Date().timeIntervalSince1970
        let payload: [String: Any] = ["version": 1, "productId": "xnook", "deviceId": device,
            "licenseId": "resident-test", "kind": "monthly", "issuedAt": now,
            "expiresAt": now + 0.3, "entitlementExpiresAt": now + 0.3]
        let body = base64URL(try JSONSerialization.data(withJSONObject: payload))
        let receipt = "MSL1.\(body).\(base64URL(try key.signature(for: Data("MSL1.\(body)".utf8))))"
        let transport = LicenseTestTransport(data: try JSONSerialization.data(withJSONObject: ["lease": receipt, "deviceToken": "test-token"]))
        let session = SoftwareLicenseSession(productId: "xnook", deviceId: device, deviceName: "Test",
            publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
            api: SoftwareLicenseAPI(baseURL: URL(string: "https://example.com")!, transport: transport), store: LicenseTestStore())
        let manager = LicenseManager(session: session)
        defer { manager.stopMonitoring() }
        let locked = expectation(description: "到期定时器主动锁定常驻应用")
        var transitions: [Bool] = []
        manager.onAccessChange = { allowed in
            transitions.append(allowed)
            if !allowed { locked.fulfill() }
        }
        let activation = await manager.activate(input: "TEST-CODE")
        XCTAssertEqual(activation, .success)
        XCTAssertTrue(manager.state.allowsAccess)
        await fulfillment(of: [locked], timeout: 2)
        XCTAssertEqual(transitions, [true, false])
        XCTAssertEqual(manager.state, .expired)
    }

    func testMissingPublicKeyDoesNotOfferAnUnverifiedLocalTrial() {
        let session = SoftwareLicenseSession(productId: "xnook", deviceId: String(repeating: "a", count: 64), deviceName: "Test",
            publicKeyBase64: nil, api: SoftwareLicenseAPI(baseURL: URL(string: "https://example.com")!,
                transport: LicenseTestTransport(data: Data())), store: LicenseTestStore())
        let manager = LicenseManager(session: session)
        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertFalse(manager.state.allowsAccess)
        XCTAssertNil(manager.remainingTrialDays)
    }

    func testLicenseStopPreventsFurtherMediaPolling() async {
        var reads = 0
        let media = MediaManager(startMonitoring: false, infoProvider: { reads += 1; return [:] })
        await media.refreshNowPlayingInfo()
        XCTAssertEqual(reads, 1)
        media.stopMonitoring()
        await media.refreshNowPlayingInfo()
        XCTAssertEqual(reads, 1)
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private final class LicenseTestStore: LicenseCredentialStore {
    var data: Data?
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
    func delete() throws { data = nil }
}

private struct LicenseTestTransport: SoftwareLicenseTransport {
    let data: Data
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
