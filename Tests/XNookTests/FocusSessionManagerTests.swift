import XCTest
@testable import XNook

@MainActor
final class FocusSessionManagerTests: XCTestCase {
    /// 每个测试使用独立 suite，避免污染全局 standard 与彼此串扰
    private var suite: UserDefaults!
    private var suiteName: String!
    private static let storageKey = "nookflow.sessions"

    override func setUp() {
        super.setUp()
        suiteName = "TestNookFlow.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        if let name = suiteName {
            suite.removePersistentDomain(forName: name)
        }
        suite = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - 1. 启动会话

    func testStartCreatesActiveSession() throws {
        let manager = FocusSessionManager(userDefaults: suite)
        let session = try XCTUnwrap(manager.start(title: "产品周会", eventIdentifier: "evt-1", scheduledEndAt: Date(timeIntervalSinceNow: 3600)))

        XCTAssertNotNil(manager.activeSession)
        XCTAssertEqual(manager.activeSession?.id, session.id)
        XCTAssertEqual(manager.activeSession?.title, "产品周会")
        XCTAssertEqual(manager.activeSession?.eventIdentifier, "evt-1")
        XCTAssertEqual(manager.activeSession?.state, .active)
        XCTAssertNil(manager.activeSession?.endedAt)
        XCTAssertNil(manager.activeSession?.linkedNote)
        XCTAssertTrue(manager.activeSession?.linkedFiles.isEmpty == true)
        XCTAssertTrue(manager.history.isEmpty)

        // 持久化数据落盘
        XCTAssertNotNil(suite.data(forKey: Self.storageKey))
    }

    // MARK: - 2. 空白标题回退

    func testEmptyTitleFallsBackToDefault() {
        let manager = FocusSessionManager(userDefaults: suite)

        manager.start(title: "")
        XCTAssertEqual(manager.activeSession?.title, FocusSessionManager.defaultTitle)

        manager.end()

        manager.start(title: "   ")
        XCTAssertEqual(manager.activeSession?.title, FocusSessionManager.defaultTitle)
    }

    // MARK: - 3. 结束会话并持久化

    func testEndMovesSessionToHistory() {
        let manager = FocusSessionManager(userDefaults: suite)
        manager.start(title: "任务 A")

        manager.end()

        XCTAssertNil(manager.activeSession)
        XCTAssertEqual(manager.history.count, 1)
        XCTAssertEqual(manager.history.first?.state, .ended)
        XCTAssertNotNil(manager.history.first?.endedAt)
        XCTAssertEqual(manager.history.first?.title, "任务 A")
    }

    // MARK: - 4. 重载后恢复

    func testReloadRestoresActiveSessionAndHistory() {
        let manager1 = FocusSessionManager(userDefaults: suite)
        manager1.start(title: "未结束会话")
        manager1.linkNote(id: UUID(), title: "关联笔记")
        manager1.end()
        manager1.start(title: "新的活跃会话")

        // 用同一 suite 新建 Manager，模拟重启
        let manager2 = FocusSessionManager(userDefaults: suite)

        XCTAssertNotNil(manager2.activeSession)
        XCTAssertEqual(manager2.activeSession?.title, "新的活跃会话")
        XCTAssertEqual(manager2.history.count, 1)
        XCTAssertEqual(manager2.history.first?.title, "未结束会话")
        XCTAssertEqual(manager2.history.first?.linkedNote?.title, "关联笔记")
    }

    // MARK: - 5. 边界（无活跃会话时关联操作不崩溃）

    func testLinkOperationsAreNoOpWhenNoActiveSession() {
        let manager = FocusSessionManager(userDefaults: suite)

        // 无活跃会话时调用关联操作，不应崩溃且不应改变状态
        manager.linkNote(id: UUID(), title: "笔记")
        manager.linkFile(id: UUID(), name: "文件", icon: "doc")
        manager.unlinkFile(id: UUID())

        XCTAssertNil(manager.activeSession)
        XCTAssertTrue(manager.history.isEmpty)
    }

    // MARK: - 6. 重复关联文件去重

    func testDuplicateFileLinkIsDeduplicated() {
        let manager = FocusSessionManager(userDefaults: suite)
        manager.start(title: "任务 B")

        let fileID = UUID()
        manager.linkFile(id: fileID, name: "文件1", icon: "doc")
        manager.linkFile(id: fileID, name: "文件1-重复", icon: "doc")

        XCTAssertEqual(manager.activeSession?.linkedFiles.count, 1)
        XCTAssertEqual(manager.activeSession?.linkedFiles.first?.id, fileID)
        XCTAssertEqual(manager.activeSession?.linkedFiles.first?.name, "文件1")
    }

    // MARK: - 7. 结束会话后快照保留

    func testSnapshotsPreservedAfterEndAndReload() {
        let manager1 = FocusSessionManager(userDefaults: suite)
        manager1.start(title: "带关联的任务")

        let noteID = UUID()
        let fileID = UUID()
        manager1.linkNote(id: noteID, title: "会议笔记")
        manager1.linkFile(id: fileID, name: "设计稿.png", icon: "photo")
        manager1.linkFile(id: UUID(), name: "数据.xlsx", icon: "tablecells")

        // 结束前快照已写入
        XCTAssertEqual(manager1.activeSession?.linkedNote?.id, noteID)
        XCTAssertEqual(manager1.activeSession?.linkedFiles.count, 2)

        manager1.end()

        // 结束后历史记录保留快照
        XCTAssertEqual(manager1.history.first?.linkedNote?.id, noteID)
        XCTAssertEqual(manager1.history.first?.linkedNote?.title, "会议笔记")
        XCTAssertEqual(manager1.history.first?.linkedFiles.count, 2)
        XCTAssertEqual(manager1.history.first?.linkedFiles.first?.name, "设计稿.png")

        // 重载后仍一致（即便原 Manager 状态已变）
        let manager2 = FocusSessionManager(userDefaults: suite)
        XCTAssertEqual(manager2.history.first?.linkedNote?.id, noteID)
        XCTAssertEqual(manager2.history.first?.linkedNote?.title, "会议笔记")
        XCTAssertEqual(manager2.history.first?.linkedFiles.count, 2)
        XCTAssertEqual(manager2.history.first?.linkedFiles.first?.name, "设计稿.png")
    }

    func testManualSessionTrimsTitleAndHasNoCalendarDependency() {
        let manager = FocusSessionManager(userDefaults: suite)
        let session = manager.start(title: "  整理设计资料\n")

        XCTAssertEqual(session?.title, "整理设计资料")
        XCTAssertNil(session?.eventIdentifier)
        XCTAssertNil(session?.scheduledEndAt)
        XCTAssertEqual(FocusSessionManager(userDefaults: suite).activeSession?.id, session?.id)
    }

    func testStartingAnotherTaskPreservesCurrentTaskAndExplainsConflict() {
        let manager = FocusSessionManager(userDefaults: suite)
        let original = manager.start(title: "正在编辑", eventIdentifier: "first")
        let duplicate = manager.start(title: "另一日程", eventIdentifier: "second")

        XCTAssertEqual(duplicate?.id, original?.id)
        XCTAssertEqual(manager.activeSession?.eventIdentifier, "first")
        XCTAssertNotNil(manager.activityMessage)
        manager.end()
        XCTAssertNil(manager.activityMessage)
    }

    func testLegacyFileWithoutBookmarkStillDecodes() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id.uuidString)\",\"name\":\"旧文件\",\"icon\":\"doc\"}".utf8)
        let file = try JSONDecoder().decode(LinkedFile.self, from: data)
        XCTAssertEqual(file.id, id)
        XCTAssertNil(file.bookmarkData)
    }

    func testCorruptedStoreIsNotOverwrittenByAnySessionOperation() {
        let original = Data("{broken session history".utf8)
        suite.set(original, forKey: Self.storageKey)
        let manager = FocusSessionManager(userDefaults: suite)

        XCTAssertNotNil(manager.storageError)
        XCTAssertNil(manager.start(title: "不应覆盖历史"))
        manager.linkNote(id: UUID(), title: "笔记")
        manager.linkFile(id: UUID(), name: "文件", icon: "doc")
        manager.unlinkFile(id: UUID())
        manager.end()

        XCTAssertNil(manager.activeSession)
        XCTAssertTrue(manager.history.isEmpty)
        XCTAssertEqual(suite.data(forKey: Self.storageKey), original)
    }

    func testWrongStorageTypeIsProtected() {
        suite.set("unexpected storage value", forKey: Self.storageKey)
        let manager = FocusSessionManager(userDefaults: suite)

        XCTAssertNotNil(manager.storageError)
        XCTAssertNil(manager.start(title: "新任务"))
        XCTAssertEqual(suite.string(forKey: Self.storageKey), "unexpected storage value")
    }

    func testRetryRestoresRepairedStoreAndAllowsNewTasks() throws {
        suite.set(Data("invalid".utf8), forKey: Self.storageKey)
        let manager = FocusSessionManager(userDefaults: suite)
        XCTAssertNotNil(manager.storageError)

        let cleanStore = FocusSessionStore(activeSession: nil, history: [])
        suite.set(try JSONEncoder().encode(cleanStore), forKey: Self.storageKey)
        manager.retryLoadingStorage()

        XCTAssertNil(manager.storageError)
        XCTAssertNotNil(manager.start(title: "恢复后任务"))
        XCTAssertEqual(FocusSessionManager(userDefaults: suite).activeSession?.title, "恢复后任务")
    }

    func testRetryWithUnrepairedStoreKeepsOriginalData() {
        let original = Data("invalid".utf8)
        suite.set(original, forKey: Self.storageKey)
        let manager = FocusSessionManager(userDefaults: suite)
        manager.retryLoadingStorage()

        XCTAssertNotNil(manager.storageError)
        XCTAssertEqual(suite.data(forKey: Self.storageKey), original)
    }

    func testFailedStartDoesNotPublishAndReloadAllowsRetry() throws {
        var shouldFail = true
        var writes = 0
        let manager = FocusSessionManager(userDefaults: suite, writeData: { [suite] data in
            writes += 1
            if shouldFail { throw CocoaError(.fileWriteNoPermission) }
            suite?.set(data, forKey: Self.storageKey)
        })
        XCTAssertNil(manager.start(title: "失败任务"))
        XCTAssertNil(manager.activeSession)
        XCTAssertTrue(manager.history.isEmpty)
        XCTAssertNil(suite.data(forKey: Self.storageKey))
        shouldFail = false
        XCTAssertNil(manager.start(title: "必须先重新读取"))
        XCTAssertEqual(writes, 1)
        XCTAssertTrue(manager.retryLoadingStorage())
        XCTAssertNotNil(manager.start(title: "恢复后任务"))
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(FocusSessionManager(userDefaults: suite).activeSession, manager.activeSession)
    }

    func testReloadFailureKeepsMemoryAndSuccessfulReloadUsesStoredState() throws {
        let manager = FocusSessionManager(userDefaults: suite)
        let original = try XCTUnwrap(manager.start(title: "原始任务"))
        let data = try XCTUnwrap(suite.data(forKey: Self.storageKey))
        suite.set(Data("damaged".utf8), forKey: Self.storageKey)
        XCTAssertFalse(manager.retryLoadingStorage())
        XCTAssertEqual(manager.activeSession, original)
        XCTAssertFalse(manager.end())
        suite.set(data, forKey: Self.storageKey)
        XCTAssertTrue(manager.retryLoadingStorage())
        XCTAssertNil(manager.storageError)
        XCTAssertEqual(manager.activeSession, original)
        suite.removeObject(forKey: Self.storageKey)
        XCTAssertTrue(manager.retryLoadingStorage())
        XCTAssertNil(manager.activeSession)
        XCTAssertTrue(manager.history.isEmpty)
    }

    func testFailedLegacyMutationsPreserveMemoryAndStoredDataAndBlockFurtherWrites() throws {
        let seed = FocusSessionManager(userDefaults: suite)
        seed.start(title: "历史")
        seed.end()
        seed.start(title: "活动")
        let fileID = UUID()
        seed.linkNote(id: UUID(), title: "原笔记")
        seed.linkFile(id: fileID, name: "原文件", icon: "doc")
        let originalData = try XCTUnwrap(suite.data(forKey: Self.storageKey))
        let originalActive = seed.activeSession
        let originalHistory = seed.history
        let operations: [(FocusSessionManager) -> Bool] = [
            { $0.end() },
            { $0.linkNote(id: UUID(), title: "新笔记") },
            { $0.linkFile(id: UUID(), name: "新文件", icon: "photo") },
            { $0.unlinkFile(id: fileID) }
        ]
        for operation in operations {
            var writes = 0
            let manager = FocusSessionManager(userDefaults: suite, writeData: { _ in
                writes += 1
                throw CocoaError(.fileWriteNoPermission)
            })
            XCTAssertFalse(operation(manager))
            XCTAssertEqual(manager.activeSession, originalActive)
            XCTAssertEqual(manager.history, originalHistory)
            XCTAssertEqual(suite.data(forKey: Self.storageKey), originalData)
            XCTAssertEqual(manager.storageError, L10n.flowStorageWriteError)
            XCTAssertFalse(manager.end())
            XCTAssertFalse(manager.linkNote(id: UUID(), title: "不可继续"))
            XCTAssertFalse(manager.linkFile(id: UUID(), name: "不可继续", icon: "doc"))
            XCTAssertFalse(manager.unlinkFile(id: fileID))
            XCTAssertNil(manager.start(title: "不可继续"))
            XCTAssertEqual(writes, 1)
        }
    }

    func testLegacyNoOpMutationsDoNotWrite() throws {
        let seed = FocusSessionManager(userDefaults: suite)
        seed.start(title: "既有任务")
        let fileID = UUID()
        let noteID = UUID()
        seed.linkNote(id: noteID, title: "原笔记")
        seed.linkFile(id: fileID, name: "原文件", icon: "doc")
        let original = try XCTUnwrap(seed.activeSession)
        var writes = 0
        let manager = FocusSessionManager(userDefaults: suite, writeData: { _ in writes += 1 })

        XCTAssertEqual(manager.start(title: "另一个任务"), original)
        XCTAssertTrue(manager.linkNote(id: noteID, title: "原笔记"))
        XCTAssertTrue(manager.linkFile(id: fileID, name: "不能替换名称", icon: "photo"))
        XCTAssertTrue(manager.unlinkFile(id: UUID()))
        XCTAssertEqual(manager.activeSession, original)
        XCTAssertEqual(writes, 0)
    }

    func testExistingOptionalMetadataSurvivesLegacyOperationsAndReload() throws {
        let seed = FocusSessionManager(userDefaults: suite)
        var session = try XCTUnwrap(seed.start(title: "兼容任务"))
        let bookmark = Data([1, 2, 3])
        session.originPendingTaskID = UUID()
        session.linkedFiles = [LinkedFile(id: UUID(), name: "已有文件", icon: "doc", bookmarkData: bookmark)]
        let store = FocusSessionStore(activeSession: session, history: [])
        suite.set(try JSONEncoder().encode(store), forKey: Self.storageKey)
        let manager = FocusSessionManager(userDefaults: suite)

        XCTAssertNil(manager.storageError)
        XCTAssertTrue(manager.linkNote(id: UUID(), title: "新笔记"))
        XCTAssertTrue(manager.end())
        let restored = FocusSessionManager(userDefaults: suite)
        XCTAssertEqual(restored.history.first?.originPendingTaskID, session.originPendingTaskID)
        XCTAssertEqual(restored.history.first?.linkedFiles.first?.bookmarkData, bookmark)
        XCTAssertEqual(restored.history.first?.linkedNote?.title, "新笔记")
    }

}
