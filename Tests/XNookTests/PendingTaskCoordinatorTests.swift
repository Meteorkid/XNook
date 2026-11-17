import XCTest
@testable import XNook

@MainActor
final class PendingTaskCoordinatorTests: XCTestCase {
    func testRestartClearsConfirmedReceiptAndLateStartStillSucceedsIdempotently() async throws {
        let fixture = try WorkflowFixture()
        await fixture.coordinator.prepare()
        let added = await fixture.coordinator.add(title: "Capture")
        XCTAssertTrue(added)
        let task = try XCTUnwrap(fixture.pending.items.first)
        let started = await fixture.coordinator.start(id: task.id)
        XCTAssertTrue(started)
        XCTAssertEqual(fixture.pending.items.first?.state, .handoff)
        XCTAssertTrue(fixture.coordinator.visibleTasks.isEmpty)
        XCTAssertFalse(fixture.coordinator.needsRecovery)

        let restored = fixture.restoredCoordinator()
        await restored.prepare()
        XCTAssertTrue(restored.pending.items.isEmpty)
        let replay = await restored.start(id: task.id)
        XCTAssertTrue(replay, "凭据已核对清理时，迟到的重复开始仍应确认同一任务")
        XCTAssertEqual(restored.focus.activeSession?.id, task.id)
        XCTAssertTrue(restored.focus.history.isEmpty)
        let imported = await restored.importTasks(data: try importData(task))
        XCTAssertTrue(imported)
        XCTAssertEqual(restored.importResults.map(\.outcome), [.duplicate])
        XCTAssertTrue(restored.pending.items.isEmpty)
    }

    func testEndedTaskIsNotReactivatedByRetryOrReimport() async throws {
        let fixture = try WorkflowFixture()
        await fixture.coordinator.prepare()
        _ = await fixture.coordinator.add(title: "Capture")
        let task = try XCTUnwrap(fixture.pending.items.first)
        _ = await fixture.coordinator.start(id: task.id)
        XCTAssertTrue(fixture.focus.end())
        let restored = fixture.restoredCoordinator()
        await restored.prepare()
        let replay = await restored.start(id: task.id)
        XCTAssertTrue(replay)
        XCTAssertNil(restored.focus.activeSession)
        XCTAssertEqual(restored.focus.history.count, 1)
        _ = await restored.importTasks(data: try importData(task))
        XCTAssertEqual(restored.importResults.map(\.outcome), [.duplicate])
    }

    func testFailedHandoffNeverCallsFocusAndReloadPreservesInput() async throws {
        for mode in [WorkflowMemory.Mode.before, .after] {
            let fixture = try WorkflowFixture()
            await fixture.coordinator.prepare()
            _ = await fixture.coordinator.add(title: "Preserve capture")
            let task = try XCTUnwrap(fixture.pending.items.first)
            await fixture.memory.setMode(mode)
            let result = await fixture.coordinator.start(id: task.id)
            XCTAssertFalse(result)
            XCTAssertEqual(fixture.focusWriter.writes, 0)
            XCTAssertNil(fixture.focus.activeSession)
            XCTAssertEqual(fixture.pending.items.first?.title, task.title)
            XCTAssertNotNil(fixture.pending.storageError)
            await fixture.memory.setMode(.normal)
            await fixture.coordinator.retryStorage()
            XCTAssertEqual(fixture.pending.items.first?.state, .pending)
            let retried = await fixture.coordinator.start(id: task.id)
            XCTAssertTrue(retried)
            XCTAssertEqual(fixture.focus.activeSession?.id, task.id)
        }
    }

    func testUncertainFocusWriteUsesStoredReceiptDuringReload() async throws {
        for mode in [FocusWriter.Mode.before, .after] {
            let fixture = try WorkflowFixture()
            await fixture.coordinator.prepare()
            _ = await fixture.coordinator.add(title: "Recover start")
            let task = try XCTUnwrap(fixture.pending.items.first)
            fixture.focusWriter.mode = mode
            let started = await fixture.coordinator.start(id: task.id)
            XCTAssertFalse(started)
            XCTAssertEqual(fixture.pending.items.first?.state, .handoff)
            XCTAssertNil(fixture.focus.startedPendingTaskIDs)
            XCTAssertTrue(fixture.coordinator.needsRecovery)
            fixture.focusWriter.mode = .normal
            await fixture.coordinator.retryStorage()
            if mode == .before {
                XCTAssertEqual(fixture.pending.items.first?.state, .pending)
                XCTAssertNil(fixture.focus.activeSession)
            } else {
                XCTAssertTrue(fixture.pending.items.isEmpty)
                XCTAssertEqual(fixture.focus.activeSession?.id, task.id)
            }
            let retried = await fixture.coordinator.start(id: task.id)
            XCTAssertTrue(retried)
            XCTAssertEqual(fixture.focus.activeSession?.id, task.id)
            XCTAssertTrue(fixture.focus.history.isEmpty)
        }
    }

    func testOtherActiveTaskDoesNotConsumePendingIntent() async throws {
        let fixture = try WorkflowFixture()
        await fixture.coordinator.prepare()
        _ = await fixture.coordinator.add(title: "Waiting")
        let pending = try XCTUnwrap(fixture.pending.items.first)
        let active = try XCTUnwrap(fixture.focus.start(title: "Existing"))
        let before = await fixture.memory.read()
        let started = await fixture.coordinator.start(id: pending.id)
        XCTAssertFalse(started)
        let after = await fixture.memory.read()
        XCTAssertEqual(after, before)
        XCTAssertEqual(fixture.pending.items.first?.state, .pending)
        XCTAssertEqual(fixture.focus.activeSession?.id, active.id)
    }

    func testMissingFocusAfterRestartRestoresCompleteCapture() async throws {
        let fixture = try WorkflowFixture()
        await fixture.coordinator.prepare()
        _ = await fixture.coordinator.add(title: "Original title")
        let task = try XCTUnwrap(fixture.pending.items.first)
        _ = await fixture.coordinator.start(id: task.id)
        fixture.defaults.removeObject(forKey: "nookflow.sessions")
        let restored = fixture.restoredCoordinator()
        await restored.prepare()
        XCTAssertEqual(restored.visibleTasks.map(\.id), [task.id])
        XCTAssertEqual(restored.pending.items.first?.title, task.title)
        XCTAssertEqual(restored.pending.items.first?.source, task.source)
        XCTAssertEqual(restored.pending.items.first?.externalID, task.externalID)
        XCTAssertEqual(restored.pending.items.first?.state, .pending)
    }

    func testUnreadableFocusCannotConfirmImportOrClearReceipt() async throws {
        let fixture = try WorkflowFixture()
        await fixture.coordinator.prepare()
        _ = await fixture.coordinator.add(title: "Original")
        let task = try XCTUnwrap(fixture.pending.items.first)
        try await fixture.pending.markHandoff(id: task.id)
        fixture.defaults.set("wrong type", forKey: "nookflow.sessions")
        XCTAssertFalse(fixture.focus.retryLoadingStorage())
        let original = await fixture.memory.read()
        let imported = await fixture.coordinator.importTasks(data: try importData(task))
        XCTAssertFalse(imported)
        XCTAssertTrue(fixture.coordinator.importResults.isEmpty)
        await fixture.coordinator.retryStorage()
        let after = await fixture.memory.read()
        XCTAssertEqual(after, original)
        XCTAssertEqual(fixture.pending.items.first?.state, .handoff)
        XCTAssertEqual(fixture.coordinator.visibleTasks.count, 1)
    }

    func testRecoverySaveFailureKeepsReceiptUntilExplicitReload() async throws {
        let fixture = try WorkflowFixture()
        await fixture.coordinator.prepare()
        _ = await fixture.coordinator.add(title: "Confirmed")
        let task = try XCTUnwrap(fixture.pending.items.first)
        _ = await fixture.coordinator.start(id: task.id)
        let original = await fixture.memory.read()
        await fixture.memory.setMode(.before)
        let restored = fixture.restoredCoordinator()
        await restored.prepare()
        XCTAssertEqual(restored.pending.items.first?.state, .handoff)
        XCTAssertNotNil(restored.pending.storageError)
        let after = await fixture.memory.read()
        XCTAssertEqual(after, original)
        await fixture.memory.setMode(.normal)
        await restored.retryStorage()
        XCTAssertTrue(restored.pending.items.isEmpty)
        XCTAssertEqual(restored.focus.activeSession?.id, task.id)
    }

    func testActionsWaitForInitialRecoveryInsteadOfRacingIt() async throws {
        let fixture = try WorkflowFixture()
        await fixture.pending.waitUntilLoaded()
        let task = try await fixture.pending.add(title: "Previous interrupted start")
        try await fixture.pending.markHandoff(id: task.id)
        let earlyAdd = await fixture.coordinator.add(title: "Before recovery")
        XCTAssertFalse(earlyAdd, "自动恢复完成前不应允许新操作占用存储")
        await fixture.coordinator.prepare()
        XCTAssertEqual(fixture.pending.items.map(\.id), [task.id])
        XCTAssertEqual(fixture.pending.items.first?.state, .pending)
        let laterAdd = await fixture.coordinator.add(title: "After recovery")
        XCTAssertTrue(laterAdd)
    }

    func testAnotherTaskStartingDuringHandoffDoesNotGetOverwritten() async throws {
        let fixture = try WorkflowFixture()
        await fixture.coordinator.prepare()
        _ = await fixture.coordinator.add(title: "Waiting")
        let task = try XCTUnwrap(fixture.pending.items.first)
        await fixture.memory.holdNextWrite()
        let start = Task { await fixture.coordinator.start(id: task.id) }
        var didWait = false
        for _ in 0..<500 {
            if await fixture.memory.isWaiting { didWait = true; break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(didWait)
        let other = try XCTUnwrap(fixture.focus.start(title: "Calendar task"))
        await fixture.memory.releaseWrite()
        let result = await start.value
        XCTAssertFalse(result)
        XCTAssertEqual(fixture.focus.activeSession?.id, other.id)
        XCTAssertEqual(fixture.pending.items.first?.state, .handoff)
        XCTAssertTrue(fixture.focus.end())
        let retried = await fixture.coordinator.start(id: task.id)
        XCTAssertTrue(retried)
        XCTAssertEqual(fixture.focus.activeSession?.id, task.id)
        XCTAssertEqual(fixture.focus.history.map(\.id), [other.id])
    }

    private func importData(_ task: PendingTask) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 1, "tasks": [
            ["source": task.source, "id": task.externalID, "title": "Changed title"]
        ]])
    }
}

private actor WorkflowMemory {
    enum Mode { case normal, before, after }
    private var data: Data?
    private var mode = Mode.normal
    private var hold = false
    private var waiting: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { waiting != nil }
    func read() -> Data? { data }
    func setMode(_ value: Mode) { mode = value }
    func holdNextWrite() { hold = true }
    func releaseWrite() { waiting?.resume(); waiting = nil }
    func write(_ data: Data) async throws {
        if hold { hold = false; await withCheckedContinuation { waiting = $0 } }
        if mode == .before { throw CocoaError(.fileWriteUnknown) }
        self.data = data
        if mode == .after { throw CocoaError(.fileWriteUnknown) }
    }
}

@MainActor
private final class FocusWriter {
    enum Mode { case normal, before, after }
    let defaults: UserDefaults
    var mode = Mode.normal
    var writes = 0
    init(_ defaults: UserDefaults) { self.defaults = defaults }
    func write(_ data: Data) throws {
        writes += 1
        if mode == .before { throw CocoaError(.fileWriteUnknown) }
        defaults.set(data, forKey: "nookflow.sessions")
        if mode == .after { throw CocoaError(.fileWriteUnknown) }
    }
}

@MainActor
private final class WorkflowFixture {
    let suite = "XNook.InboxWorkflow.\(UUID().uuidString)"
    let defaults: UserDefaults
    let memory = WorkflowMemory()
    let focusWriter: FocusWriter
    let pending: PendingTaskManager
    let focus: FocusSessionManager
    let coordinator: PendingTaskCoordinator

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        focusWriter = FocusWriter(defaults)
        focus = FocusSessionManager(userDefaults: defaults, writeData: focusWriter.write)
        pending = Self.makePending(memory)
        coordinator = PendingTaskCoordinator(pending: pending, focus: focus)
    }

    func restoredCoordinator() -> PendingTaskCoordinator {
        PendingTaskCoordinator(pending: Self.makePending(memory), focus: FocusSessionManager(userDefaults: defaults))
    }

    private static func makePending(_ memory: WorkflowMemory) -> PendingTaskManager {
        PendingTaskManager(storageURL: URL(fileURLWithPath: "/unused-injected-store/pending.json"),
            readData: { _ in await memory.read() }, writeData: { data, _ in try await memory.write(data) })
    }

    deinit { defaults.removePersistentDomain(forName: suite) }
}
