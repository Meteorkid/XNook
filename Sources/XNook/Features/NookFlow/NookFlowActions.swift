import Foundation

/// 任务与资料的协调入口，和界面导航分开以验证完整保存、恢复流程。
@MainActor
struct NookFlowActions {
    let sessions: FocusSessionManager
    let notes: NotesManager
    let tray: TrayManager

    func createLinkedNote() -> Bool {
        guard let session = sessions.activeSession, sessions.storageError == nil else { return false }
        if let linkedNote = session.linkedNote { return notes.selectNote(id: linkedNote.id) }
        guard let note = notes.createNote(title: session.title, content: "", isMarkdown: true) else { return false }
        sessions.linkNote(id: note.id, title: note.title)
        return true
    }

    func linkTrayFiles() {
        guard sessions.activeSession != nil, sessions.storageError == nil else { return }
        // 一次性提交，避免在文件架条目多的时候变成 n 次全量写盘。
        sessions.linkFiles(tray.files.map {
            FocusSessionManager.FileSnapshot(id: $0.id, name: $0.name, icon: $0.icon, bookmarkData: $0.bookmarkData)
        })
    }

    func openNote(_ id: UUID) -> Bool {
        notes.selectNote(id: id)
    }

    func openFile(_ file: LinkedFile) -> Bool {
        LinkedFileAccess.open(file, fallbackBookmark: tray.files.first(where: { $0.id == file.id })?.bookmarkData)
    }
}
