import XCTest
@testable import XNook

@MainActor
final class NotesManagerTests: XCTestCase {
    private var directory: URL!
    private var storageURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("XNookNotesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storageURL = directory.appendingPathComponent("notes.json")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        directory = nil
        storageURL = nil
    }

    func testFirstLaunchCreatesPersistedWelcomeNotes() throws {
        let manager = NotesManager(storageURL: storageURL)

        XCTAssertFalse(manager.notes.isEmpty)
        XCTAssertEqual(try savedNotes().map(\.id), manager.notes.map(\.id))
        XCTAssertNil(manager.storageErrorMessage)
    }

    func testMalformedStorageIsNeverAutomaticallyOverwritten() throws {
        let original = Data("original notes that cannot be decoded".utf8)
        try original.write(to: storageURL)

        let manager = NotesManager(storageURL: storageURL)
        XCTAssertTrue(manager.notes.isEmpty)
        XCTAssertTrue(manager.isStorageReadOnly)
        XCTAssertNotNil(manager.storageErrorMessage)
        XCTAssertEqual(try Data(contentsOf: storageURL), original)

        // NookFlow 等调用方必须获知创建失败，不能关联一个不会保存的笔记。
        XCTAssertNil(manager.createNote(title: "Pending recovery", content: "Keep this draft"))
        XCTAssertFalse(manager.flushPendingChanges())
        XCTAssertEqual(try Data(contentsOf: storageURL), original)
        XCTAssertTrue(manager.notes.isEmpty)
        XCTAssertNil(manager.currentNote)
        XCTAssertFalse(manager.isEditing)
    }

    func testReadFailureDoesNotCreateWelcomeNotes() throws {
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: false)
        let manager = NotesManager(storageURL: storageURL)

        XCTAssertTrue(manager.notes.isEmpty)
        XCTAssertNotNil(manager.storageErrorMessage)
        XCTAssertTrue(manager.isStorageReadOnly)
    }

    func testReloadFailurePreservesLoadedNotesAndCurrentEditor() throws {
        let note = NotesManager.Note(title: "Existing", content: "Important notes")
        try store([note])
        let manager = NotesManager(storageURL: storageURL)
        manager.selectNote(note)
        let damaged = Data("damaged after initial load".utf8)
        try damaged.write(to: storageURL)

        manager.loadNotes()

        XCTAssertEqual(manager.notes.first?.content, note.content)
        XCTAssertEqual(manager.currentNote?.id, note.id)
        XCTAssertNotNil(manager.storageErrorMessage)
        XCTAssertEqual(try Data(contentsOf: storageURL), damaged)
    }

    func testDebouncedEditUpdatesMemoryImmediately() throws {
        var note = NotesManager.Note(title: "Draft", content: "Before")
        try store([note])
        let manager = NotesManager(storageURL: storageURL, saveDelay: 60)
        manager.selectNote(note)
        note.content = "After typing"

        manager.saveNoteDebounced(note)

        XCTAssertEqual(manager.notes.first?.content, "After typing")
        XCTAssertEqual(manager.currentNote?.content, "After typing")
        XCTAssertEqual(try savedNotes().first?.content, "Before")
        manager.flushPendingChanges()
    }

    func testEditsToDifferentNotesSurviveOneFlush() throws {
        var first = NotesManager.Note(title: "First", content: "Before first")
        var second = NotesManager.Note(title: "Second", content: "Before second")
        try store([first, second])
        let manager = NotesManager(storageURL: storageURL, saveDelay: 60)
        first.content = "After first"
        second.content = "After second"

        manager.saveNoteDebounced(first)
        manager.saveNoteDebounced(second)
        XCTAssertTrue(manager.flushPendingChanges())

        XCTAssertEqual(try savedNotes().map(\.content), ["After first", "After second"])
    }

    func testClosingEditorFlushesLatestContent() throws {
        var note = NotesManager.Note(title: "Draft", content: "Before")
        try store([note])
        let manager = NotesManager(storageURL: storageURL, saveDelay: 60)
        manager.selectNote(note)
        note.content = "Latest content"
        manager.saveNoteDebounced(note)

        manager.closeEditor()

        XCTAssertFalse(manager.isEditing)
        XCTAssertNil(manager.currentNote)
        XCTAssertEqual(try savedNotes().first?.content, "Latest content")
    }

    func testSelectingStaleNoteUsesItsLatestInMemoryContent() throws {
        let original = NotesManager.Note(title: "Draft", content: "Before")
        try store([original])
        let manager = NotesManager(storageURL: storageURL, saveDelay: 60)
        var edited = original
        edited.content = "Latest content"
        manager.saveNoteDebounced(edited)

        manager.selectNote(original)

        XCTAssertEqual(manager.currentNote?.content, "Latest content")
        manager.flushPendingChanges()
    }

    func testFailedSaveRetainsDraftAndRetriesSuccessfully() throws {
        var note = NotesManager.Note(title: "Draft", content: "Before")
        try store([note])
        var shouldFail = true
        let manager = NotesManager(storageURL: storageURL, writeData: { data, url in
            if shouldFail { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        note.content = "Unsaved changes"
        manager.saveNote(note)

        XCTAssertEqual(manager.notes.first?.content, "Unsaved changes")
        XCTAssertNotNil(manager.storageErrorMessage)
        XCTAssertEqual(try savedNotes().first?.content, "Before")

        shouldFail = false
        XCTAssertTrue(manager.retryPersistence())
        XCTAssertNil(manager.storageErrorMessage)
        XCTAssertEqual(try savedNotes().first?.content, "Unsaved changes")
    }

    func testExplicitRecoveryKeepsOriginalBackupBeforeSavingDrafts() throws {
        let original = Data("unreadable original".utf8)
        try original.write(to: storageURL)
        let manager = NotesManager(storageURL: storageURL)
        XCTAssertTrue(manager.recoverStorage())
        XCTAssertNotNil(manager.createNote(title: "Recovered draft", content: "New content"))

        let backupURL = try XCTUnwrap(manager.recoveryBackupURL)
        XCTAssertEqual(try Data(contentsOf: backupURL), original)
        XCTAssertEqual(try savedNotes().first?.content, "New content")
        XCTAssertNil(manager.storageErrorMessage)
        XCTAssertFalse(manager.isStorageReadOnly)
    }

    func testExplicitRecoveryDoesNotWriteWhenOriginalCannotBeBackedUp() throws {
        try Data("unreadable original".utf8).write(to: storageURL)
        var writes = 0
        let manager = NotesManager(storageURL: storageURL, writeData: { _, _ in writes += 1 })
        try FileManager.default.removeItem(at: storageURL)

        XCTAssertFalse(manager.recoverStorage())

        XCTAssertEqual(writes, 0)
        XCTAssertTrue(manager.isStorageReadOnly)
        XCTAssertNotNil(manager.storageErrorMessage)
    }

    func testFlushingWithoutChangesDoesNotRewriteStorage() throws {
        try store([NotesManager.Note(title: "Existing")])
        var writes = 0
        let manager = NotesManager(storageURL: storageURL, writeData: { _, _ in writes += 1 })

        XCTAssertTrue(manager.flushPendingChanges())
        manager.closeEditor()

        XCTAssertEqual(writes, 0)
    }

    func testDebounceWritesLatestContentAutomatically() async throws {
        var note = NotesManager.Note(title: "Draft", content: "Before")
        try store([note])
        let saved = expectation(description: "Debounced notes were written")
        let manager = NotesManager(storageURL: storageURL, saveDelay: 0.01, writeData: { data, url in
            try data.write(to: url, options: .atomic)
            saved.fulfill()
        })
        note.content = "Intermediate"
        manager.saveNoteDebounced(note)
        note.content = "Latest"
        manager.saveNoteDebounced(note)

        await fulfillment(of: [saved], timeout: 2)

        XCTAssertEqual(try savedNotes().first?.content, "Latest")
    }

    func testExplicitSaveCancelsOlderDebouncedWrite() async throws {
        var note = NotesManager.Note(title: "Draft", content: "Before")
        try store([note])
        let unexpectedWrite = expectation(description: "Old debounce must not write after explicit save")
        unexpectedWrite.isInverted = true
        var writes = 0
        let manager = NotesManager(storageURL: storageURL, saveDelay: 0.01, writeData: { data, url in
            writes += 1
            if writes > 1 { unexpectedWrite.fulfill() }
            try data.write(to: url, options: .atomic)
        })
        note.content = "Debounced draft"
        manager.saveNoteDebounced(note)
        note.content = "Explicit final version"
        manager.saveNote(note)

        await fulfillment(of: [unexpectedWrite], timeout: 0.1)

        XCTAssertEqual(try savedNotes().first?.content, "Explicit final version")
        XCTAssertEqual(writes, 1)
    }

    func testRetryReadLoadsRepairedOriginal() throws {
        try Data("malformed".utf8).write(to: storageURL)
        let manager = NotesManager(storageURL: storageURL)
        let repaired = NotesManager.Note(title: "Repaired", content: "Recovered original contents")
        try store([repaired])

        XCTAssertTrue(manager.retryPersistence())

        XCTAssertEqual(manager.notes.first?.content, repaired.content)
        XCTAssertNil(manager.storageErrorMessage)
        XCTAssertNil(manager.recoveryBackupURL)
    }

    func testTerminationFlushesPendingEdits() throws {
        var note = NotesManager.Note(title: "Draft", content: "Before")
        try store([note])
        let manager = NotesManager(storageURL: storageURL, saveDelay: 60)
        note.content = "Last keystrokes"
        manager.saveNoteDebounced(note)

        XCTAssertTrue(manager.prepareForTermination())
        XCTAssertEqual(try savedNotes().first?.content, "Last keystrokes")
    }

    func testTerminationIsBlockedOnlyWhenUnsavedEditsCannotBeWritten() throws {
        var note = NotesManager.Note(title: "Draft", content: "Before")
        try store([note])
        let manager = NotesManager(storageURL: storageURL, writeData: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        XCTAssertTrue(manager.prepareForTermination())
        note.content = "Unsaved"
        manager.saveNote(note)

        XCTAssertFalse(manager.prepareForTermination())
        XCTAssertEqual(manager.notes.first?.content, "Unsaved")
        XCTAssertEqual(try savedNotes().first?.content, "Before")
    }

    func testUnreadableStorageWithoutEditsDoesNotBlockTermination() throws {
        try Data("malformed".utf8).write(to: storageURL)
        let manager = NotesManager(storageURL: storageURL)

        XCTAssertTrue(manager.prepareForTermination())
        XCTAssertEqual(try Data(contentsOf: storageURL), Data("malformed".utf8))
    }

    func testSearchIncludesNotesBeyondOverviewAndMatchesTitleOrContent() throws {
        let notes = (0..<7).map { NotesManager.Note(title: "Note \($0)", content: "Body \($0)") }
        try store(notes)
        let manager = NotesManager(storageURL: storageURL)

        XCTAssertEqual(manager.filteredNotes(matching: "  \n").map(\.id), notes.map(\.id))
        XCTAssertEqual(manager.filteredNotes(matching: "  NOTE 6  ").map(\.id), [notes[6].id])
        XCTAssertEqual(manager.filteredNotes(matching: "body 5").map(\.id), [notes[5].id])
        XCTAssertTrue(manager.filteredNotes(matching: "not present").isEmpty)
    }

    func testSearchSupportsChineseContents() throws {
        let note = NotesManager.Note(title: "今天", content: "整理项目验收记录")
        try store([note])
        let manager = NotesManager(storageURL: storageURL)

        XCTAssertEqual(manager.filteredNotes(matching: "验收").map(\.id), [note.id])
    }

    func testRenameAndBodyEditsUseLatestDraftAndPersistTogether() throws {
        let note = NotesManager.Note(title: "Before", content: "Original body")
        try store([note])
        let manager = NotesManager(storageURL: storageURL, saveDelay: 60)
        XCTAssertTrue(manager.selectNote(id: note.id))

        manager.updateCurrentNoteContent("Updated body")
        manager.updateCurrentNoteTitle("After")
        manager.updateCurrentNoteContent("Final body")

        XCTAssertEqual(manager.currentNote?.title, "After")
        XCTAssertEqual(manager.currentNote?.content, "Final body")
        XCTAssertTrue(manager.closeEditor())
        let reloaded = NotesManager(storageURL: storageURL)
        XCTAssertEqual(reloaded.notes.first?.title, "After")
        XCTAssertEqual(reloaded.notes.first?.content, "Final body")
        XCTAssertEqual(reloaded.notes.first?.createdAt, note.createdAt)
    }

    func testSelectingMissingIDDoesNotChangeEditorOrFlushPendingDraft() throws {
        let note = NotesManager.Note(title: "Open", content: "Original")
        try store([note])
        let manager = NotesManager(storageURL: storageURL, saveDelay: 60)
        manager.selectNote(note)
        manager.updateCurrentNoteContent("Draft")

        XCTAssertFalse(manager.selectNote(id: UUID()))

        XCTAssertEqual(manager.currentNote?.id, note.id)
        XCTAssertTrue(manager.isEditing)
        XCTAssertEqual(manager.currentNote?.content, "Draft")
        XCTAssertEqual(try savedNotes().first?.content, "Original")
        manager.flushPendingChanges()
    }

    func testDeleteAndUndoRestoreLatestDraftAtOriginalPosition() throws {
        let notes = (0..<3).map { NotesManager.Note(title: "Note \($0)", content: "Body \($0)") }
        try store(notes)
        let manager = NotesManager(storageURL: storageURL, saveDelay: 60)
        manager.selectNote(notes[1])
        manager.updateCurrentNoteContent("Latest unsaved body")
        manager.updateCurrentNoteTitle("Latest title")

        XCTAssertTrue(manager.deleteNote(notes[1]))

        XCTAssertEqual(try savedNotes().map(\.id), [notes[0].id, notes[2].id])
        XCTAssertNil(manager.currentNote)
        XCTAssertFalse(manager.isEditing)
        XCTAssertTrue(manager.canUndoDelete)
        XCTAssertTrue(manager.undoDelete())
        XCTAssertFalse(manager.undoDelete())

        let restored = try savedNotes()
        XCTAssertEqual(restored.map(\.id), notes.map(\.id))
        XCTAssertEqual(restored[1].title, "Latest title")
        XCTAssertEqual(restored[1].content, "Latest unsaved body")
        XCTAssertEqual(restored[1].createdAt, notes[1].createdAt)
        XCTAssertFalse(manager.canUndoDelete)
    }

    func testOnlyLatestDeletionCanBeUndoneAndMissingDeleteDoesNotReplaceIt() throws {
        let first = NotesManager.Note(title: "First")
        let second = NotesManager.Note(title: "Second")
        try store([first, second])
        let manager = NotesManager(storageURL: storageURL)

        manager.deleteNote(first)
        manager.deleteNote(second)
        XCTAssertFalse(manager.deleteNote(NotesManager.Note(title: "Missing")))
        XCTAssertTrue(manager.undoDelete())

        XCTAssertEqual(manager.notes.map(\.id), [second.id])
        XCTAssertFalse(manager.canUndoDelete)
    }

    func testFailedDeleteAndUndoKeepRestoredDraftUntilPersistenceSucceeds() throws {
        let note = NotesManager.Note(title: "Existing", content: "Saved body")
        try store([note])
        var shouldFail = true
        let manager = NotesManager(storageURL: storageURL, saveDelay: 60, writeData: { data, url in
            if shouldFail { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        manager.selectNote(note)
        manager.updateCurrentNoteContent("Latest draft")

        XCTAssertTrue(manager.deleteNote(note))
        XCTAssertNotNil(manager.storageErrorMessage)
        XCTAssertTrue(manager.undoDelete())

        XCTAssertEqual(manager.notes.first?.content, "Latest draft")
        XCTAssertEqual(try savedNotes().first?.content, "Saved body")
        XCTAssertFalse(manager.prepareForTermination())
        shouldFail = false
        XCTAssertTrue(manager.retryPersistence())
        XCTAssertNil(manager.storageErrorMessage)
        XCTAssertEqual(try savedNotes().first?.content, "Latest draft")
    }

    func testReadOnlyStorageRejectsEditingDeletingCreatingAndUndo() throws {
        let notes = [NotesManager.Note(title: "First"), NotesManager.Note(title: "Second", content: "Original")]
        try store(notes)
        let manager = NotesManager(storageURL: storageURL)
        manager.deleteNote(notes[0])
        manager.selectNote(notes[1])
        let damaged = Data("unreadable".utf8)
        try damaged.write(to: storageURL)
        manager.loadNotes()

        XCTAssertTrue(manager.isStorageReadOnly)
        XCTAssertNil(manager.createNote(title: "Rejected"))
        XCTAssertFalse(manager.deleteNote(notes[1]))
        XCTAssertFalse(manager.undoDelete())
        manager.updateCurrentNoteTitle("Rejected")
        manager.updateCurrentNoteContent("Rejected")

        XCTAssertEqual(manager.currentNote?.title, "Second")
        XCTAssertEqual(manager.currentNote?.content, "Original")
        XCTAssertEqual(manager.notes.map(\.id), [notes[1].id])
        XCTAssertEqual(try Data(contentsOf: storageURL), damaged)
        XCTAssertTrue(manager.closeEditor())
    }

    func testReloadRemovingSelectedNoteAlsoClosesEditor() throws {
        let note = NotesManager.Note(title: "Existing")
        try store([note])
        let manager = NotesManager(storageURL: storageURL)
        manager.selectNote(note)
        try store([])

        manager.loadNotes()

        XCTAssertNil(manager.currentNote)
        XCTAssertFalse(manager.isEditing)
    }

    func testFailedSaveKeepsEditorOpenUntilRetrySucceeds() throws {
        let note = NotesManager.Note(title: "Existing")
        try store([note])
        var shouldFail = true
        let manager = NotesManager(storageURL: storageURL, saveDelay: 60, writeData: { data, url in
            if shouldFail { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        manager.selectNote(note)
        manager.updateCurrentNoteContent("Do not lose this")

        XCTAssertFalse(manager.closeEditor())
        XCTAssertTrue(manager.isEditing)
        XCTAssertEqual(manager.currentNote?.content, "Do not lose this")
        shouldFail = false
        XCTAssertTrue(manager.closeEditor())
        XCTAssertFalse(manager.isEditing)
        XCTAssertEqual(try savedNotes().first?.content, "Do not lose this")
    }

    func testExportUsesLatestContentAndPreservesUnicodeAndMarkdown() throws {
        let note = NotesManager.Note(title: "My / Note:One", content: "Before")
        try store([note])
        let manager = NotesManager(storageURL: storageURL, saveDelay: 60)
        manager.selectNote(note)
        let contents = "# 最新笔记\n\n- 中文\n- **text**\n"
        manager.updateCurrentNoteContent(contents)

        for format in NotesManager.ExportFormat.allCases {
            let filename = manager.exportFileName(for: note, format: format)
            XCTAssertFalse(filename.contains("/"))
            XCTAssertFalse(filename.contains(":"))
            XCTAssertTrue(filename.hasSuffix(".\(format.rawValue)"))
            let destination = directory.appendingPathComponent(filename)
            try manager.exportNote(id: note.id, to: destination, format: format)
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), contents)
        }
        XCTAssertEqual(try savedNotes().first?.content, "Before")
        manager.flushPendingChanges()
    }

    func testExportRejectsMissingNoteAndStorageOverwrite() throws {
        let note = NotesManager.Note(title: "Protected", content: "Body")
        try store([note])
        let manager = NotesManager(storageURL: storageURL)
        let original = try Data(contentsOf: storageURL)
        let missingDestination = directory.appendingPathComponent("missing.md")

        XCTAssertThrowsError(try manager.exportNote(id: UUID(), to: missingDestination, format: .markdown))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingDestination.path))
        XCTAssertThrowsError(try manager.exportNote(id: note.id, to: storageURL, format: .plainText))
        XCTAssertEqual(try Data(contentsOf: storageURL), original)
    }

    func testExportFailureLeavesNotesAndStorageUnchanged() throws {
        let note = NotesManager.Note(title: "Existing", content: "Original")
        try store([note])
        let manager = NotesManager(storageURL: storageURL)
        let destination = directory.appendingPathComponent("missing-parent/note.md")

        XCTAssertThrowsError(try manager.exportNote(id: note.id, to: destination, format: .markdown))

        XCTAssertEqual(manager.notes.first?.content, note.content)
        XCTAssertEqual(try savedNotes().first?.content, note.content)
        XCTAssertNil(manager.storageErrorMessage)
    }

    func testExportCannotOverwriteRecoveryBackupOrStorageThroughSymbolicLink() throws {
        let original = Data("original unreadable notes".utf8)
        try original.write(to: storageURL)
        let manager = NotesManager(storageURL: storageURL)
        XCTAssertTrue(manager.recoverStorage())
        let note = try XCTUnwrap(manager.createNote(title: "Recovered", content: "New body"))
        let backup = try XCTUnwrap(manager.recoveryBackupURL)
        let storedNotes = try Data(contentsOf: storageURL)
        let linkedStorage = directory.appendingPathComponent("linked-storage.txt")
        try FileManager.default.createSymbolicLink(at: linkedStorage, withDestinationURL: storageURL)

        XCTAssertThrowsError(try manager.exportNote(id: note.id, to: backup, format: .plainText))
        XCTAssertThrowsError(try manager.exportNote(id: note.id, to: linkedStorage, format: .plainText))

        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try Data(contentsOf: storageURL), storedNotes)
    }

    func testCreateAndSelectRefuseToLeaveDraftWhenFlushFails() throws {
        let first = NotesManager.Note(title: "First", content: "Before")
        let second = NotesManager.Note(title: "Second", content: "Other")
        try store([first, second])
        var shouldFail = true
        let manager = NotesManager(storageURL: storageURL, saveDelay: 60, writeData: { data, url in
            if shouldFail { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        XCTAssertTrue(manager.selectNote(id: first.id))
        manager.updateCurrentNoteContent("Unsaved draft")

        XCTAssertNil(manager.createNote(title: "Must not replace draft"))
        XCTAssertFalse(manager.selectNote(id: second.id))
        XCTAssertEqual(manager.notes.map(\.id), [first.id, second.id])
        XCTAssertEqual(manager.currentNote?.id, first.id)
        XCTAssertEqual(manager.currentNote?.content, "Unsaved draft")
        XCTAssertTrue(manager.isEditing)
        XCTAssertEqual(try savedNotes().first?.content, "Before")

        shouldFail = false
        XCTAssertTrue(manager.selectNote(id: second.id))
        XCTAssertEqual(try savedNotes().first?.content, "Unsaved draft")
        XCTAssertNotNil(manager.createNote(title: "Saved draft can be left"))
    }

    private func store(_ notes: [NotesManager.Note]) throws {
        try JSONEncoder().encode(notes).write(to: storageURL, options: .atomic)
    }

    private func savedNotes() throws -> [NotesManager.Note] {
        try JSONDecoder().decode([NotesManager.Note].self, from: Data(contentsOf: storageURL))
    }
}
