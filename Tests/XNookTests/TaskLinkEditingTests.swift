import XCTest
@testable import XNook

@MainActor
final class TaskLinkEditingTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!
    private static let storageKey = "nookflow.sessions"

    override func setUp() {
        super.setUp()
        suiteName = "XNook.TaskLinkEditing.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        suite = nil
        suiteName = nil
        super.tearDown()
    }

    func testLegacyJSONWithoutRevisionStillDecodesAndNewRevisionRoundTrips() throws {
        let id = UUID()
        let data = Data("""
        {"id":"\(id.uuidString)","title":"旧网页","urlString":"https://example.com/"}
        """.utf8)
        let legacy = try JSONDecoder().decode(LinkedTaskURL.self, from: data)
        XCTAssertEqual(legacy.id, id)
        XCTAssertNil(legacy.revision)

        let edited = LinkedTaskURL(id: id, title: legacy.title, urlString: legacy.urlString, revision: UUID())
        XCTAssertEqual(try JSONDecoder().decode(LinkedTaskURL.self, from: JSONEncoder().encode(edited)), edited)
        XCTAssertNotEqual(edited, legacy)
    }

    func testEditPreservesIDPositionAndOtherResourcesAndSurvivesReload() throws {
        let links = [makeLink(path: "first"), makeLink(path: "target"), makeLink(path: "last")]
        let original = makeSession(links: links)
        try store(active: original)
        let manager = FocusSessionManager(userDefaults: suite)

        XCTAssertEqual(manager.editTaskURL(links[1], urlString: " HTTPS://EXAMPLE.ORG:443/new ",
                                          title: " 修改后的标题 \n", in: original.id), .updated)

        let updated = try XCTUnwrap(manager.activeSession)
        let edited = updated.taskURLs[1]
        XCTAssertEqual(updated.taskURLs.map(\.id), links.map(\.id))
        XCTAssertEqual(edited.title, "修改后的标题")
        XCTAssertEqual(edited.urlString, "https://example.org/new")
        XCTAssertNotNil(edited.revision)
        var expected = original
        expected.linkedURLs?[1] = edited
        XCTAssertEqual(updated, expected)
        XCTAssertEqual(FocusSessionManager(userDefaults: suite).activeSession, updated)
    }

    func testEditingAddressWithBlankTitleUsesNewHost() throws {
        let link = makeLink()
        let session = makeSession(links: [link])
        try store(active: session)
        let manager = FocusSessionManager(userDefaults: suite)

        XCTAssertEqual(manager.editTaskURL(link, urlString: "https://NEW.EXAMPLE.org", title: " \n", in: session.id), .updated)
        XCTAssertEqual(manager.activeSession?.taskURLs.first?.title, "new.example.org")
        XCTAssertEqual(manager.activeSession?.taskURLs.first?.urlString, "https://new.example.org/")
    }

    func testHistoricalEditPreservesSessionOrderAndActiveTask() throws {
        let link = makeLink()
        let historical = makeSession(state: .ended, links: [link])
        let other = makeSession(state: .ended)
        let active = makeSession()
        try store(active: active, history: [other, historical])
        let manager = FocusSessionManager(userDefaults: suite)

        XCTAssertEqual(manager.editTaskURL(link, urlString: link.urlString, title: "历史新标题", in: historical.id), .updated)

        let edited = try XCTUnwrap(manager.session(id: historical.id)?.taskURLs.first)
        var expected = historical
        expected.linkedURLs = [edited]
        XCTAssertEqual(manager.activeSession, active)
        XCTAssertEqual(manager.history, [other, expected])
        XCTAssertEqual(FocusSessionManager(userDefaults: suite).history, manager.history)
    }

    func testAnActiveTaskThatEndedWhileEditingCanStillBeEdited() throws {
        let link = makeLink()
        let session = makeSession(links: [link])
        try store(active: session)
        let manager = FocusSessionManager(userDefaults: suite)
        XCTAssertTrue(manager.end())

        XCTAssertEqual(manager.editTaskURL(link, urlString: link.urlString, title: "结束后保存", in: session.id), .updated)
        XCTAssertNil(manager.activeSession)
        XCTAssertEqual(manager.history.first?.taskURLs.first?.title, "结束后保存")
    }

    func testEditingLegacyStoreOverTwentyLinksDoesNotApplyAddLimit() throws {
        let links = (0..<21).map { makeLink(path: "\($0)") }
        let session = makeSession(links: links)
        try store(active: session)
        let manager = FocusSessionManager(userDefaults: suite)

        XCTAssertEqual(manager.editTaskURL(links[20], urlString: links[20].urlString, title: "末项新标题", in: session.id), .updated)
        XCTAssertEqual(manager.activeSession?.taskURLs.count, 21)
        XCTAssertEqual(manager.activeSession?.taskURLs.map(\.id), links.map(\.id))
    }

    func testUnchangedNormalizedInputDoesNotWriteOrCreateRevision() throws {
        for revision in [nil, UUID()] as [UUID?] {
            let link = LinkedTaskURL(id: UUID(), title: "原网页", urlString: "HTTPS://EXAMPLE.COM:443", revision: revision)
            let session = makeSession(links: [link])
            try store(active: session)
            let before = suite.data(forKey: Self.storageKey)
            var writes = 0
            let manager = FocusSessionManager(userDefaults: suite, writeData: { _ in writes += 1 })

            XCTAssertEqual(manager.editTaskURL(link, urlString: " https://example.com/ \n", title: " 原网页 ", in: session.id), .unchanged)
            XCTAssertEqual(manager.activeSession, session)
            XCTAssertEqual(suite.data(forKey: Self.storageKey), before)
            XCTAssertEqual(writes, 0)
        }
    }

    func testInvalidEditsKeepEntireStoreWithoutWriting() throws {
        let link = makeLink()
        let session = makeSession(links: [link])
        try store(active: session)
        let before = suite.data(forKey: Self.storageKey)
        var writes = 0
        let manager = FocusSessionManager(userDefaults: suite, writeData: { _ in writes += 1 })
        let invalidAddresses = ["", "example.com", "file:///tmp/file", "javascript:alert(1)",
                                "https://user:secret@example.com", "https://example.com/%zz",
                                "https://example.com/" + String(repeating: "a", count: 4096)]
        for address in invalidAddresses {
            XCTAssertEqual(manager.editTaskURL(link, urlString: address, title: "标题", in: session.id), .invalidLink, address)
        }
        XCTAssertEqual(manager.editTaskURL(link, urlString: link.urlString, title: String(repeating: "字", count: 121), in: session.id), .invalidLink)
        XCTAssertEqual(manager.activeSession, session)
        XCTAssertEqual(suite.data(forKey: Self.storageKey), before)
        XCTAssertEqual(writes, 0)
    }

    func testDuplicateNormalizedAddressIsRejectedWithoutWriting() throws {
        let link = makeLink()
        let duplicate = LinkedTaskURL(id: UUID(), title: "既有网页", urlString: "HTTPS://OTHER.EXAMPLE.COM:443")
        let session = makeSession(links: [link, duplicate])
        try store(active: session)
        var writes = 0
        let manager = FocusSessionManager(userDefaults: suite, writeData: { _ in writes += 1 })

        XCTAssertEqual(manager.editTaskURL(link, urlString: " https://other.example.com/ ", title: "不能覆盖", in: session.id), .existing(duplicate.id))
        XCTAssertEqual(manager.activeSession, session)
        XCTAssertEqual(writes, 0)
    }

    func testDifferentPathQueryAndFragmentRemainDistinctWhenEditing() throws {
        let first = makeLink(path: "a")
        let target = makeLink(path: "target")
        let session = makeSession(links: [first, target])
        try store(active: session)
        let manager = FocusSessionManager(userDefaults: suite)
        var original = target
        for suffix in ["A", "a?x=1", "a#part"] {
            XCTAssertEqual(manager.editTaskURL(original, urlString: "https://example.com/\(suffix)", title: "新地址", in: session.id), .updated)
            original = try XCTUnwrap(manager.session(id: session.id)?.taskURLs.last)
        }
        XCTAssertEqual(manager.activeSession?.taskURLs.first, first)
    }

    func testStaleSnapshotCannotOverwriteNewTitleEvenWithMatchingRevision() throws {
        let link = makeLink()
        var session = makeSession(links: [link])
        try store(active: session)
        var writes = 0
        let manager = FocusSessionManager(userDefaults: suite, writeData: { _ in writes += 1 })
        session.linkedURLs = [LinkedTaskURL(id: link.id, title: "另一处保存的标题", urlString: link.urlString)]
        try store(active: session)
        XCTAssertTrue(manager.retryLoadingStorage())

        XCTAssertEqual(manager.editTaskURL(link, urlString: link.urlString, title: "迟到内容", in: session.id), .conflict)
        XCTAssertEqual(manager.editTaskURL(link, urlString: link.urlString, title: "另一处保存的标题", in: session.id), .conflict)
        XCTAssertEqual(manager.activeSession, session)
        XCTAssertEqual(writes, 0)
    }

    func testChangingBackToOriginalValuesStillRejectsOldSnapshotAfterReload() throws {
        let original = makeLink()
        let session = makeSession(links: [original])
        try store(active: session)
        let manager = FocusSessionManager(userDefaults: suite)
        XCTAssertEqual(manager.editTaskURL(original, urlString: original.urlString, title: "暂时标题", in: session.id), .updated)
        let intermediate = try XCTUnwrap(manager.activeSession?.taskURLs.first)
        XCTAssertEqual(manager.editTaskURL(intermediate, urlString: original.urlString, title: original.title, in: session.id), .updated)
        let restored = try XCTUnwrap(manager.activeSession?.taskURLs.first)
        XCTAssertNotEqual(restored.revision, intermediate.revision)
        XCTAssertNotNil(restored.revision)
        var writes = 0
        let reloaded = FocusSessionManager(userDefaults: suite, writeData: { _ in writes += 1 })

        XCTAssertEqual(reloaded.editTaskURL(original, urlString: original.urlString, title: "迟到覆盖", in: session.id), .conflict)
        XCTAssertEqual(reloaded.activeSession?.taskURLs.first, restored)
        XCTAssertEqual(writes, 0)
    }

    func testRemovedLinkAndDeletedTaskRejectOldSnapshotWithoutWriting() throws {
        let link = makeLink()
        let session = makeSession(links: [link])
        try store(active: session)
        var writes = 0
        let manager = FocusSessionManager(userDefaults: suite, writeData: { [suite] data in
            writes += 1
            suite?.set(data, forKey: Self.storageKey)
        })
        XCTAssertTrue(manager.unlinkTaskURL(id: link.id, from: session.id))
        writes = 0
        XCTAssertEqual(manager.editTaskURL(link, urlString: link.urlString, title: "已解除", in: session.id), .linkUnavailable)
        try store(active: nil)
        XCTAssertTrue(manager.retryLoadingStorage())
        XCTAssertEqual(manager.editTaskURL(link, urlString: link.urlString, title: "已移除", in: session.id), .taskUnavailable)
        XCTAssertEqual(writes, 0)
    }

    func testDuplicateLegacyLinkIDsAreRejectedWithoutChangingEitherEntry() throws {
        let link = makeLink()
        let duplicate = LinkedTaskURL(id: link.id, title: "相同 ID 的另一条", urlString: "https://other.example.com/")
        let session = makeSession(links: [link, duplicate])
        try store(active: session)
        var writes = 0
        let manager = FocusSessionManager(userDefaults: suite, writeData: { _ in writes += 1 })

        XCTAssertEqual(manager.editTaskURL(link, urlString: link.urlString, title: "无法定位", in: session.id), .conflict)
        XCTAssertEqual(manager.activeSession, session)
        XCTAssertEqual(writes, 0)
    }

    func testCandidateIsWrittenBeforeEditedStateIsPublished() throws {
        let link = makeLink()
        let session = makeSession(links: [link])
        try store(active: session)
        var manager: FocusSessionManager!
        var candidate: FocusSessionStore?
        manager = FocusSessionManager(userDefaults: suite, writeData: { data in
            XCTAssertEqual(manager.activeSession, session)
            candidate = try JSONDecoder().decode(FocusSessionStore.self, from: data)
        })

        XCTAssertEqual(manager.editTaskURL(link, urlString: link.urlString, title: "落盘候选", in: session.id), .updated)
        XCTAssertEqual(candidate?.activeSession, manager.activeSession)
        XCTAssertEqual(candidate?.activeSession?.taskURLs.first?.title, "落盘候选")
        XCTAssertNotNil(candidate?.activeSession?.taskURLs.first?.revision)
    }

    func testFailedEditsPreserveActiveHistoryAndStoredDataAndBlockLaterWrites() throws {
        let link = makeLink()
        let active = makeSession(links: [link])
        let historical = makeSession(state: .ended, links: [link])
        try store(active: active, history: [historical])
        let before = suite.data(forKey: Self.storageKey)
        for sessionID in [active.id, historical.id] {
            var writes = 0
            let manager = FocusSessionManager(userDefaults: suite, writeData: { _ in
                writes += 1
                throw CocoaError(.fileWriteNoPermission)
            })
            XCTAssertEqual(manager.editTaskURL(link, urlString: link.urlString, title: "不能发布", in: sessionID), .saveFailed)
            XCTAssertEqual(manager.activeSession, active)
            XCTAssertEqual(manager.history, [historical])
            XCTAssertEqual(suite.data(forKey: Self.storageKey), before)
            XCTAssertEqual(manager.storageError, L10n.flowStorageWriteError)
            XCTAssertEqual(manager.editTaskURL(link, urlString: link.urlString, title: "后续写入", in: sessionID), .saveFailed)
            XCTAssertEqual(writes, 1)
        }
    }

    func testReloadAfterWriteFailureAllowsSameDraftOnlyIfOriginalStillMatches() throws {
        let link = makeLink()
        let session = makeSession(links: [link])
        try store(active: session)
        var shouldFail = true
        let manager = FocusSessionManager(userDefaults: suite, writeData: { [suite] data in
            if shouldFail { throw CocoaError(.fileWriteNoPermission) }
            suite?.set(data, forKey: Self.storageKey)
        })
        XCTAssertEqual(manager.editTaskURL(link, urlString: link.urlString, title: "保留草稿", in: session.id), .saveFailed)
        shouldFail = false
        XCTAssertEqual(manager.editTaskURL(link, urlString: link.urlString, title: "保留草稿", in: session.id), .saveFailed)
        XCTAssertTrue(manager.retryLoadingStorage())
        XCTAssertEqual(manager.editTaskURL(link, urlString: link.urlString, title: "保留草稿", in: session.id), .updated)
        XCTAssertEqual(manager.activeSession?.taskURLs.first?.title, "保留草稿")
    }

    func testReloadAfterWriteFailureRejectsDraftWhenStoredLinkHasChanged() throws {
        let link = makeLink()
        let session = makeSession(links: [link])
        try store(active: session)
        var writes = 0
        let manager = FocusSessionManager(userDefaults: suite, writeData: { _ in
            writes += 1
            throw CocoaError(.fileWriteNoPermission)
        })
        XCTAssertEqual(manager.editTaskURL(link, urlString: link.urlString, title: "旧草稿", in: session.id), .saveFailed)
        let other = FocusSessionManager(userDefaults: suite)
        XCTAssertEqual(other.editTaskURL(link, urlString: link.urlString, title: "新内容", in: session.id), .updated)
        XCTAssertTrue(manager.retryLoadingStorage())

        XCTAssertEqual(manager.editTaskURL(link, urlString: link.urlString, title: "旧草稿", in: session.id), .conflict)
        XCTAssertEqual(manager.activeSession, other.activeSession)
        XCTAssertEqual(writes, 1)
    }

    func testCorruptStoreBlocksEditsWithoutOverwritingStoredData() throws {
        let data = Data("invalid store".utf8)
        suite.set(data, forKey: Self.storageKey)
        var writes = 0
        let manager = FocusSessionManager(userDefaults: suite, writeData: { _ in writes += 1 })

        XCTAssertEqual(manager.editTaskURL(makeLink(), urlString: "https://example.com/", title: "标题", in: UUID()), .saveFailed)
        XCTAssertEqual(manager.storageError, L10n.flowStorageReadError)
        XCTAssertEqual(suite.data(forKey: Self.storageKey), data)
        XCTAssertEqual(writes, 0)
    }

    func testCoordinatorReportsValidationAndConflictErrorsAndClearsOnSuccess() throws {
        let link = makeLink()
        let duplicate = makeLink(path: "duplicate")
        let session = makeSession(links: [link, duplicate])
        try store(active: session)
        let manager = FocusSessionManager(userDefaults: suite)
        let resources = makeResources(manager: manager)

        XCTAssertFalse(resources.editTaskURL(link, urlString: "file:///tmp/file", title: "无效", in: session.id))
        XCTAssertEqual(resources.errorMessage, L10n.flowInvalidWebLink)
        XCTAssertFalse(resources.editTaskURL(link, urlString: duplicate.urlString, title: "重复", in: session.id))
        XCTAssertEqual(resources.errorMessage, L10n.flowWebLinkExists)
        XCTAssertTrue(resources.editTaskURL(link, urlString: link.urlString, title: link.title, in: session.id))
        XCTAssertNil(resources.errorMessage)
        XCTAssertTrue(resources.editTaskURL(link, urlString: link.urlString, title: "新标题", in: session.id))
        XCTAssertNil(resources.errorMessage)
        XCTAssertFalse(resources.editTaskURL(link, urlString: link.urlString, title: "迟到", in: session.id))
        XCTAssertEqual(resources.errorMessage, L10n.flowWebLinkChanged)
        let latest = try XCTUnwrap(manager.activeSession?.taskURLs.first)
        XCTAssertTrue(manager.unlinkTaskURL(id: link.id, from: session.id))
        XCTAssertFalse(resources.editTaskURL(latest, urlString: latest.urlString, title: "解除后", in: session.id))
        XCTAssertEqual(resources.errorMessage, L10n.flowWebLinkRemoved)
        XCTAssertFalse(resources.editTaskURL(latest, urlString: latest.urlString, title: "任务移除后", in: UUID()))
        XCTAssertEqual(resources.errorMessage, L10n.flowResourceTaskMissing)
    }

    func testCoordinatorKeepsWriteFailureAndStorageReadFailureMessages() throws {
        let link = makeLink()
        let session = makeSession(links: [link])
        try store(active: session)
        let manager = FocusSessionManager(userDefaults: suite, writeData: { _ in throw CocoaError(.fileWriteNoPermission) })
        let resources = makeResources(manager: manager)
        XCTAssertFalse(resources.editTaskURL(link, urlString: link.urlString, title: "未保存草稿", in: session.id))
        XCTAssertEqual(resources.errorMessage, L10n.flowStorageWriteError)
        XCTAssertEqual(manager.activeSession, session)

        suite.set(Data("corrupt".utf8), forKey: Self.storageKey)
        XCTAssertFalse(manager.retryLoadingStorage())
        XCTAssertFalse(resources.editTaskURL(link, urlString: link.urlString, title: "未保存草稿", in: session.id))
        XCTAssertEqual(resources.errorMessage, L10n.flowStorageReadError)
        XCTAssertEqual(manager.activeSession, session)
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

    func testLinksAndExistingResourcesSurviveEndAndReload() throws {
        let original = makeSession()
        try store(active: original)
        let manager = FocusSessionManager(userDefaults: suite)

        guard case .added(let linkID) = manager.addTaskURL(
            urlString: "https://example.com/guide", title: "使用说明", to: original.id
        ) else { return XCTFail("应添加链接") }
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
        XCTAssertEqual(restored.history.first?.scheduledEndAt, original.scheduledEndAt)
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

    func testFailedLinkWritesPreserveEntireStoreAndBlockFurtherWrites() throws {
        let link = try XCTUnwrap(LinkedTaskURL.make(urlString: "https://example.com/original", title: "原网页"))
        let active = makeSession(links: [link])
        let historical = makeSession(state: .ended, links: [link])
        try store(active: active, history: [historical])
        let originalData = suite.data(forKey: Self.storageKey)
        let operations: [(FocusSessionManager) -> Bool] = [
            { $0.addTaskURL(urlString: "https://example.com/new", title: "新增", to: active.id) != .saveFailed },
            { $0.addTaskURL(urlString: "https://example.com/new", title: "新增", to: historical.id) != .saveFailed },
            { $0.unlinkTaskURL(id: link.id, from: active.id) },
            { $0.unlinkTaskURL(id: link.id, from: historical.id) }
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

    func testCoordinatorAddsOpensAndUnlinksHistoricalLinkWithoutChangingActiveTask() throws {
        let historical = makeSession(state: .ended)
        let active = makeSession()
        try store(active: active, history: [historical])
        let manager = FocusSessionManager(userDefaults: suite)
        var opened: [URL] = []
        let resources = TaskLinkCoordinator(manager: manager, openURL: { opened.append($0); return true })

        XCTAssertTrue(resources.addTaskURL(urlString: " HTTPS://EXAMPLE.COM:443 ", title: "历史资料", to: historical.id))
        let link = try XCTUnwrap(manager.session(id: historical.id)?.taskURLs.first)
        XCTAssertTrue(resources.openTaskURL(id: link.id, in: historical.id))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/"])
        XCTAssertNil(resources.errorMessage)
        XCTAssertTrue(resources.unlinkTaskURL(id: link.id, from: historical.id))
        XCTAssertTrue(manager.session(id: historical.id)?.taskURLs.isEmpty == true)
        XCTAssertEqual(manager.activeSession, active)
        XCTAssertEqual(FocusSessionManager(userDefaults: suite).history, manager.history)
    }

    func testCoordinatorReportsInvalidDuplicateLimitAndMissingTaskOnAdd() throws {
        let links = (0..<20).map { makeLink(path: "\($0)") }
        let session = makeSession(links: links)
        try store(active: session)
        var writes = 0
        let manager = FocusSessionManager(userDefaults: suite, writeData: { _ in writes += 1 })
        let resources = makeResources(manager: manager)

        XCTAssertFalse(resources.addTaskURL(urlString: "file:///tmp/file", title: "无效", to: session.id))
        XCTAssertEqual(resources.errorMessage, L10n.flowInvalidWebLink)
        XCTAssertFalse(resources.addTaskURL(urlString: links[0].urlString, title: "重复", to: session.id))
        XCTAssertEqual(resources.errorMessage, L10n.flowWebLinkExists)
        XCTAssertFalse(resources.addTaskURL(urlString: "https://example.com/new", title: "满额", to: session.id))
        XCTAssertEqual(resources.errorMessage, L10n.flowWebLinkLimit)
        XCTAssertFalse(resources.addTaskURL(urlString: "https://example.com/new", title: "任务缺失", to: UUID()))
        XCTAssertEqual(resources.errorMessage, L10n.flowResourceTaskMissing)
        XCTAssertFalse(resources.unlinkTaskURL(id: links[0].id, from: UUID()))
        XCTAssertEqual(resources.errorMessage, L10n.flowResourceTaskMissing)
        resources.clearError()
        XCTAssertNil(resources.errorMessage)
        XCTAssertEqual(manager.activeSession, session)
        XCTAssertEqual(writes, 0)
    }

    func testCoordinatorRevalidatesStoredLinksAndReportsOpenFailuresWithoutWriting() throws {
        let invalid = LinkedTaskURL(id: UUID(), title: "旧链接", urlString: "file:///tmp/private")
        let valid = makeLink()
        let session = makeSession(links: [invalid, valid])
        try store(active: session)
        var writes = 0
        var opened: [URL] = []
        let manager = FocusSessionManager(userDefaults: suite, writeData: { _ in writes += 1 })
        let resources = TaskLinkCoordinator(manager: manager, openURL: { opened.append($0); return false })

        XCTAssertFalse(resources.openTaskURL(id: invalid.id, in: session.id))
        XCTAssertEqual(resources.errorMessage, L10n.flowWebLinkUnavailable)
        XCTAssertFalse(resources.openTaskURL(id: UUID(), in: session.id))
        XCTAssertFalse(resources.openTaskURL(id: valid.id, in: UUID()))
        XCTAssertTrue(opened.isEmpty)
        XCTAssertFalse(resources.openTaskURL(id: valid.id, in: session.id))
        XCTAssertEqual(resources.errorMessage, L10n.flowWebLinkUnavailable)
        XCTAssertEqual(opened.map(\.absoluteString), [valid.urlString])
        XCTAssertEqual(manager.activeSession, session)
        XCTAssertEqual(writes, 0)
    }

    func testCoordinatorAddAndUnlinkKeepStorageFailureAndPreserveSnapshots() throws {
        let link = makeLink()
        let session = makeSession(links: [link])
        try store(active: session)
        let manager = FocusSessionManager(userDefaults: suite, writeData: { _ in throw CocoaError(.fileWriteNoPermission) })
        let resources = makeResources(manager: manager)

        XCTAssertFalse(resources.addTaskURL(urlString: "https://example.com/new", title: "未保存", to: session.id))
        XCTAssertEqual(resources.errorMessage, L10n.flowStorageWriteError)
        XCTAssertFalse(resources.unlinkTaskURL(id: link.id, from: session.id))
        XCTAssertEqual(resources.errorMessage, L10n.flowStorageWriteError)
        XCTAssertEqual(manager.activeSession, session)
        suite.set(Data("corrupt".utf8), forKey: Self.storageKey)
        XCTAssertFalse(manager.retryLoadingStorage())
        XCTAssertFalse(resources.addTaskURL(urlString: "https://example.com/new", title: "未保存", to: session.id))
        XCTAssertEqual(resources.errorMessage, L10n.flowStorageReadError)
        XCTAssertFalse(resources.unlinkTaskURL(id: link.id, from: session.id))
        XCTAssertEqual(resources.errorMessage, L10n.flowStorageReadError)
        XCTAssertEqual(manager.activeSession, session)
    }

    private func makeLink(path: String = "original") -> LinkedTaskURL {
        LinkedTaskURL(id: UUID(), title: "原网页", urlString: "https://example.com/\(path)")
    }

    private func makeSession(state: FocusSession.State = .active, links: [LinkedTaskURL] = []) -> FocusSession {
        let id = UUID()
        return FocusSession(
            id: id, title: "编辑资料任务", eventIdentifier: "event-\(id.uuidString)",
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

    private func makeResources(manager: FocusSessionManager) -> TaskLinkCoordinator {
        TaskLinkCoordinator(manager: manager, openURL: { _ in
            XCTFail("链接编辑不能打开浏览器")
            return false
        })
    }
}
