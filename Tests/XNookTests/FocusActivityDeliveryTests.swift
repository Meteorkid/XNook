import XCTest
@testable import XNook

@MainActor
final class FocusActivityDeliveryTests: XCTestCase {
    func testCompletionIsDeliveredOnceAfterStoreAcceptsEndedSession() throws {
        let suite = "XNook.FocusActivity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var stored: Data?
        var delivered: [FocusSession] = []
        var storedWhenDelivered: Data?
        let manager = FocusSessionManager(userDefaults: defaults, writeData: { stored = $0 }, onSessionEnded: {
            delivered.append($0)
            storedWhenDelivered = stored
        })
        let started = try XCTUnwrap(manager.start(title: "完成测试"))
        XCTAssertTrue(manager.end())
        XCTAssertTrue(manager.end())
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.id, started.id)
        XCTAssertEqual(delivered.first?.state, .ended)
        let accepted = try JSONDecoder().decode(FocusSessionStore.self, from: XCTUnwrap(storedWhenDelivered))
        XCTAssertNil(accepted.activeSession)
        XCTAssertEqual(accepted.history.first?.id, started.id)
    }

    func testFailedEndDoesNotPublishCompletionOrChangeActiveSession() throws {
        let suite = "XNook.FocusActivity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var reject = false
        var delivered = 0
        let manager = FocusSessionManager(userDefaults: defaults, writeData: { _ in
            if reject { throw CocoaError(.fileWriteNoPermission) }
        }, onSessionEnded: { _ in delivered += 1 })
        let started = try XCTUnwrap(manager.start(title: "尚未保存"))
        reject = true
        XCTAssertFalse(manager.end())
        XCTAssertEqual(manager.activeSession?.id, started.id)
        XCTAssertTrue(manager.history.isEmpty)
        XCTAssertEqual(delivered, 0)
    }

    func testEndingWithoutActiveTaskDoesNotPublishCompletion() throws {
        let suite = "XNook.FocusActivity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = FocusSessionManager(userDefaults: defaults, onSessionEnded: { _ in
            XCTFail("没有任务时不能发布完成提示")
        })
        XCTAssertTrue(manager.end())
    }
}
