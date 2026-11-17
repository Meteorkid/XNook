import XCTest
@testable import XNook

@MainActor
final class TaskWorkflowIntegrationTests: XCTestCase {
    func testInboxResourcesBudgetRestartReminderAndHistoryStayConnected() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let inbox = f.makeInbox()
        await inbox.prepare()
        let added = await inbox.add(title: "整理项目资料")
        XCTAssertTrue(added)
        let task = try XCTUnwrap(inbox.pending.items.first)
        let started = await inbox.start(id: task.id)
        XCTAssertTrue(started)
        guard case .added(let linkID) = inbox.focus.addTaskURL(
            urlString: "HTTPS://EXAMPLE.COM:443/guide", title: "手工资料标题", to: task.id
        ) else { return XCTFail("链接应保存在已开始的收件箱任务上") }
        XCTAssertTrue(inbox.focus.setTimeBudget(minutes: 25, for: task.id, now: f.time))
        let expected = try XCTUnwrap(inbox.focus.activeSession)

        let restored = f.makeInbox()
        await restored.prepare()
        XCTAssertTrue(restored.pending.items.isEmpty)
        XCTAssertEqual(restored.focus.activeSession, expected)
        XCTAssertEqual(restored.focus.activeSession?.originPendingTaskID, task.id)
        let monitor = f.makeMonitor(focus: restored.focus)
        defer { monitor.shutdown() }
        monitor.refresh()
        XCTAssertNil(f.activities.current)

        f.time = try XCTUnwrap(expected.scheduledEndAt)
        monitor.resynchronize()
        XCTAssertNil(f.activities.current, "交互保护期间只排队，不抢占展示")
        XCTAssertEqual(f.activities.pendingCount, 1)
        XCTAssertEqual(restored.focus.activeSession, expected, "到时不能自动结束或修改资料")
        f.canPresent = true
        f.activities.refreshPresentation()
        let event = try XCTUnwrap(f.activities.current)
        XCTAssertEqual(event.kind, .deadline)
        XCTAssertEqual(event.title, L10n.flowBudgetDue(task.title))
        XCTAssertEqual(f.presented.count, 1)
        f.activities.dismissCurrent(event)

        monitor.shutdown()
        let restartedMonitor = f.makeMonitor(focus: restored.focus)
        defer { restartedMonitor.shutdown() }
        restartedMonitor.refresh()
        XCTAssertNil(f.activities.current)
        XCTAssertEqual(f.presented.count, 1, "重启监控器后不能重复提醒同一计划")
        XCTAssertTrue(restored.focus.end())
        restartedMonitor.refresh()

        let history = f.makeInbox()
        await history.prepare()
        XCTAssertNil(history.focus.activeSession)
        let saved = try XCTUnwrap(history.focus.history.first)
        XCTAssertEqual(saved.originPendingTaskID, task.id)
        XCTAssertEqual(saved.taskURLs.first?.id, linkID)
        XCTAssertEqual(saved.taskURLs.first?.title, "手工资料标题")
        XCTAssertEqual(saved.scheduledEndAt, expected.scheduledEndAt)
        let replay = await history.start(id: task.id)
        XCTAssertTrue(replay)
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "tasks": [
            ["source": task.source, "id": task.externalID, "title": "重复导入不能覆盖原任务"]
        ]])
        let imported = await history.importTasks(data: data)
        XCTAssertTrue(imported)
        XCTAssertEqual(history.importResults.map(\.outcome), [.duplicate])
        XCTAssertTrue(history.pending.items.isEmpty)
        XCTAssertEqual(history.focus.history, [saved])
        XCTAssertNil(history.focus.activeSession)
    }

    func testUncertainBudgetWritePausesRemindersUntilStoredPlanIsReconciled() throws {
        for writesBeforeFailure in [false, true] {
            let f = try Fixture()
            defer { f.cleanUp() }
            let originalTime = f.time
            var shouldFail = false
            let focus = FocusSessionManager(userDefaults: f.defaults, writeData: { data in
                if shouldFail && !writesBeforeFailure { throw CocoaError(.fileWriteNoPermission) }
                f.defaults.set(data, forKey: "nookflow.sessions")
                if shouldFail { throw CocoaError(.fileWriteNoPermission) }
            })
            let task = try XCTUnwrap(focus.start(title: "重试预算"))
            guard case .added = focus.addTaskURL(urlString: "https://example.com/", title: "保留资料", to: task.id)
            else { return XCTFail("链接应保存成功") }
            XCTAssertTrue(focus.setTimeBudget(minutes: 25, for: task.id, now: originalTime))
            let original = focus.activeSession
            let monitor = f.makeMonitor(focus: focus)
            defer { monitor.shutdown() }
            monitor.refresh()
            shouldFail = true
            XCTAssertFalse(focus.setTimeBudget(minutes: 1, for: task.id, now: originalTime))
            XCTAssertEqual(focus.activeSession, original)
            XCTAssertNotNil(focus.storageError)
            f.time = originalTime.addingTimeInterval(60)
            monitor.resynchronize()
            XCTAssertEqual(f.activities.pendingCount, 0)
            XCTAssertNil(f.defaults.object(forKey: FocusDeadlineMonitor.notifiedKey))

            shouldFail = false
            XCTAssertTrue(focus.retryLoadingStorage())
            XCTAssertEqual(focus.activeSession?.taskURLs, original?.taskURLs)
            let expectedDeadline = originalTime.addingTimeInterval(writesBeforeFailure ? 60 : 1500)
            XCTAssertEqual(focus.activeSession?.scheduledEndAt, expectedDeadline)
            monitor.refresh()
            XCTAssertEqual(f.activities.pendingCount, writesBeforeFailure ? 1 : 0)
            f.time = expectedDeadline
            monitor.resynchronize()
            XCTAssertEqual(f.activities.pendingCount, 1)
            f.canPresent = true
            f.activities.refreshPresentation()
            XCTAssertEqual(f.presented.count, 1)
            XCTAssertEqual(f.activities.current?.kind, .deadline)
        }
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let suiteName = "XNook.WorkflowIntegration.\(UUID().uuidString)"
        let defaults: UserDefaults
        var time = Date(timeIntervalSince1970: 1_700_000_000)
        var canPresent = false
        var presented: [PanelActivityEvent] = []
        lazy var activities = PanelActivityCoordinator(now: { [unowned self] in time },
            schedule: { _, _ in {} }, isPresentationAllowed: { [unowned self] in canPresent },
            onPresent: { [unowned self] in presented.append($0) })

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("XNookWorkflow-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        }
        func makeInbox() -> PendingTaskCoordinator {
            PendingTaskCoordinator(pending: PendingTaskManager(storageURL: directory.appendingPathComponent("pending.json")),
                focus: FocusSessionManager(userDefaults: defaults))
        }
        func makeMonitor(focus: FocusSessionManager) -> FocusDeadlineMonitor {
            FocusDeadlineMonitor(defaults: defaults, currentSession: { [weak focus] in
                guard let focus, focus.storageError == nil else { return nil }
                return focus.activeSession
            }, notificationsEnabled: { true }, emit: { [unowned self] in activities.enqueue($0) },
                now: { [unowned self] in time }, schedule: { _, _ in {} })
        }
        func cleanUp() {
            activities.shutdown()
            defaults.removePersistentDomain(forName: suiteName)
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("无法清理隔离测试目录：\(error)") }
        }
    }
}
