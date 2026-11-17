import SwiftUI
import XCTest
@testable import XNook

@MainActor
final class FocusSessionResourcesViewTests: XCTestCase {
    private var directory: URL!
    private var storageURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("XNookFlowResourcesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storageURL = directory.appendingPathComponent("notes.json")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        storageURL = nil
        directory = nil
    }

    func testEditorDismissalSavesPendingChangesBeforeClosing() throws {
        let note = NotesManager.Note(title: "任务笔记", content: "原内容")
        try JSONEncoder().encode([note]).write(to: storageURL)
        let manager = NotesManager(storageURL: storageURL, saveDelay: 60)
        XCTAssertTrue(manager.selectNote(id: note.id))
        manager.updateCurrentNoteContent("任务中编辑的内容")
        var presented = true
        let binding = FocusSessionResourcesView.editorPresentationBinding(
            Binding(get: { presented }, set: { presented = $0 }), notes: manager
        )

        binding.wrappedValue = false

        XCTAssertFalse(presented)
        XCTAssertFalse(manager.isEditing)
        XCTAssertNil(manager.currentNote)
        let stored = try JSONDecoder().decode([NotesManager.Note].self, from: Data(contentsOf: storageURL))
        XCTAssertEqual(stored.first?.content, "任务中编辑的内容")
    }

    func testFailedEditorDismissalKeepsSheetAndDraftUntilSaveSucceeds() throws {
        let note = NotesManager.Note(title: "任务笔记", content: "原内容")
        let original = try JSONEncoder().encode([note])
        try original.write(to: storageURL)
        var shouldFail = true
        let manager = NotesManager(storageURL: storageURL, saveDelay: 60, writeData: { data, url in
            if shouldFail { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        XCTAssertTrue(manager.selectNote(id: note.id))
        manager.updateCurrentNoteContent("不能丢失的草稿")
        var presented = true
        let binding = FocusSessionResourcesView.editorPresentationBinding(
            Binding(get: { presented }, set: { presented = $0 }), notes: manager
        )

        binding.wrappedValue = false

        XCTAssertTrue(presented)
        XCTAssertTrue(manager.isEditing)
        XCTAssertEqual(manager.currentNote?.content, "不能丢失的草稿")
        XCTAssertNotNil(manager.storageErrorMessage)
        XCTAssertEqual(try Data(contentsOf: storageURL), original)
        shouldFail = false
        binding.wrappedValue = false
        XCTAssertFalse(presented)
        XCTAssertFalse(manager.isEditing)
        let stored = try JSONDecoder().decode([NotesManager.Note].self, from: Data(contentsOf: storageURL))
        XCTAssertEqual(stored.first?.content, "不能丢失的草稿")
    }

    func testResourcePopoverDismissalIsBlockedOnlyWhileEmbeddedEditorIsPresented() {
        var presented = true
        var editing = true
        let binding = FocusSessionView.guardedPresentationBinding(
            Binding(get: { presented }, set: { presented = $0 }), isEditing: { editing }
        )

        binding.wrappedValue = false
        XCTAssertTrue(presented)
        editing = false
        binding.wrappedValue = false
        XCTAssertFalse(presented)
        binding.wrappedValue = true
        XCTAssertTrue(presented)
    }

    func testExplicitQuitWithoutSavingDoesNotRetryWriteWhenTaskNoteSheetCloses() throws {
        let note = NotesManager.Note(title: "任务笔记", content: "已保存原文")
        let original = try JSONEncoder().encode([note])
        try original.write(to: storageURL)
        var shouldFail = true
        var attempts = 0
        let manager = NotesManager(storageURL: storageURL, saveDelay: 60, writeData: { data, url in
            attempts += 1
            if shouldFail { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        XCTAssertTrue(manager.selectNote(id: note.id))
        manager.updateCurrentNoteContent("用户选择放弃的修改")
        XCTAssertFalse(manager.prepareForTermination())
        // 即使写故障随后恢复，用户选择丢弃后关闭弹层也不能再次保存。
        shouldFail = false
        attempts = 0
        var presented = true
        let binding = FocusSessionResourcesView.editorPresentationBinding(
            Binding(get: { presented }, set: { presented = $0 }), notes: manager,
            shouldDiscardPendingChanges: { true })
        binding.wrappedValue = false
        XCTAssertFalse(presented)
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(try Data(contentsOf: storageURL), original)
    }
}
