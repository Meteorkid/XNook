import XCTest
@testable import XNook

@MainActor
final class FocusPendingTaskTests: XCTestCase {
    func testStartIsIdempotentWhileActiveAndAfterEndingAndReload() throws {
        let fixture = try PendingFocusFixture()
        let manager = FocusSessionManager(userDefaults: fixture.defaults)
        let id = UUID()
        XCTAssertEqual(manager.startPendingTask(id: id, title: "Imported task"), .started(id))
        XCTAssertEqual(manager.activeSession?.originPendingTaskID, id)
        XCTAssertEqual(manager.startedPendingTaskIDs, [id])
        XCTAssertEqual(manager.startPendingTask(id: id, title: "Changed title"), .alreadyStarted(id))
        XCTAssertEqual(manager.activeSession?.title, "Imported task")
        XCTAssertTrue(manager.end())
        XCTAssertEqual(manager.startPendingTask(id: id, title: "Retry after ending"), .alreadyStarted(id))
        XCTAssertNil(manager.activeSession)
        let reloaded = FocusSessionManager(userDefaults: fixture.defaults)
        XCTAssertEqual(reloaded.startPendingTask(id: id, title: "Reload"), .alreadyStarted(id))
        XCTAssertEqual(reloaded.history.count, 1)
        XCTAssertEqual(reloaded.startedPendingTaskIDs, [id])
    }

    func testExistingOtherTaskIsNeverReturnedAsImportedSuccess() throws {
        let fixture = try PendingFocusFixture()
        let manager = FocusSessionManager(userDefaults: fixture.defaults)
        let existing = try XCTUnwrap(manager.start(title: "Already working"))
        XCTAssertEqual(manager.startPendingTask(id: UUID(), title: "Imported"), .activeTaskConflict)
        XCTAssertEqual(manager.activeSession?.id, existing.id)
        XCTAssertEqual(manager.startedPendingTaskIDs, [])
    }

    func testNormalHistoricalIdentityCollisionCannotBeReused() throws {
        let fixture = try PendingFocusFixture()
        let manager = FocusSessionManager(userDefaults: fixture.defaults)
        let existing = try XCTUnwrap(manager.start(title: "Manual"))
        XCTAssertTrue(manager.end())
        XCTAssertEqual(manager.startPendingTask(id: existing.id, title: "Imported"), .identifierConflict)
        XCTAssertNil(manager.activeSession)
        XCTAssertEqual(manager.history.first?.title, "Manual")
    }

    func testUnknownStorageReturnsUnknownOriginsAndRefusesStart() throws {
        let fixture = try PendingFocusFixture()
        let original = Data("broken history".utf8)
        fixture.defaults.set(original, forKey: "nookflow.sessions")
        let manager = FocusSessionManager(userDefaults: fixture.defaults)
        XCTAssertNil(manager.startedPendingTaskIDs)
        XCTAssertEqual(manager.startPendingTask(id: UUID(), title: "Imported"), .storageUnavailable)
        XCTAssertEqual(fixture.defaults.data(forKey: "nookflow.sessions"), original)
    }

    func testWriteThenThrowRequiresReloadAndDoesNotDuplicate() throws {
        let fixture = try PendingFocusFixture()
        let id = UUID()
        let manager = FocusSessionManager(userDefaults: fixture.defaults, writeData: { data in
            fixture.defaults.set(data, forKey: "nookflow.sessions")
            throw CocoaError(.fileWriteUnknown)
        })
        XCTAssertEqual(manager.startPendingTask(id: id, title: "Uncertain write"), .storageUnavailable)
        XCTAssertNil(manager.activeSession)
        XCTAssertNil(manager.startedPendingTaskIDs)
        XCTAssertTrue(manager.retryLoadingStorage())
        XCTAssertEqual(manager.startPendingTask(id: id, title: "Retry"), .alreadyStarted(id))
        XCTAssertEqual(manager.activeSession?.title, "Uncertain write")
    }

    func testInvalidTitlesNeverCreateTasks() throws {
        let fixture = try PendingFocusFixture()
        let manager = FocusSessionManager(userDefaults: fixture.defaults)
        for title in ["", " \n", String(repeating: "字", count: 501)] {
            XCTAssertEqual(manager.startPendingTask(id: UUID(), title: title), .invalidTask)
        }
        XCTAssertNil(fixture.defaults.object(forKey: "nookflow.sessions"))
    }

    func testLegacyRecordsWithoutOriginRemainReadable() throws {
        let fixture = try PendingFocusFixture()
        let original = FocusSessionManager(userDefaults: fixture.defaults)
        let task = try XCTUnwrap(original.start(title: "Legacy"))
        let data = try XCTUnwrap(fixture.defaults.data(forKey: "nookflow.sessions"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var active = try XCTUnwrap(json["activeSession"] as? [String: Any])
        active.removeValue(forKey: "originPendingTaskID")
        json["activeSession"] = active
        fixture.defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "nookflow.sessions")
        let reloaded = FocusSessionManager(userDefaults: fixture.defaults)
        XCTAssertNil(reloaded.storageError)
        XCTAssertEqual(reloaded.activeSession?.id, task.id)
        XCTAssertNil(reloaded.activeSession?.originPendingTaskID)
        XCTAssertEqual(reloaded.startedPendingTaskIDs, [])
    }

    func testLegacyOriginMappingPreservesHistoryAndReturnsActualSessionIdentity() throws {
        let fixture = try PendingFocusFixture()
        let session = FocusSession(id: UUID(), title: "Invalid origin", eventIdentifier: nil,
            startedAt: Date(), scheduledEndAt: nil, endedAt: nil, state: .active,
            linkedNote: nil, linkedFiles: [], originPendingTaskID: UUID())
        let data = try JSONEncoder().encode(FocusSessionStore(activeSession: session, history: []))
        fixture.defaults.set(data, forKey: "nookflow.sessions")
        let manager = FocusSessionManager(userDefaults: fixture.defaults)
        XCTAssertNil(manager.storageError)
        XCTAssertEqual(manager.activeSession, session)
        let origin = try XCTUnwrap(session.originPendingTaskID)
        XCTAssertEqual(manager.startedPendingTaskIDs, [origin])
        XCTAssertEqual(manager.startPendingTask(id: origin, title: "不覆盖旧标题"), .alreadyStarted(session.id))
        XCTAssertEqual(fixture.defaults.data(forKey: "nookflow.sessions"), data)
    }
}

@MainActor
private final class PendingFocusFixture {
    let suite = "XNook.FocusPendingTask.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws { defaults = try XCTUnwrap(UserDefaults(suiteName: suite)) }
    deinit { defaults.removePersistentDomain(forName: suite) }
}
