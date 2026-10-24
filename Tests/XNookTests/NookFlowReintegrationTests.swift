import SwiftUI
import XCTest
@testable import XNook

@MainActor
final class NookFlowReintegrationTests: XCTestCase {
    func testMigratedPendingSessionKeepsResourcesAndDeduplicatesInbox() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let task = PendingTask(source: "agent", externalID: "existing", title: "迁移任务", createdAt: Date())
        let legacy = FocusSessionManager(userDefaults: fixture.legacy)
        XCTAssertEqual(legacy.startPendingTask(id: task.id, title: task.title), .started(task.id))
        XCTAssertTrue(legacy.setTimeBudget(minutes: 25, for: task.id))
        XCTAssertTrue(legacy.linkFile(id: UUID(), name: "资料.pdf", icon: "doc", bookmarkData: Data([1])))
        guard case .added = legacy.addTaskURL(urlString: "https://example.com/review", title: "资料", to: task.id)
        else { return XCTFail("历史链接写入失败") }
        let original = fixture.legacy.data(forKey: "nookflow.sessions")
        let migrated = FocusSessionManager(userDefaults: fixture.defaults, legacyUserDefaults: fixture.legacy)
        XCTAssertEqual(migrated.activeSession, legacy.activeSession)
        XCTAssertEqual(fixture.defaults.data(forKey: "nookflow.sessions"), original)
        let pending = PendingTaskManager(storageURL: fixture.directory.appendingPathComponent("pending.json"))
        await pending.waitUntilLoaded()
        let payload = try JSONSerialization.data(withJSONObject: ["version": 1, "tasks": [
            ["source": task.source, "id": task.externalID, "title": "不能覆盖迁移任务"]
        ]])
        let inbox = PendingTaskCoordinator(pending: pending, focus: migrated)
        await inbox.prepare()
        let imported = await inbox.importTasks(data: payload)
        XCTAssertTrue(imported)
        XCTAssertEqual(inbox.importResults.map(\.outcome), [.duplicate])
        XCTAssertTrue(pending.items.isEmpty)
        XCTAssertEqual(migrated.activeSession, legacy.activeSession)
        XCTAssertEqual(fixture.legacy.data(forKey: "nookflow.sessions"), original)
    }

    func testBothFileLinkingAPIsPreserveLimitAndAllowCredentialRepairAtCapacity() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = FocusSessionManager(userDefaults: fixture.defaults)
        let session = try XCTUnwrap(manager.start(title: "兼容文件快照"))
        let snapshots = (0..<60).map { FocusSessionManager.FileSnapshot(id: UUID(), name: "文件\($0)", icon: "doc") }
        XCTAssertTrue(manager.linkFiles(snapshots))
        XCTAssertEqual(manager.activeSession?.linkedFiles.count, FocusSessionManager.linkedFileLimit)
        let original = try XCTUnwrap(manager.activeSession?.linkedFiles.first)
        XCTAssertTrue(manager.end())
        let bookmark = Data([3, 2, 1])
        XCTAssertTrue(manager.linkFiles([
            LinkedFile(id: original.id, name: "不覆盖原名称", icon: "folder", bookmarkData: bookmark),
            LinkedFile(id: UUID(), name: "超出上限", icon: "doc")
        ], to: session.id))
        let stored = try XCTUnwrap(manager.session(id: session.id))
        XCTAssertEqual(stored.linkedFiles.count, FocusSessionManager.linkedFileLimit)
        XCTAssertEqual(stored.linkedFiles.first?.name, original.name)
        XCTAssertEqual(stored.linkedFiles.first?.bookmarkData, bookmark)
        XCTAssertNil(manager.activeSession)
    }

    func testResourceChangesDoNotInvalidateLinkEditButConcurrentLinkEditsDo() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = FocusSessionManager(userDefaults: fixture.defaults)
        let session = try XCTUnwrap(manager.start(title: "链接编辑兼容"))
        guard case .added = manager.addTaskURL(urlString: "https://example.com/old", title: "原链接", to: session.id)
        else { return XCTFail("添加链接失败") }
        let original = try XCTUnwrap(manager.activeSession?.taskURLs.first)
        let resources = fixture.resources(manager: manager)
        let links = TaskLinkCoordinator(manager: manager, openURL: { _ in false })
        XCTAssertTrue(resources.setTimeBudget(minutes: 25, in: session.id))
        XCTAssertTrue(manager.setLinkedNote(LinkedNote(id: UUID(), title: "任务笔记"), for: session.id))
        XCTAssertTrue(links.editTaskURL(original, urlString: original.urlString, title: "新版标题", in: session.id))
        XCTAssertFalse(resources.editTaskURL(original, urlString: original.urlString, title: "过期编辑", in: session.id))
        XCTAssertEqual(resources.errorMessage, L10n.flowWebLinkChanged)
        XCTAssertEqual(manager.activeSession?.taskURLs.first?.title, "新版标题")
        XCTAssertNotNil(manager.activeSession?.scheduledEndAt)
        XCTAssertEqual(manager.activeSession?.linkedNote?.title, "任务笔记")
    }

    func testEndCallbackOnlyRunsAfterSuccessfulCommitAndNeverRepeatsForEmptyEnd() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var fail = false
        var ended: [FocusSession] = []
        let manager = FocusSessionManager(userDefaults: fixture.defaults, writeData: { data in
            if fail { throw CocoaError(.fileWriteNoPermission) }
            fixture.defaults.set(data, forKey: "nookflow.sessions")
        }, onSessionEnded: { session in
            let persisted = try? JSONDecoder().decode(FocusSessionStore.self,
                from: fixture.defaults.data(forKey: "nookflow.sessions") ?? Data())
            XCTAssertNil(persisted?.activeSession)
            XCTAssertEqual(persisted?.history.first, session)
            ended.append(session)
        })
        let session = try XCTUnwrap(manager.start(title: "可靠结束"))
        fail = true
        XCTAssertFalse(manager.end())
        XCTAssertTrue(ended.isEmpty)
        XCTAssertEqual(manager.activeSession, session)
        fail = false
        XCTAssertTrue(manager.retryLoadingStorage())
        XCTAssertTrue(manager.end())
        XCTAssertTrue(manager.end())
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended.first?.id, session.id)
    }

    func testLegacySourceMappingReconcilesHandoffAndReturnsActualSessionWithoutCreatingAnother() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let pending = PendingTaskManager(storageURL: fixture.directory.appendingPathComponent("pending.json"))
        await pending.waitUntilLoaded()
        let task = try await pending.add(title: "已开始的旧待办")
        try await pending.markHandoff(id: task.id)
        let session = FocusSession(id: UUID(), title: "旧格式任务", eventIdentifier: nil,
            startedAt: Date(), scheduledEndAt: nil, endedAt: nil, state: .active,
            linkedNote: nil, linkedFiles: [], originPendingTaskID: task.id)
        let original = try JSONEncoder().encode(FocusSessionStore(activeSession: session, history: []))
        fixture.defaults.set(original, forKey: "nookflow.sessions")
        let manager = FocusSessionManager(userDefaults: fixture.defaults)
        let inbox = PendingTaskCoordinator(pending: pending, focus: manager)
        await inbox.prepare()
        XCTAssertFalse(inbox.hasStorageIssue)
        XCTAssertTrue(pending.items.isEmpty)
        let started = await inbox.start(id: task.id)
        XCTAssertTrue(started)
        XCTAssertEqual(manager.startPendingTask(id: task.id, title: "不替换"), .alreadyStarted(session.id))
        XCTAssertEqual(manager.activeSession, session)
        let payload = try JSONSerialization.data(withJSONObject: ["version": 1, "tasks": [
            ["source": task.source, "id": task.externalID, "title": "不能重建旧任务"]
        ]])
        let imported = await inbox.importTasks(data: payload)
        XCTAssertTrue(imported)
        XCTAssertEqual(inbox.importResults.map(\.outcome), [.duplicate])
        XCTAssertEqual(fixture.defaults.data(forKey: "nookflow.sessions"), original)
        XCTAssertTrue(manager.end())
        XCTAssertEqual(manager.startPendingTask(id: task.id, title: "不重新激活"), .alreadyStarted(session.id))
        XCTAssertNil(manager.activeSession)
        XCTAssertEqual(manager.history.first?.originPendingTaskID, task.id)
    }

    func testConflictingSourceMappingPreservesHistoryAndPendingHandoffWithoutConfirmation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let pending = PendingTaskManager(storageURL: fixture.directory.appendingPathComponent("pending.json"))
        await pending.waitUntilLoaded()
        let task = try await pending.add(title: "保留完整待办")
        try await pending.markHandoff(id: task.id)
        let session = FocusSession(id: UUID(), title: "旧格式任务", eventIdentifier: nil,
            startedAt: Date(), scheduledEndAt: nil, endedAt: nil, state: .active,
            linkedNote: nil, linkedFiles: [], originPendingTaskID: task.id)
        let conflicting = FocusSession(id: UUID(), title: "另一条旧记录", eventIdentifier: nil,
            startedAt: Date(), scheduledEndAt: nil, endedAt: Date(), state: .ended,
            linkedNote: nil, linkedFiles: [], originPendingTaskID: task.id)
        let original = try JSONEncoder().encode(FocusSessionStore(activeSession: session, history: [conflicting]))
        fixture.defaults.set(original, forKey: "nookflow.sessions")
        let manager = FocusSessionManager(userDefaults: fixture.defaults)
        let inbox = PendingTaskCoordinator(pending: pending, focus: manager)
        await inbox.prepare()
        XCTAssertNil(manager.storageError)
        XCTAssertEqual(manager.activeSession, session)
        XCTAssertEqual(manager.history, [conflicting])
        XCTAssertTrue(inbox.hasStorageIssue)
        XCTAssertEqual(pending.items.first?.state, .handoff)
        let started = await inbox.start(id: task.id)
        XCTAssertFalse(started)
        XCTAssertEqual(fixture.defaults.data(forKey: "nookflow.sessions"), original)
        XCTAssertTrue(manager.end(), "来源冲突不能破坏旧版本普通任务操作")
        XCTAssertEqual(manager.history.count, 2)
        XCTAssertNil(manager.startedPendingTaskIDs)
    }

    func testGridSectionsAcceptCoordinatorsWithoutChangingTheirSharedSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = FocusSessionManager(userDefaults: fixture.defaults)
        let resources = fixture.resources(manager: manager)
        let pending = PendingTaskManager(storageURL: fixture.directory.appendingPathComponent("pending.json"))
        let inbox = PendingTaskCoordinator(pending: pending, focus: manager)
        await inbox.prepare()
        let session = try XCTUnwrap(manager.start(title: "共享网格任务"))
        let snapshot = fixture.defaults.data(forKey: "nookflow.sessions")
        for section in [FocusSessionView.Section.currentTask, .recentTasks] {
            let view = FocusSessionView(manager: manager, historyDisplayLimit: 3, trayFileCount: 0,
                onCreateLinkedNote: { false }, onLinkTrayFiles: {}, onEndSession: {},
                section: section, availableHeight: 116, resources: resources, pendingTasks: inbox)
            XCTAssertEqual(view.section, section)
            XCTAssertEqual(view.availableHeight, 116)
            XCTAssertTrue(view.resources === resources)
            XCTAssertTrue(view.pendingTasks === inbox)
            XCTAssertEqual(view.manager.activeSession, session)
        }
        XCTAssertEqual(fixture.defaults.data(forKey: "nookflow.sessions"), snapshot)
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let suiteName = "XNook.Reintegration.\(UUID().uuidString)"
        let defaults: UserDefaults
        let legacy: UserDefaults

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("XNookReintegration-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            legacy = try XCTUnwrap(UserDefaults(suiteName: suiteName + ".legacy"))
        }

        func resources(manager: FocusSessionManager) -> FocusResourceCoordinator {
            FocusResourceCoordinator(manager: manager,
                notes: NotesManager(storageURL: directory.appendingPathComponent("notes.json")),
                tray: TrayManager(storageURL: directory.appendingPathComponent("tray.json"),
                    resolveBookmark: { _ in nil }, makeBookmark: { _ in Data() }), openURL: { _ in false })
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
            legacy.removePersistentDomain(forName: suiteName + ".legacy")
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("清理隔离测试目录失败：\(error)") }
        }
    }
}
