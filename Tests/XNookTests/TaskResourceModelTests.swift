import XCTest
@testable import XNook

@MainActor
final class TaskResourceModelTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!
    private static let storageKey = "nookflow.sessions"

    override func setUp() {
        super.setUp()
        suiteName = "TestTaskResources.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        suite = nil
        suiteName = nil
        super.tearDown()
    }

    func testLegacySessionWithoutLinksOrOriginStillDecodes() throws {
        let id = UUID()
        let data = Data("""
        {"id":"\(id.uuidString)","title":"旧任务","startedAt":100,
        "state":"active","linkedFiles":[]}
        """.utf8)

        let session = try JSONDecoder().decode(FocusSession.self, from: data)

        XCTAssertEqual(session.id, id)
        XCTAssertNil(session.linkedURLs)
        XCTAssertTrue(session.taskURLs.isEmpty)
        XCTAssertNil(session.originPendingTaskID)
    }

    func testLinksBudgetAndExistingResourcesSurviveEndAndReload() throws {
        let original = makeSession()
        try store(active: original)
        let manager = FocusSessionManager(userDefaults: suite)
        let now = Date(timeIntervalSinceReferenceDate: 1000)

        guard case .added(let linkID) = manager.addTaskURL(
            urlString: "https://example.com/guide", title: "使用说明", to: original.id
        ) else { return XCTFail("应添加链接") }
        XCTAssertTrue(manager.setTimeBudget(minutes: 30, for: original.id, now: now))
        let updated = try XCTUnwrap(manager.activeSession)
        XCTAssertEqual(updated.linkedNote, original.linkedNote)
        XCTAssertEqual(updated.linkedFiles, original.linkedFiles)
        XCTAssertEqual(updated.originPendingTaskID, original.originPendingTaskID)
        XCTAssertEqual(updated.eventIdentifier, original.eventIdentifier)
        XCTAssertTrue(manager.end())

        let restored = FocusSessionManager(userDefaults: suite)
        XCTAssertEqual(restored.history, manager.history)
        XCTAssertEqual(restored.history.first?.taskURLs.first?.id, linkID)
        XCTAssertEqual(restored.history.first?.taskURLs.first?.title, "使用说明")
        XCTAssertEqual(restored.history.first?.scheduledEndAt, now.addingTimeInterval(1800))
        XCTAssertEqual(restored.history.first?.linkedFiles, original.linkedFiles)
        XCTAssertEqual(restored.history.first?.originPendingTaskID, original.originPendingTaskID)
    }

    func testURLNormalizationAndTitleFallback() throws {
        let link = try XCTUnwrap(LinkedTaskURL.make(
            urlString: " \nHTTPS://EXAMPLE.COM:443\t", title: " \n"
        ))
        XCTAssertEqual(link.urlString, "https://example.com/")
        XCTAssertEqual(link.title, "example.com")
        XCTAssertEqual(link.validatedURL?.absoluteString, link.urlString)
        XCTAssertEqual(LinkedTaskURL.make(urlString: "http://EXAMPLE.com:80/a?b=1#c", title: " 手工标题 ")?.title, "手工标题")
        XCTAssertEqual(LinkedTaskURL.make(urlString: "http://EXAMPLE.com:80/a?b=1#c", title: "说明")?.urlString,
                       "http://example.com/a?b=1#c")
        XCTAssertEqual(LinkedTaskURL.make(urlString: "https://example.com:8443/A?b=1#C", title: "说明")?.urlString,
                       "https://example.com:8443/A?b=1#C")
    }

    func testInvalidSchemesHostsCredentialsAndMalformedURLsAreRejected() {
        let invalid = [
            "", " \n", "example.com", "/relative", "//example.com",
            "file:///tmp/note", "javascript:alert(1)", "data:text/html,test", "ftp://example.com",
            "http://", "https:///path", "https://?query", "https://exa mple.com",
            "https://example.com/path with space", "https://example.com/%zz",
            "https://user@example.com", "https://user:secret@example.com",
            "https://:secret@example.com", "https://@example.com"
        ]
        for address in invalid {
            XCTAssertNil(LinkedTaskURL.make(urlString: address, title: "说明"), address)
            XCTAssertNil(LinkedTaskURL(id: UUID(), title: "旧记录", urlString: address).validatedURL, address)
        }
    }

    func testURLAndTitleLengthBoundaries() {
        let prefix = "https://example.com/"
        let maximumURL = prefix + String(repeating: "a", count: 4096 - prefix.count)
        XCTAssertNotNil(LinkedTaskURL.make(urlString: maximumURL, title: String(repeating: "字", count: 120)))
        XCTAssertNil(LinkedTaskURL.make(urlString: maximumURL + "a", title: "说明"))
        XCTAssertNil(LinkedTaskURL.make(urlString: prefix, title: String(repeating: "字", count: 121)))
        XCTAssertNotNil(LinkedTaskURL.make(urlString: prefix, title: " " + String(repeating: "字", count: 120) + "\n"))
    }

    func testStoredLinkRevalidatesItsAddressWithoutDependingOnTitle() {
        let stored = LinkedTaskURL(id: UUID(), title: String(repeating: "旧", count: 121), urlString: " HTTPS://EXAMPLE.COM ")
        XCTAssertEqual(stored.validatedURL?.absoluteString, "https://example.com/")
        XCTAssertNil(LinkedTaskURL(id: UUID(), title: "旧链接", urlString: "file:///tmp/private").validatedURL)
        XCTAssertNil(LinkedTaskURL(id: UUID(), title: "旧链接", urlString: "https://name:password@example.com").validatedURL)
    }

    func testDuplicateNormalizedAddressPreservesOriginalTitleIDAndDoesNotWrite() throws {
        let existing = LinkedTaskURL(id: UUID(), title: "原名称", urlString: "HTTPS://EXAMPLE.COM:443")
        let original = makeSession(links: [existing])
        try store(active: original)
        let originalData = suite.data(forKey: Self.storageKey)
        var writes = 0
        let manager = FocusSessionManager(userDefaults: suite, writeData: { _ in writes += 1 })

        XCTAssertEqual(manager.addTaskURL(urlString: " https://example.com/ ", title: "新名称", to: original.id), .existing(existing.id))

        XCTAssertEqual(manager.activeSession, original)
        XCTAssertEqual(suite.data(forKey: Self.storageKey), originalData)
        XCTAssertEqual(writes, 0)
    }

    func testDistinctPathsQueriesAndFragmentsRemainSeparateLinks() throws {
        let manager = FocusSessionManager(userDefaults: suite)
        let session = try XCTUnwrap(manager.start(title: "地址语义"))
        let addresses = ["https://example.com/a", "https://example.com/A", "https://example.com/a?x=1", "https://example.com/a#part"]
        for address in addresses {
            guard case .added = manager.addTaskURL(urlString: address, title: "说明", to: session.id) else {
                return XCTFail("不能折叠不同地址：\(address)")
            }
        }
        XCTAssertEqual(manager.activeSession?.taskURLs.count, addresses.count)
    }

    func testTwentyLinkLimitAllowsDuplicateButPreservesAllLegacyEntries() throws {
        let links = (0..<21).map { index in
            LinkedTaskURL(id: UUID(), title: "链接\(index)", urlString: "https://example.com/\(index)")
        }
        for count in [19, 20, 21] {
            let original = makeSession(links: Array(links.prefix(count)))
            try store(active: original)
            var writes = 0
            let manager = FocusSessionManager(userDefaults: suite, writeData: { _ in writes += 1 })
            XCTAssertEqual(manager.addTaskURL(urlString: links[0].urlString, title: "重复", to: original.id), .existing(links[0].id))
            let result = manager.addTaskURL(urlString: "https://example.com/new", title: "新增", to: original.id)
            if count == 19 {
                guard case .added = result else { return XCTFail("第 20 条应可添加") }
                XCTAssertEqual(manager.activeSession?.taskURLs.count, 20)
                XCTAssertEqual(writes, 1)
            } else {
                XCTAssertEqual(result, .limitReached)
                XCTAssertEqual(manager.activeSession, original)
                XCTAssertEqual(writes, 0)
            }
        }
    }

    func testHistoricalLinkOperationsOnlyChangeExplicitSession() throws {
        let first = makeSession(state: .ended)
        let second = makeSession(state: .ended)
        let active = makeSession()
        try store(active: active, history: [second, first])
        let manager = FocusSessionManager(userDefaults: suite)

        guard case .added(let id) = manager.addTaskURL(urlString: "https://example.com/history", title: "历史资料", to: first.id) else {
            return XCTFail("历史任务可关联网页")
        }
        XCTAssertEqual(manager.history.map(\.id), [second.id, first.id])
        XCTAssertEqual(manager.activeSession, active)
        XCTAssertEqual(manager.session(id: second.id), second)
        XCTAssertEqual(manager.session(id: first.id)?.taskURLs.first?.id, id)
        XCTAssertEqual(manager.session(id: first.id)?.linkedNote, first.linkedNote)
        XCTAssertEqual(manager.session(id: first.id)?.linkedFiles, first.linkedFiles)
        XCTAssertEqual(manager.session(id: first.id)?.originPendingTaskID, first.originPendingTaskID)
        XCTAssertEqual(manager.session(id: first.id)?.scheduledEndAt, first.scheduledEndAt)
        XCTAssertTrue(manager.unlinkTaskURL(id: id, from: first.id))
        XCTAssertTrue(manager.session(id: first.id)?.taskURLs.isEmpty == true)
        XCTAssertEqual(manager.activeSession, active)
        XCTAssertEqual(FocusSessionManager(userDefaults: suite).history, manager.history)
    }

    func testUnavailableInvalidAndUnchangedOperationsDoNotWrite() throws {
        let original = makeSession()
        try store(active: original)
        var writes = 0
        let manager = FocusSessionManager(userDefaults: suite, writeData: { _ in writes += 1 })

        XCTAssertEqual(manager.addTaskURL(urlString: "https://example.com", title: "说明", to: UUID()), .taskUnavailable)
        XCTAssertEqual(manager.addTaskURL(urlString: "file:///tmp/file", title: "说明", to: original.id), .invalidLink)
        XCTAssertFalse(manager.unlinkTaskURL(id: UUID(), from: UUID()))
        XCTAssertTrue(manager.unlinkTaskURL(id: UUID(), from: original.id))
        XCTAssertEqual(manager.activeSession, original)
        XCTAssertEqual(writes, 0)
    }

    func testBudgetBoundsUseNowAndCanBeClearedWithoutChangingResources() throws {
        let original = makeSession(links: [try XCTUnwrap(LinkedTaskURL.make(urlString: "https://example.com", title: "说明"))])
        try store(active: original)
        let manager = FocusSessionManager(userDefaults: suite)
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        for minutes in [1, 1440] {
            XCTAssertTrue(manager.setTimeBudget(minutes: minutes, for: original.id, now: now))
            var expected = original
            expected.scheduledEndAt = now.addingTimeInterval(Double(minutes) * 60)
            XCTAssertEqual(manager.activeSession, expected)
        }
        XCTAssertTrue(manager.setTimeBudget(minutes: nil, for: original.id, now: now))
        var cleared = original
        cleared.scheduledEndAt = nil
        XCTAssertEqual(manager.activeSession, cleared)
        XCTAssertEqual(FocusSessionManager(userDefaults: suite).activeSession, cleared)
    }

    func testInvalidBudgetAndDatesPreservePlanWithoutWriting() throws {
        let original = makeSession()
        try store(active: original)
        var writes = 0
        let manager = FocusSessionManager(userDefaults: suite, writeData: { _ in writes += 1 })
        for minutes in [Int.min, -1, 0, 1441, Int.max] {
            XCTAssertFalse(manager.setTimeBudget(minutes: minutes, for: original.id))
        }
        for seconds in [Double.nan, Double.infinity, -Double.infinity, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude] {
            XCTAssertFalse(manager.setTimeBudget(minutes: 1, for: original.id, now: Date(timeIntervalSinceReferenceDate: seconds)))
        }
        XCTAssertEqual(manager.activeSession, original)
        XCTAssertEqual(writes, 0)
    }

    func testHistoricalMissingAndEndedActiveSlotCannotSetOrClearBudget() throws {
        let active = makeSession()
        let historical = makeSession(state: .ended)
        try store(active: active, history: [historical])
        var writes = 0
        let manager = FocusSessionManager(userDefaults: suite, writeData: { _ in writes += 1 })
        for id in [historical.id, UUID()] {
            XCTAssertFalse(manager.setTimeBudget(minutes: 10, for: id))
            XCTAssertFalse(manager.setTimeBudget(minutes: nil, for: id))
        }
        XCTAssertEqual(manager.activeSession, active)
        XCTAssertEqual(manager.history, [historical])
        XCTAssertEqual(writes, 0)

        try store(active: historical)
        let endedManager = FocusSessionManager(userDefaults: suite)
        XCTAssertFalse(endedManager.setTimeBudget(minutes: 10, for: historical.id))
        XCTAssertFalse(endedManager.setTimeBudget(minutes: nil, for: historical.id))
    }

    func testFailedLinkAndBudgetWritesPreserveEntireStoreAndBlockFurtherWrites() throws {
        let link = try XCTUnwrap(LinkedTaskURL.make(urlString: "https://example.com/original", title: "原网页"))
        let active = makeSession(links: [link])
        let historical = makeSession(state: .ended, links: [link])
        try store(active: active, history: [historical])
        let originalData = suite.data(forKey: Self.storageKey)
        let operations: [(FocusSessionManager) -> Bool] = [
            { $0.addTaskURL(urlString: "https://example.com/new", title: "新增", to: active.id) != .saveFailed },
            { $0.addTaskURL(urlString: "https://example.com/new", title: "新增", to: historical.id) != .saveFailed },
            { $0.unlinkTaskURL(id: link.id, from: active.id) },
            { $0.unlinkTaskURL(id: link.id, from: historical.id) },
            { $0.setTimeBudget(minutes: 10, for: active.id) },
            { $0.setTimeBudget(minutes: nil, for: active.id) }
        ]
        for operation in operations {
            var writes = 0
            let manager = FocusSessionManager(userDefaults: suite, writeData: { _ in
                writes += 1
                throw CocoaError(.fileWriteNoPermission)
            })
            XCTAssertFalse(operation(manager))
            XCTAssertEqual(manager.activeSession, active)
            XCTAssertEqual(manager.history, [historical])
            XCTAssertEqual(suite.data(forKey: Self.storageKey), originalData)
            XCTAssertNotNil(manager.storageError)
            XCTAssertEqual(manager.addTaskURL(urlString: "https://example.com/other", title: "后续", to: active.id), .saveFailed)
            XCTAssertFalse(manager.unlinkTaskURL(id: link.id, from: active.id))
            XCTAssertFalse(manager.setTimeBudget(minutes: 20, for: active.id))
            XCTAssertEqual(writes, 1)
        }
    }

    func testCandidateLinkIsWrittenBeforeBeingPublished() throws {
        let original = makeSession()
        try store(active: original)
        var manager: FocusSessionManager!
        var persisted: FocusSessionStore?
        manager = FocusSessionManager(userDefaults: suite, writeData: { data in
            XCTAssertEqual(manager.activeSession, original)
            persisted = try JSONDecoder().decode(FocusSessionStore.self, from: data)
        })

        guard case .added = manager.addTaskURL(urlString: "https://example.com", title: "说明", to: original.id) else {
            return XCTFail("应成功添加")
        }
        XCTAssertEqual(persisted?.activeSession, manager.activeSession)
        XCTAssertEqual(persisted?.activeSession?.taskURLs.count, 1)
    }

    private func makeSession(state: FocusSession.State = .active, links: [LinkedTaskURL]? = nil) -> FocusSession {
        let id = UUID()
        return FocusSession(
            id: id, title: "资料任务", eventIdentifier: "event-\(id.uuidString)",
            startedAt: Date(timeIntervalSinceReferenceDate: 100),
            scheduledEndAt: Date(timeIntervalSinceReferenceDate: 200),
            endedAt: state == .ended ? Date(timeIntervalSinceReferenceDate: 300) : nil,
            state: state, linkedNote: LinkedNote(id: UUID(), title: "原笔记"),
            linkedFiles: [LinkedFile(id: UUID(), name: "原文件", icon: "doc", bookmarkData: Data([1, 2, 3]))],
            originPendingTaskID: id, linkedURLs: links
        )
    }

    private func store(active: FocusSession?, history: [FocusSession] = []) throws {
        suite.set(try JSONEncoder().encode(FocusSessionStore(activeSession: active, history: history)), forKey: Self.storageKey)
    }
}
