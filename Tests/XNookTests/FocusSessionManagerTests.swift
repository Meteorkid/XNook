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

    func testStartCreatesActiveSession() {
        let manager = FocusSessionManager(userDefaults: suite)
        let session = manager.start(title: "产品周会", eventIdentifier: "evt-1", scheduledEndAt: Date(timeIntervalSinceNow: 3600))

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
}
