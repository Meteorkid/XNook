import XCTest
@testable import XNook

@MainActor
final class FocusResourceCoordinatorTests: XCTestCase {
    func testTrayBatchWritesOnceAndKeepsBookmarksForHistory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = try XCTUnwrap(fixture.manager.start(title: "批量资料"))
        fixture.tray.files = (0..<20).map { index in
            TrayManager.TrayFile(id: UUID(), bookmarkData: Data([UInt8(index)]), name: "文件\(index)", icon: "doc", size: 1, addedAt: Date())
        }
        fixture.faults.taskWrites = 0
        let resources = fixture.resources()
        XCTAssertTrue(resources.linkTrayFiles(to: session.id))
        XCTAssertEqual(fixture.faults.taskWrites, 1)
        XCTAssertEqual(fixture.manager.activeSession?.linkedFiles.map(\.bookmarkData), fixture.tray.files.map { Optional($0.bookmarkData) })
        XCTAssertTrue(resources.linkTrayFiles(to: session.id))
        XCTAssertEqual(fixture.faults.taskWrites, 1)
        fixture.manager.end()
        fixture.tray.files = []
        XCTAssertEqual(FocusSessionManager(userDefaults: fixture.defaults).history.first?.linkedFiles.count, 20)
    }

    func testUnsavedNewNoteIsNotLinkedAndRetryReusesDraft() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = try XCTUnwrap(fixture.manager.start(title: "保存失败"))
        let resources = fixture.resources()
        fixture.faults.notesFail = true
        XCTAssertFalse(resources.createNote(in: session.id))
        let draftID = try XCTUnwrap(fixture.notes.currentNote?.id)
        XCTAssertNil(fixture.manager.activeSession?.linkedNote)
        XCTAssertEqual(fixture.notes.notes.count, 1)
        XCTAssertNotNil(resources.errorMessage)
        fixture.faults.notesFail = false
        XCTAssertTrue(resources.createNote(in: session.id))
        XCTAssertEqual(fixture.notes.notes.count, 1)
        XCTAssertEqual(fixture.manager.activeSession?.linkedNote?.id, draftID)
        XCTAssertEqual(NotesManager(storageURL: fixture.notesURL).notes.first?.id, draftID)
    }

    func testTaskCommitFailureKeepsSavedNoteAndRetryDoesNotDuplicateIt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = try XCTUnwrap(fixture.manager.start(title: "关联失败"))
        let before = fixture.defaults.data(forKey: "nookflow.sessions")
        let resources = fixture.resources()
        fixture.faults.taskFail = true
        XCTAssertFalse(resources.createNote(in: session.id))
        XCTAssertNil(fixture.manager.activeSession?.linkedNote)
        XCTAssertEqual(fixture.defaults.data(forKey: "nookflow.sessions"), before)
        let noteID = try XCTUnwrap(fixture.notes.notes.first?.id)
        XCTAssertEqual(NotesManager(storageURL: fixture.notesURL).notes.first?.id, noteID)
        XCTAssertEqual(resources.errorMessage, L10n.flowResourceNoteKept)

        fixture.faults.taskFail = false
        fixture.manager.retryLoadingStorage()
        XCTAssertTrue(fixture.notes.closeEditor())
        XCTAssertTrue(resources.createNote(in: session.id))
        XCTAssertEqual(fixture.notes.notes.count, 1)
        XCTAssertEqual(fixture.notes.currentNote?.id, noteID)
        XCTAssertEqual(fixture.manager.activeSession?.linkedNote?.id, noteID)
    }

    func testDeletedNoteCanBeUnlinkedAndReplacedWithoutChangingOtherSession() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let historical = try XCTUnwrap(fixture.manager.start(title: "历史"))
        let missingID = UUID()
        fixture.manager.linkNote(id: missingID, title: "已删除")
        fixture.manager.end()
        let active = try XCTUnwrap(fixture.manager.start(title: "当前"))
        let resources = fixture.resources()
        XCTAssertFalse(resources.openNote(in: historical.id))
        XCTAssertEqual(resources.errorMessage, L10n.flowNoteUnavailable)
        XCTAssertTrue(resources.unlinkNote(in: historical.id))
        let replacement = try XCTUnwrap(fixture.notes.createNote(title: "保留笔记", content: "正文"))
        XCTAssertTrue(resources.linkNote(id: replacement.id, to: historical.id))
        XCTAssertEqual(fixture.manager.history.first?.linkedNote?.id, replacement.id)
        XCTAssertNil(fixture.manager.activeSession?.linkedNote)
        XCTAssertEqual(fixture.manager.activeSession?.id, active.id)
        XCTAssertEqual(fixture.notes.notes.first?.content, "正文")
    }

    func testUnsavedEditorIsNotMisreportedAsMissingLinkedNote() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let linked = try XCTUnwrap(fixture.notes.createNote(title: "目标", content: "已保存"))
        let current = try XCTUnwrap(fixture.notes.createNote(title: "当前", content: "旧内容"))
        let session = try XCTUnwrap(fixture.manager.start(title: "任务"))
        fixture.manager.linkNote(id: linked.id, title: linked.title)
        fixture.faults.notesFail = true
        fixture.notes.updateCurrentNoteContent("不能丢的编辑")
        let resources = fixture.resources()
        XCTAssertFalse(resources.openNote(in: session.id))
        XCTAssertEqual(fixture.notes.currentNote?.id, current.id)
        XCTAssertEqual(fixture.notes.currentNote?.content, "不能丢的编辑")
        XCTAssertEqual(resources.errorMessage, fixture.notes.storageErrorMessage)
        XCTAssertNotEqual(resources.errorMessage, L10n.flowNoteUnavailable)
        fixture.faults.notesFail = false
        XCTAssertTrue(resources.openNote(in: session.id))
        XCTAssertEqual(fixture.notes.currentNote?.id, linked.id)
    }

    func testSnapshotOpensWithoutTrayAndBalancesAccessOnOpenFailure() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = try XCTUnwrap(fixture.manager.start(title: "独立资料"))
        let fileID = UUID(), bookmark = Data([1, 2, 3])
        fixture.manager.linkFile(id: fileID, name: "资料", icon: "doc", bookmarkData: bookmark)
        fixture.manager.end()
        var accessCount = 0, stopCount = 0, openCount = 0
        let resources = fixture.resources(
            resolve: { data in XCTAssertEqual(data, bookmark); return (fixture.directory.appendingPathComponent("资料"), false) },
            open: { _ in openCount += 1; return false },
            start: { _ in accessCount += 1; return true }, stop: { _ in stopCount += 1 }
        )
        XCTAssertFalse(resources.openFile(id: fileID, in: session.id))
        XCTAssertEqual([accessCount, stopCount, openCount], [1, 1, 1])
        XCTAssertEqual(resources.errorMessage, L10n.flowFileUnavailable)
        XCTAssertEqual(fixture.manager.history.first?.linkedFiles.first?.bookmarkData, bookmark)
    }

    func testLegacyBookmarkFallsBackToTrayButExplicitBrokenSnapshotDoesNot() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = try XCTUnwrap(fixture.manager.start(title: "旧记录"))
        let fileID = UUID(), bookmark = Data([9])
        fixture.manager.linkFile(id: fileID, name: "旧文件", icon: "doc")
        fixture.tray.files = [.init(id: fileID, bookmarkData: bookmark, name: "文件", icon: "doc", size: 1, addedAt: Date())]
        var opens = 0
        let resources = fixture.resources(resolve: { data in
            data == bookmark ? (fixture.directory.appendingPathComponent("文件"), false) : nil
        }, open: { _ in opens += 1; return true })
        XCTAssertTrue(resources.openFile(id: fileID, in: session.id))
        XCTAssertEqual(opens, 1)
        XCTAssertTrue(fixture.manager.replaceLinkedFile(.init(id: fileID, name: "原快照", icon: "doc", bookmarkData: Data([0])), in: session.id))
        XCTAssertFalse(resources.openFile(id: fileID, in: session.id))
        XCTAssertEqual(opens, 1)
    }

    func testReselectingFileUpdatesOnlyTargetAndFailureKeepsOriginal() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = try XCTUnwrap(fixture.manager.start(title: "历史资料"))
        let fileID = UUID(), original = Data([0]), replacement = Data([7])
        fixture.manager.linkFile(id: fileID, name: "失效文件", icon: "doc", bookmarkData: original)
        fixture.manager.end()
        let active = try XCTUnwrap(fixture.manager.start(title: "新任务"))
        var stops = 0
        let resources = fixture.resources(make: { _ in replacement }, start: { _ in true }, stop: { _ in stops += 1 })
        let url = fixture.directory.appendingPathComponent("替换.pdf")
        fixture.faults.taskFail = true
        XCTAssertFalse(resources.replaceFile(id: fileID, in: session.id, with: url))
        XCTAssertEqual(fixture.manager.history.first?.linkedFiles.first?.bookmarkData, original)
        XCTAssertEqual(stops, 1)
        fixture.faults.taskFail = false
        fixture.manager.retryLoadingStorage()
        XCTAssertTrue(resources.replaceFile(id: fileID, in: session.id, with: url))
        XCTAssertEqual(fixture.manager.history.first?.linkedFiles.first?.bookmarkData, replacement)
        XCTAssertEqual(fixture.manager.history.first?.linkedFiles.first?.name, "替换.pdf")
        XCTAssertEqual(fixture.manager.activeSession?.id, active.id)
        XCTAssertEqual(stops, 2)
        XCTAssertTrue(fixture.tray.files.isEmpty)
    }

    func testBookmarkCreationFailureAndInvalidDestinationPreserveAssociation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = try XCTUnwrap(fixture.manager.start(title: "选择失败"))
        let fileID = UUID()
        fixture.manager.linkFile(id: fileID, name: "原文件", icon: "doc", bookmarkData: Data([1]))
        let before = fixture.manager.activeSession
        var starts = 0, stops = 0
        let resources = fixture.resources(make: { _ in throw CocoaError(.fileReadNoPermission) },
                                          start: { _ in starts += 1; return true }, stop: { _ in stops += 1 })
        XCTAssertFalse(resources.replaceFile(id: fileID, in: session.id, with: URL(string: "https://example.com/file")!))
        XCTAssertEqual(starts, 0)
        XCTAssertFalse(resources.replaceFile(id: fileID, in: session.id, with: fixture.directory.appendingPathComponent("file")))
        XCTAssertEqual(starts, stops)
        XCTAssertEqual(fixture.manager.activeSession, before)
        XCTAssertEqual(resources.errorMessage, L10n.flowResourceBookmarkFailure)
    }

    func testTaskURLAddPersistsNormalizedSnapshotAndClearsInvalidInputFeedback() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = try XCTUnwrap(fixture.manager.start(title: "网页资料"))
        let resources = fixture.resources()
        fixture.faults.taskWrites = 0

        XCTAssertFalse(resources.addTaskURL(urlString: "file:///tmp/private", title: "说明", to: session.id))
        XCTAssertEqual(resources.errorMessage, L10n.flowInvalidWebLink)
        XCTAssertEqual(fixture.faults.taskWrites, 0)
        XCTAssertTrue(resources.addTaskURL(urlString: " HTTPS://EXAMPLE.COM:443/guide ", title: " 使用说明 ", to: session.id))
        let link = try XCTUnwrap(fixture.manager.activeSession?.taskURLs.first)
        XCTAssertEqual(link.urlString, "https://example.com/guide")
        XCTAssertEqual(link.title, "使用说明")
        XCTAssertNil(resources.errorMessage)
        XCTAssertEqual(fixture.faults.taskWrites, 1)
        XCTAssertEqual(FocusSessionManager(userDefaults: fixture.defaults).activeSession?.taskURLs, [link])
    }

    func testDuplicateTaskURLKeepsOriginalNameAndReportsInputFeedbackWithoutWriting() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = try XCTUnwrap(fixture.manager.start(title: "重复资料"))
        let resources = fixture.resources()
        XCTAssertTrue(resources.addTaskURL(urlString: "https://example.com/", title: "原名称", to: session.id))
        let original = fixture.manager.activeSession
        let stored = fixture.defaults.data(forKey: "nookflow.sessions")
        fixture.faults.taskWrites = 0

        XCTAssertFalse(resources.addTaskURL(urlString: " HTTPS://EXAMPLE.COM:443 ", title: "新名称", to: session.id))
        XCTAssertEqual(resources.errorMessage, L10n.flowWebLinkExists)
        XCTAssertEqual(fixture.manager.activeSession, original)
        XCTAssertEqual(fixture.manager.activeSession?.taskURLs.first?.title, "原名称")
        XCTAssertEqual(fixture.defaults.data(forKey: "nookflow.sessions"), stored)
        XCTAssertEqual(fixture.faults.taskWrites, 0)
    }

    func testHistoricalTaskURLAddAndUnlinkOnlyChangeExplicitSession() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let historical = try XCTUnwrap(fixture.manager.start(title: "目标历史", scheduledEndAt: Date(timeIntervalSinceReferenceDate: 1000)))
        XCTAssertTrue(fixture.manager.end())
        var expected = try XCTUnwrap(fixture.manager.session(id: historical.id))
        let other = try XCTUnwrap(fixture.manager.start(title: "另一历史"))
        XCTAssertTrue(fixture.manager.end())
        let otherSnapshot = try XCTUnwrap(fixture.manager.session(id: other.id))
        let active = try XCTUnwrap(fixture.manager.start(title: "当前任务"))
        let resources = fixture.resources()

        XCTAssertTrue(resources.addTaskURL(urlString: "https://example.com/history", title: "历史资料", to: historical.id))
        let link = try XCTUnwrap(fixture.manager.session(id: historical.id)?.taskURLs.first)
        expected.linkedURLs = [link]
        XCTAssertEqual(fixture.manager.history, [otherSnapshot, expected])
        XCTAssertEqual(fixture.manager.activeSession, active)
        XCTAssertTrue(resources.unlinkTaskURL(id: link.id, from: historical.id))
        expected.linkedURLs = []
        XCTAssertEqual(fixture.manager.history, [otherSnapshot, expected])
        XCTAssertEqual(fixture.manager.activeSession, active)
        XCTAssertNil(resources.errorMessage)
        XCTAssertEqual(FocusSessionManager(userDefaults: fixture.defaults).history, fixture.manager.history)
    }

    func testTaskURLManualOpenUsesInjectedOpenerWithoutFileSecurityScope() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = try XCTUnwrap(fixture.manager.start(title: "手动打开"))
        var opened: [URL] = []
        var shouldOpen = true
        let resources = fixture.resources(
            resolve: { _ in XCTFail("Web links must not resolve file bookmarks"); return nil },
            make: { _ in XCTFail("Web links must not create file bookmarks"); return Data() },
            open: { opened.append($0); return shouldOpen },
            start: { _ in XCTFail("Web links must not acquire file scope"); return false },
            stop: { _ in XCTFail("Web links must not release file scope") }
        )
        XCTAssertTrue(resources.addTaskURL(urlString: "https://example.com/guide", title: "说明", to: session.id))
        XCTAssertTrue(opened.isEmpty)
        let link = try XCTUnwrap(fixture.manager.activeSession?.taskURLs.first)
        XCTAssertTrue(fixture.manager.end())
        let historical = fixture.manager.history
        fixture.faults.taskWrites = 0

        XCTAssertTrue(resources.openTaskURL(id: link.id, in: session.id))
        XCTAssertEqual(opened.map(\.absoluteString), [link.urlString])
        shouldOpen = false
        XCTAssertFalse(resources.openTaskURL(id: link.id, in: session.id))
        XCTAssertEqual(resources.errorMessage, L10n.flowWebLinkUnavailable)
        shouldOpen = true
        XCTAssertTrue(resources.openTaskURL(id: link.id, in: session.id))
        XCTAssertNil(resources.errorMessage)
        XCTAssertEqual(opened.count, 3)
        XCTAssertEqual(fixture.manager.history, historical)
        XCTAssertEqual(fixture.faults.taskWrites, 0)
    }

    func testUnsafeStoredTaskURLsAreRevalidatedBeforeOpening() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var session = try XCTUnwrap(fixture.manager.start(title: "旧网页记录"))
        session.linkedURLs = [
            "file:///tmp/private", "javascript:alert(1)",
            "data:text/html,private", "https://name:password@example.com"
        ].map { LinkedTaskURL(id: UUID(), title: "旧链接", urlString: $0) }
        fixture.defaults.set(try JSONEncoder().encode(FocusSessionStore(activeSession: session, history: [])), forKey: "nookflow.sessions")
        XCTAssertTrue(fixture.manager.retryLoadingStorage())
        let stored = fixture.defaults.data(forKey: "nookflow.sessions")
        let resources = fixture.resources(
            open: { _ in XCTFail("Unsafe stored URL must not reach the opener"); return true },
            start: { _ in XCTFail("Unsafe URL must not acquire file scope"); return false }
        )
        fixture.faults.taskWrites = 0

        for link in session.taskURLs {
            XCTAssertFalse(resources.openTaskURL(id: link.id, in: session.id), link.urlString)
            XCTAssertEqual(resources.errorMessage, L10n.flowWebLinkUnavailable)
        }
        XCTAssertEqual(fixture.manager.activeSession, session)
        XCTAssertEqual(fixture.defaults.data(forKey: "nookflow.sessions"), stored)
        XCTAssertEqual(fixture.faults.taskWrites, 0)
    }

    func testFailedTaskURLAddAndUnlinkKeepSnapshotsAndReportStorageError() throws {
        for unlink in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let historical = try XCTUnwrap(fixture.manager.start(title: "历史网页"))
            let resources = fixture.resources()
            XCTAssertTrue(resources.addTaskURL(urlString: "https://example.com/original", title: "原网页", to: historical.id))
            let link = try XCTUnwrap(fixture.manager.activeSession?.taskURLs.first)
            XCTAssertTrue(fixture.manager.end())
            let active = try XCTUnwrap(fixture.manager.start(title: "当前任务"))
            let history = fixture.manager.history
            let stored = fixture.defaults.data(forKey: "nookflow.sessions")
            fixture.faults.taskWrites = 0
            fixture.faults.taskFail = true

            let saved = unlink
                ? resources.unlinkTaskURL(id: link.id, from: historical.id)
                : resources.addTaskURL(urlString: "https://example.com/new", title: "新增网页", to: historical.id)
            XCTAssertFalse(saved)
            XCTAssertEqual(resources.errorMessage, try XCTUnwrap(fixture.manager.storageError))
            XCTAssertEqual(fixture.manager.activeSession, active)
            XCTAssertEqual(fixture.manager.history, history)
            XCTAssertEqual(fixture.defaults.data(forKey: "nookflow.sessions"), stored)
            XCTAssertFalse(resources.addTaskURL(urlString: "https://example.com/retry", title: "再次添加", to: historical.id))
            XCTAssertEqual(fixture.faults.taskWrites, 1)
        }
    }

    func testHistoricalBudgetCannotBeChangedOrCleared() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let historical = try XCTUnwrap(fixture.manager.start(title: "已完成计划", scheduledEndAt: Date(timeIntervalSinceReferenceDate: 1000)))
        XCTAssertTrue(fixture.manager.end())
        let active = try XCTUnwrap(fixture.manager.start(title: "当前计划", scheduledEndAt: Date(timeIntervalSinceReferenceDate: 2000)))
        let history = fixture.manager.history
        let stored = fixture.defaults.data(forKey: "nookflow.sessions")
        let resources = fixture.resources()
        fixture.faults.taskWrites = 0

        for minutes in [30, nil] as [Int?] {
            XCTAssertFalse(resources.setTimeBudget(minutes: minutes, in: historical.id))
            XCTAssertEqual(resources.errorMessage, L10n.flowBudgetHistoryReadOnly)
        }
        XCTAssertEqual(fixture.manager.activeSession, active)
        XCTAssertEqual(fixture.manager.history, history)
        XCTAssertEqual(fixture.defaults.data(forKey: "nookflow.sessions"), stored)
        XCTAssertEqual(fixture.faults.taskWrites, 0)
    }

    func testInvalidActiveBudgetKeepsPlanAndSuccessfulClearResetsFeedback() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = try XCTUnwrap(fixture.manager.start(title: "当前计划", scheduledEndAt: Date(timeIntervalSinceReferenceDate: 2000)))
        let stored = fixture.defaults.data(forKey: "nookflow.sessions")
        let resources = fixture.resources()
        fixture.faults.taskWrites = 0

        for minutes in [-1, 0, 1441, Int.max] {
            XCTAssertFalse(resources.setTimeBudget(minutes: minutes, in: session.id))
            XCTAssertEqual(resources.errorMessage, L10n.flowBudgetInvalid)
        }
        XCTAssertEqual(fixture.manager.activeSession, session)
        XCTAssertEqual(fixture.defaults.data(forKey: "nookflow.sessions"), stored)
        XCTAssertEqual(fixture.faults.taskWrites, 0)
        XCTAssertTrue(resources.setTimeBudget(minutes: nil, in: session.id))
        var expected = session
        expected.scheduledEndAt = nil
        XCTAssertEqual(fixture.manager.activeSession, expected)
        XCTAssertNil(resources.errorMessage)
        XCTAssertEqual(fixture.faults.taskWrites, 1)
        XCTAssertEqual(FocusSessionManager(userDefaults: fixture.defaults).activeSession, expected)
    }

    func testFailedActiveBudgetChangeAndClearKeepOriginalPlan() throws {
        for minutes in [30, nil] as [Int?] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let session = try XCTUnwrap(fixture.manager.start(title: "不能丢的计划", scheduledEndAt: Date(timeIntervalSinceReferenceDate: 2000)))
            let stored = fixture.defaults.data(forKey: "nookflow.sessions")
            let resources = fixture.resources()
            fixture.faults.taskWrites = 0
            fixture.faults.taskFail = true

            XCTAssertFalse(resources.setTimeBudget(minutes: minutes, in: session.id))
            XCTAssertEqual(resources.errorMessage, try XCTUnwrap(fixture.manager.storageError))
            XCTAssertEqual(fixture.manager.activeSession, session)
            XCTAssertEqual(fixture.defaults.data(forKey: "nookflow.sessions"), stored)
            XCTAssertFalse(resources.setTimeBudget(minutes: 60, in: session.id))
            XCTAssertEqual(fixture.faults.taskWrites, 1)
        }
    }

    private final class Faults {
        var notesFail = false
        var taskFail = false
        var taskWrites = 0
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let notesURL: URL
        let defaults: UserDefaults
        let suiteName: String
        let faults = Faults()
        let manager: FocusSessionManager
        let notes: NotesManager
        let tray: TrayManager

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("XNookResources-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            notesURL = directory.appendingPathComponent("notes.json")
            try Data("[]".utf8).write(to: notesURL)
            suiteName = "XNook.Resources.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            let state = faults, storage = defaults
            notes = NotesManager(storageURL: notesURL, saveDelay: 60, writeData: { data, url in
                if state.notesFail { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: url, options: .atomic)
            })
            tray = TrayManager(storageURL: directory.appendingPathComponent("tray.json"), resolveBookmark: { _ in nil }, makeBookmark: { _ in Data() })
            manager = FocusSessionManager(userDefaults: defaults, writeData: { data in
                state.taskWrites += 1
                if state.taskFail { throw CocoaError(.fileWriteNoPermission) }
                storage.set(data, forKey: "nookflow.sessions")
            })
        }

        func resources(
            resolve: @escaping (Data) -> (url: URL, isStale: Bool)? = { _ in nil },
            make: @escaping (URL) throws -> Data = { _ in Data([4]) },
            open: @escaping (URL) -> Bool = { _ in XCTFail("No real file open allowed"); return false },
            start: @escaping (URL) -> Bool = { _ in false },
            stop: @escaping (URL) -> Void = { _ in XCTFail("Scope was not acquired") }
        ) -> FocusResourceCoordinator {
            FocusResourceCoordinator(manager: manager, notes: notes, tray: tray, resolveBookmark: resolve,
                                     makeBookmark: make, openURL: open, isReachable: { _ in true }, startAccess: start, stopAccess: stop)
        }

        func cleanUp() {
            faults.notesFail = false
            _ = notes.closeEditor()
            defaults.removePersistentDomain(forName: suiteName)
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Temporary fixture cleanup failed: \(error)") }
        }
    }
}
