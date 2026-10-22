import XCTest
@testable import XNook

@MainActor
final class NookFlowActionsTests: XCTestCase {
    func testTaskResourcesCanBeRecoveredAfterEndingAndReloading() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "XNook.WorkflowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let notesURL = directory.appendingPathComponent("notes.json")
        let trayURL = directory.appendingPathComponent("tray.json")
        let fileURL = directory.appendingPathComponent("assignment.txt")
        try Data("course material".utf8).write(to: fileURL)
        let sessions = FocusSessionManager(userDefaults: defaults)
        let notes = NotesManager(storageURL: notesURL)
        let tray = TrayManager(storageURL: trayURL, resolveBookmark: { data in
            (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
        }, makeBookmark: { Data($0.path.utf8) })
        let actions = NookFlowActions(sessions: sessions, notes: notes, tray: tray)

        XCTAssertNotNil(sessions.start(title: "Course review"))
        XCTAssertTrue(actions.createLinkedNote())
        let noteID = try XCTUnwrap(sessions.activeSession?.linkedNote?.id)
        let noteCount = notes.notes.count
        XCTAssertTrue(actions.createLinkedNote())
        XCTAssertEqual(notes.notes.count, noteCount)
        XCTAssertEqual(sessions.activeSession?.linkedNote?.id, noteID)
        notes.updateCurrentNoteContent("Remember the key conclusions")
        XCTAssertTrue(notes.closeEditor())
        tray.addFile(from: fileURL)
        actions.linkTrayFiles()
        sessions.end()
        // 清理文件架后，任务中仍有独立文件访问凭据。
        tray.removeFile(try XCTUnwrap(tray.files.first))

        let reloaded = FocusSessionManager(userDefaults: defaults)
        let restoredNotes = NotesManager(storageURL: notesURL)
        let record = try XCTUnwrap(reloaded.history.first)
        XCTAssertEqual(record.linkedNote?.id, noteID)
        XCTAssertTrue(NookFlowActions(sessions: reloaded, notes: restoredNotes, tray: tray).openNote(noteID))
        XCTAssertEqual(restoredNotes.currentNote?.content, "Remember the key conclusions")
        var openedURL: URL?
        XCTAssertTrue(LinkedFileAccess.open(try XCTUnwrap(record.linkedFiles.first), fallbackBookmark: nil,
            resolve: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)) },
            openURL: { openedURL = $0; return true }))
        XCTAssertEqual(openedURL, fileURL)
    }

    func testLegacyFileUsesTrayBookmarkAndUnavailableFileReturnsFailure() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let record = LinkedFile(id: UUID(), name: "Legacy", icon: "doc")
        let fallback = Data([1])
        var openCount = 0
        XCTAssertTrue(LinkedFileAccess.open(record, fallbackBookmark: fallback,
            resolve: { $0 == fallback ? fileURL : nil }, openURL: { _ in openCount += 1; return true }))
        XCTAssertFalse(LinkedFileAccess.open(record, fallbackBookmark: nil,
            resolve: { _ in XCTFail("没有书签不能解析"); return nil }, openURL: { _ in true }))
        try FileManager.default.removeItem(at: fileURL)
        XCTAssertFalse(LinkedFileAccess.open(record, fallbackBookmark: fallback,
            resolve: { _ in fileURL }, openURL: { _ in openCount += 1; return true }))
        XCTAssertEqual(openCount, 1)
    }
}
