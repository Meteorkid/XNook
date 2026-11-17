import XCTest
@testable import XNook

@MainActor
final class FocusSessionManagerTests: XCTestCase {
    /// 每个测试使用独立 suite，避免污染全局 standard 与彼此串扰
    private var suite: UserDefaults!
    private var suiteName: String!
    private var legacySuite: UserDefaults!
    private static let storageKey = "nookflow.sessions"

    override func setUp() {
        super.setUp()
        suiteName = "TestNookFlow.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
        legacySuite = UserDefaults(suiteName: suiteName + ".legacy")
        legacySuite.removePersistentDomain(forName: suiteName + ".legacy")
    }

    override func tearDown() {
        if let name = suiteName {
            suite.removePersistentDomain(forName: name)
            legacySuite.removePersistentDomain(forName: name + ".legacy")
        }
        suite = nil
        legacySuite = nil
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

    func testFileBookmarkSurvivesEndAndReload() {
        let manager = FocusSessionManager(userDefaults: suite)
        let bookmark = Data([1, 7, 9, 4])
        manager.start(title: "手动任务")
        manager.linkFile(id: UUID(), name: "草图.png", icon: "photo", bookmarkData: bookmark)
        manager.end()

        let restored = FocusSessionManager(userDefaults: suite)
        XCTAssertEqual(restored.history.first?.linkedFiles.first?.bookmarkData, bookmark)
    }

    func testLegacyFileWithoutBookmarkStillDecodes() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id.uuidString)\",\"name\":\"旧文件\",\"icon\":\"doc\"}".utf8)
        let file = try JSONDecoder().decode(LinkedFile.self, from: data)
        XCTAssertEqual(file.id, id)
        XCTAssertNil(file.bookmarkData)
    }

    func testRelinkingLegacyFileAddsBookmarkWithoutDuplicatingOrRenaming() {
        let manager = FocusSessionManager(userDefaults: suite)
        let id = UUID()
        let bookmark = Data([4, 2, 1])
        manager.start(title: "旧任务")
        manager.linkFile(id: id, name: "原文件名", icon: "doc")
        manager.linkFile(id: id, name: "新文件名", icon: "photo", bookmarkData: bookmark)

        XCTAssertEqual(manager.activeSession?.linkedFiles.count, 1)
        XCTAssertEqual(manager.activeSession?.linkedFiles.first?.name, "原文件名")
        XCTAssertEqual(manager.activeSession?.linkedFiles.first?.bookmarkData, bookmark)
        XCTAssertEqual(FocusSessionManager(userDefaults: suite).activeSession?.linkedFiles.first?.bookmarkData, bookmark)
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

    func testEndingTaskPreservesAllHistoryBeyondTwoHundredRecords() throws {
        let originalHistory = makeHistory(count: 200)
        suite.set(
            try JSONEncoder().encode(FocusSessionStore(activeSession: nil, history: originalHistory)),
            forKey: Self.storageKey
        )
        let manager = FocusSessionManager(userDefaults: suite)
        let active = try XCTUnwrap(manager.start(title: "第 201 个任务"))

        XCTAssertTrue(manager.end())
        XCTAssertEqual(manager.history.count, 201)
        XCTAssertEqual(manager.history.first?.id, active.id)
        XCTAssertTrue(Array(manager.history.dropFirst()) == originalHistory, "原有 200 条历史应完整保留")

        let restored = FocusSessionManager(userDefaults: suite)
        XCTAssertTrue(restored.history == manager.history, "重载应恢复全部 201 条历史")
        XCTAssertEqual(restored.session(id: originalHistory[199].id), originalHistory[199])
    }

    func testOldestHistoryRecordRemainsEditableAfterEndingAnotherTask() throws {
        let originalHistory = makeHistory(count: 250)
        let oldest = try XCTUnwrap(originalHistory.last)
        suite.set(
            try JSONEncoder().encode(FocusSessionStore(activeSession: nil, history: originalHistory)),
            forKey: Self.storageKey
        )
        let manager = FocusSessionManager(userDefaults: suite)
        XCTAssertNotNil(manager.start(title: "最新任务"))
        XCTAssertTrue(manager.end())
        guard case .added = manager.addTaskURL(
            urlString: "https://example.com/older-task", title: "旧任务资料", to: oldest.id
        ) else {
            return XCTFail("超过 200 条的历史任务必须仍可编辑")
        }
        let link = try XCTUnwrap(manager.session(id: oldest.id)?.taskURLs.first)
        XCTAssertEqual(
            manager.editTaskURL(link, urlString: "https://example.com/updated", title: "更新资料", in: oldest.id),
            .updated
        )

        let restored = FocusSessionManager(userDefaults: suite)
        let restoredOldest = try XCTUnwrap(restored.session(id: oldest.id))
        XCTAssertEqual(restored.history.count, 251)
        XCTAssertEqual(restoredOldest.linkedFiles, oldest.linkedFiles)
        XCTAssertEqual(restoredOldest.linkedNote, oldest.linkedNote)
        XCTAssertEqual(restoredOldest.taskURLs.first?.title, "更新资料")
        XCTAssertEqual(restoredOldest.taskURLs.first?.urlString, "https://example.com/updated")
    }

    func testFailedEndPreservesCompleteLargeHistoryAndActiveTask() throws {
        let originalHistory = makeHistory(count: 250)
        suite.set(
            try JSONEncoder().encode(FocusSessionStore(activeSession: nil, history: originalHistory)),
            forKey: Self.storageKey
        )
        let seed = FocusSessionManager(userDefaults: suite)
        let active = try XCTUnwrap(seed.start(title: "保存失败的任务"))
        let originalData = try XCTUnwrap(suite.data(forKey: Self.storageKey))
        let manager = FocusSessionManager(userDefaults: suite, writeData: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })

        XCTAssertFalse(manager.end())
        XCTAssertEqual(manager.activeSession, active)
        XCTAssertTrue(manager.history == originalHistory, "写入失败不得更改完整历史")
        XCTAssertEqual(suite.data(forKey: Self.storageKey), originalData)
        XCTAssertEqual(manager.storageError, L10n.flowStorageWriteError)
    }

    func testLegacyMigrationCopiesCompleteStoreAndKeepsRollbackSnapshot() throws {
        let seed = FocusSessionManager(userDefaults: legacySuite)
        let active = try XCTUnwrap(seed.start(title: "旧活跃任务"))
        seed.linkNote(id: UUID(), title: "旧笔记")
        seed.linkFile(id: UUID(), name: "旧文件", icon: "doc", bookmarkData: Data([4, 2, 1]))
        seed.addTaskURL(urlString: "https://example.com/legacy", title: "旧资料", to: active.id)
        let originalHistory = makeHistory(count: 250)
        let originalData = try JSONEncoder().encode(
            FocusSessionStore(activeSession: seed.activeSession, history: originalHistory)
        )
        legacySuite.set(originalData, forKey: Self.storageKey)

        let manager = FocusSessionManager(userDefaults: suite, legacyUserDefaults: legacySuite)

        XCTAssertNil(manager.storageError)
        XCTAssertEqual(manager.activeSession, seed.activeSession)
        XCTAssertTrue(manager.history == originalHistory, "迁移应保留全部 250 条历史及关联快照")
        XCTAssertEqual(suite.data(forKey: Self.storageKey), originalData)
        XCTAssertEqual(legacySuite.data(forKey: Self.storageKey), originalData)
        let rollback = FocusSessionManager(userDefaults: legacySuite)
        XCTAssertEqual(rollback.activeSession, seed.activeSession)
        XCTAssertTrue(rollback.history == originalHistory, "迁移来源应保持旧版本可读取的完整快照")
    }

    func testLegacyMigrationIsIdempotentAfterTargetEdits() throws {
        let sourceHistory = makeHistory(count: 2)
        let sourceData = try JSONEncoder().encode(FocusSessionStore(activeSession: nil, history: sourceHistory))
        legacySuite.set(sourceData, forKey: Self.storageKey)
        var writes = 0
        let write: (Data) throws -> Void = { [suite] data in
            writes += 1
            suite?.set(data, forKey: Self.storageKey)
        }
        let manager = FocusSessionManager(userDefaults: suite, legacyUserDefaults: legacySuite, writeData: write)
        XCTAssertEqual(writes, 1)
        let active = try XCTUnwrap(manager.start(title: "迁移后新增任务"))
        let targetData = try XCTUnwrap(suite.data(forKey: Self.storageKey))
        XCTAssertEqual(writes, 2)

        let restored = FocusSessionManager(userDefaults: suite, legacyUserDefaults: legacySuite, writeData: write)
        XCTAssertTrue(restored.retryLoadingStorage())
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(restored.activeSession, active)
        XCTAssertEqual(restored.history, sourceHistory)
        XCTAssertEqual(suite.data(forKey: Self.storageKey), targetData)
        XCTAssertEqual(legacySuite.data(forKey: Self.storageKey), sourceData)
    }

    func testExistingValidTargetIsUsableEvenWhenLegacySourceIsCorrupt() throws {
        let history = makeHistory(count: 2)
        let targetData = try JSONEncoder().encode(FocusSessionStore(activeSession: nil, history: history))
        suite.set(targetData, forKey: Self.storageKey)
        let corruptSource = Data("corrupt legacy history".utf8)
        legacySuite.set(corruptSource, forKey: Self.storageKey)
        var writes = 0

        let manager = FocusSessionManager(userDefaults: suite, legacyUserDefaults: legacySuite, writeData: { _ in
            writes += 1
        })

        XCTAssertNil(manager.storageError)
        XCTAssertEqual(manager.history, history)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(suite.data(forKey: Self.storageKey), targetData)
        XCTAssertEqual(legacySuite.data(forKey: Self.storageKey), corruptSource)
    }

    func testInvalidLegacySourcesAreProtectedAndDoNotCreateTarget() {
        for payload in [Data("broken source".utf8), "unexpected source type"] as [Any] {
            legacySuite.set(payload, forKey: Self.storageKey)
            var writes = 0
            let manager = FocusSessionManager(userDefaults: suite, legacyUserDefaults: legacySuite, writeData: { _ in
                writes += 1
            })

            XCTAssertEqual(manager.storageError, L10n.flowStorageReadError)
            XCTAssertNil(manager.start(title: "不得覆盖旧历史"))
            XCTAssertFalse(manager.end())
            XCTAssertFalse(manager.retryLoadingStorage())
            XCTAssertTrue(manager.history.isEmpty)
            XCTAssertNil(suite.object(forKey: Self.storageKey))
            XCTAssertEqual(legacySuite.object(forKey: Self.storageKey) as? NSObject, payload as? NSObject)
            XCTAssertEqual(writes, 0)
        }
    }

    func testInvalidExistingTargetsAreNotReplacedByLegacySource() throws {
        let sourceData = try JSONEncoder().encode(FocusSessionStore(activeSession: nil, history: makeHistory(count: 2)))
        legacySuite.set(sourceData, forKey: Self.storageKey)
        for payload in [Data("broken target".utf8), "unexpected target type"] as [Any] {
            suite.set(payload, forKey: Self.storageKey)
            var writes = 0
            let manager = FocusSessionManager(userDefaults: suite, legacyUserDefaults: legacySuite, writeData: { _ in
                writes += 1
            })

            XCTAssertEqual(manager.storageError, L10n.flowStorageReadError)
            XCTAssertNil(manager.start(title: "不得覆盖损坏目标"))
            XCTAssertFalse(manager.retryLoadingStorage())
            XCTAssertEqual(suite.object(forKey: Self.storageKey) as? NSObject, payload as? NSObject)
            XCTAssertEqual(legacySuite.data(forKey: Self.storageKey), sourceData)
            XCTAssertEqual(writes, 0)
        }
    }

    func testFailedLegacyMigrationPreservesSourceAndRequiresReloadBeforeWriting() throws {
        let sourceHistory = makeHistory(count: 2)
        let sourceData = try JSONEncoder().encode(FocusSessionStore(activeSession: nil, history: sourceHistory))
        legacySuite.set(sourceData, forKey: Self.storageKey)
        var shouldFail = true
        var writes = 0
        let manager = FocusSessionManager(userDefaults: suite, legacyUserDefaults: legacySuite, writeData: { [suite] data in
            writes += 1
            if shouldFail { throw CocoaError(.fileWriteNoPermission) }
            suite?.set(data, forKey: Self.storageKey)
        })

        XCTAssertEqual(manager.storageError, L10n.flowStorageWriteError)
        XCTAssertTrue(manager.history.isEmpty)
        XCTAssertNil(suite.object(forKey: Self.storageKey))
        XCTAssertEqual(legacySuite.data(forKey: Self.storageKey), sourceData)
        shouldFail = false
        XCTAssertNil(manager.start(title: "须先重新读取"))
        XCTAssertEqual(writes, 1)

        XCTAssertTrue(manager.retryLoadingStorage())
        XCTAssertNil(manager.storageError)
        XCTAssertEqual(manager.history, sourceHistory)
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(suite.data(forKey: Self.storageKey), sourceData)
        XCTAssertEqual(legacySuite.data(forKey: Self.storageKey), sourceData)
        XCTAssertNotNil(manager.start(title: "恢复后任务"))
    }

    func testMigrationWithoutMatchingReadbackDoesNotPublishAndCanRetry() throws {
        let sourceHistory = makeHistory(count: 2)
        let sourceData = try JSONEncoder().encode(FocusSessionStore(activeSession: nil, history: sourceHistory))
        legacySuite.set(sourceData, forKey: Self.storageKey)
        var acceptsWrite = false
        let manager = FocusSessionManager(userDefaults: suite, legacyUserDefaults: legacySuite, writeData: { [suite] data in
            if acceptsWrite { suite?.set(data, forKey: Self.storageKey) }
        })

        XCTAssertEqual(manager.storageError, L10n.flowStorageWriteError)
        XCTAssertTrue(manager.history.isEmpty)
        XCTAssertNil(manager.start(title: "不能先发布"))
        XCTAssertEqual(legacySuite.data(forKey: Self.storageKey), sourceData)
        acceptsWrite = true

        XCTAssertTrue(manager.retryLoadingStorage())
        XCTAssertEqual(manager.history, sourceHistory)
        XCTAssertEqual(suite.data(forKey: Self.storageKey), sourceData)
        XCTAssertEqual(legacySuite.data(forKey: Self.storageKey), sourceData)
    }

    func testRepairingLegacySourceAllowsMigrationOnReload() throws {
        legacySuite.set(Data("broken source".utf8), forKey: Self.storageKey)
        let manager = FocusSessionManager(userDefaults: suite, legacyUserDefaults: legacySuite)
        XCTAssertEqual(manager.storageError, L10n.flowStorageReadError)
        let history = makeHistory(count: 2)
        let sourceData = try JSONEncoder().encode(FocusSessionStore(activeSession: nil, history: history))
        legacySuite.set(sourceData, forKey: Self.storageKey)

        XCTAssertTrue(manager.retryLoadingStorage())
        XCTAssertNil(manager.storageError)
        XCTAssertEqual(manager.history, history)
        XCTAssertEqual(suite.data(forKey: Self.storageKey), sourceData)
        XCTAssertEqual(legacySuite.data(forKey: Self.storageKey), sourceData)
    }

    private func makeHistory(count: Int) -> [FocusSession] {
        (0..<count).map { index in
            let endedAt = Date(timeIntervalSince1970: 1_700_000_000 - Double(index * 60))
            return FocusSession(
                id: UUID(), title: "历史任务 \(index)", eventIdentifier: nil,
                startedAt: endedAt.addingTimeInterval(-30), scheduledEndAt: nil,
                endedAt: endedAt, state: .ended,
                linkedNote: LinkedNote(id: UUID(), title: "历史笔记 \(index)"),
                linkedFiles: [LinkedFile(
                    id: UUID(), name: "历史文件 \(index)", icon: "doc", bookmarkData: Data([1, 2, 3])
                )]
            )
        }
    }

}
