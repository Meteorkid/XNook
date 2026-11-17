import AppKit
import Observation

/// 协调笔记文件与任务快照，不以删除笔记补偿另一存储的写入失败。
@Observable @MainActor
final class FocusResourceCoordinator {
    let manager: FocusSessionManager
    let notes: NotesManager
    let tray: TrayManager
    private(set) var errorMessage: String?

    private var pendingCreatedNotes: [UUID: UUID] = [:]
    private let resolveBookmark: (Data) -> (url: URL, isStale: Bool)?
    private let makeBookmark: (URL) throws -> Data
    private let openURL: (URL) -> Bool
    private let isReachable: (URL) -> Bool
    private let startAccess: (URL) -> Bool
    private let stopAccess: (URL) -> Void

    init(
        manager: FocusSessionManager,
        notes: NotesManager,
        tray: TrayManager,
        resolveBookmark: @escaping (Data) -> (url: URL, isStale: Bool)? = TrayManager.TrayFile.resolveBookmark,
        makeBookmark: @escaping (URL) throws -> Data = {
            try $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        },
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        isReachable: @escaping (URL) -> Bool = { (try? $0.checkResourceIsReachable()) == true },
        startAccess: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.manager = manager
        self.notes = notes
        self.tray = tray
        self.resolveBookmark = resolveBookmark
        self.makeBookmark = makeBookmark
        self.openURL = openURL
        self.isReachable = isReachable
        self.startAccess = startAccess
        self.stopAccess = stopAccess
    }

    func clearError() { errorMessage = nil }

    @discardableResult
    func addTaskURL(urlString: String, title: String, to sessionID: UUID) -> Bool {
        guard writableSession(id: sessionID) != nil else { return false }
        switch manager.addTaskURL(urlString: urlString, title: title, to: sessionID) {
        case .added:
            clearError()
            return true
        case .existing: return fail(L10n.flowWebLinkExists)
        case .invalidLink: return fail(L10n.flowInvalidWebLink)
        case .limitReached: return fail(L10n.flowWebLinkLimit)
        case .taskUnavailable: return fail(L10n.flowResourceTaskMissing)
        case .saveFailed: return fail(manager.storageError ?? L10n.flowStorageWriteError)
        }
    }

    @discardableResult
    func editTaskURL(
        _ original: LinkedTaskURL, urlString: String, title: String, in sessionID: UUID
    ) -> Bool {
        switch manager.editTaskURL(original, urlString: urlString, title: title, in: sessionID) {
        case .updated, .unchanged:
            clearError()
            return true
        case .invalidLink: return fail(L10n.flowInvalidWebLink)
        case .existing: return fail(L10n.flowWebLinkExists)
        case .linkUnavailable: return fail(L10n.flowWebLinkRemoved)
        case .taskUnavailable: return fail(L10n.flowResourceTaskMissing)
        case .conflict: return fail(L10n.flowWebLinkChanged)
        case .saveFailed: return fail(manager.storageError ?? L10n.flowStorageWriteError)
        }
    }

    @discardableResult
    func openTaskURL(id: UUID, in sessionID: UUID) -> Bool {
        guard let session = manager.session(id: sessionID),
              let link = session.taskURLs.first(where: { $0.id == id }),
              let url = link.validatedURL, openURL(url) else { return fail(L10n.flowWebLinkUnavailable) }
        clearError()
        return true
    }

    @discardableResult
    func unlinkTaskURL(id: UUID, from sessionID: UUID) -> Bool {
        guard writableSession(id: sessionID) != nil else { return false }
        return finish(manager.unlinkTaskURL(id: id, from: sessionID))
    }

    @discardableResult
    func setTimeBudget(minutes: Int?, in sessionID: UUID) -> Bool {
        guard let session = writableSession(id: sessionID) else { return false }
        guard !session.isEnded else { return fail(L10n.flowBudgetHistoryReadOnly) }
        if let minutes, !(1...1440).contains(minutes) { return fail(L10n.flowBudgetInvalid) }
        return finish(manager.setTimeBudget(minutes: minutes, for: sessionID))
    }

    @discardableResult
    func openNote(in sessionID: UUID) -> Bool {
        guard let session = manager.session(id: sessionID) else { return fail(L10n.flowResourceTaskMissing) }
        guard let link = session.linkedNote, notes.notes.contains(where: { $0.id == link.id }) else {
            return fail(L10n.flowNoteUnavailable)
        }
        guard notes.selectNote(id: link.id) else {
            return fail(notes.storageErrorMessage ?? L10n.flowResourceNoteUnsaved)
        }
        clearError()
        return true
    }

    @discardableResult
    func createNote(in sessionID: UUID) -> Bool {
        guard let session = writableSession(id: sessionID) else { return false }
        if let linked = session.linkedNote, notes.notes.contains(where: { $0.id == linked.id }) {
            return openNote(in: sessionID)
        }
        let note: NotesManager.Note
        if let pendingID = pendingCreatedNotes[sessionID], let pending = notes.notes.first(where: { $0.id == pendingID }) {
            note = pending
        } else {
            guard let created = notes.createNote(title: session.title, content: "", isMarkdown: true) else {
                return fail(notes.storageErrorMessage ?? L10n.flowNoteCreationFailed)
            }
            note = created
            pendingCreatedNotes[sessionID] = note.id
        }
        // createNote会保留写失败的草稿，返回值本身不能作为保存成功的证据。
        guard notes.flushPendingChanges(), notes.selectNote(id: note.id) else {
            return fail(notes.storageErrorMessage ?? L10n.flowResourceNoteUnsaved)
        }
        guard manager.setLinkedNote(LinkedNote(id: note.id, title: note.title), for: sessionID) else {
            return fail(L10n.flowResourceNoteKept)
        }
        pendingCreatedNotes.removeValue(forKey: sessionID)
        clearError()
        return true
    }

    @discardableResult
    func linkNote(id noteID: UUID, to sessionID: UUID) -> Bool {
        guard writableSession(id: sessionID) != nil else { return false }
        guard let note = notes.notes.first(where: { $0.id == noteID }) else { return fail(L10n.flowNoteUnavailable) }
        guard !notes.isStorageReadOnly, notes.flushPendingChanges() else {
            return fail(notes.storageErrorMessage ?? L10n.flowResourceNoteUnsaved)
        }
        let saved = manager.setLinkedNote(LinkedNote(id: note.id, title: note.title), for: sessionID)
        if saved { pendingCreatedNotes.removeValue(forKey: sessionID) }
        return finish(saved)
    }

    @discardableResult
    func unlinkNote(in sessionID: UUID) -> Bool {
        guard writableSession(id: sessionID) != nil else { return false }
        return finish(manager.setLinkedNote(nil, for: sessionID))
    }

    @discardableResult
    func linkTrayFiles(to sessionID: UUID) -> Bool {
        guard writableSession(id: sessionID) != nil else { return false }
        let snapshots = tray.files.map { LinkedFile(id: $0.id, name: $0.name, icon: $0.icon, bookmarkData: $0.bookmarkData) }
        return finish(manager.linkFiles(snapshots, to: sessionID))
    }

    @discardableResult
    func openFile(id fileID: UUID, in sessionID: UUID) -> Bool {
        guard let session = manager.session(id: sessionID) else { return fail(L10n.flowResourceTaskMissing) }
        guard let file = session.linkedFiles.first(where: { $0.id == fileID }),
              let bookmark = file.bookmarkData ?? tray.files.first(where: { $0.id == fileID })?.bookmarkData,
              let resolved = resolveBookmark(bookmark), resolved.url.isFileURL else {
            return fail(L10n.flowFileUnavailable)
        }
        let accessing = startAccess(resolved.url)
        defer { if accessing { stopAccess(resolved.url) } }
        guard isReachable(resolved.url), openURL(resolved.url) else { return fail(L10n.flowFileUnavailable) }
        clearError()
        return true
    }

    @discardableResult
    func replaceFile(id fileID: UUID, in sessionID: UUID, with url: URL) -> Bool {
        guard let session = writableSession(id: sessionID) else { return false }
        guard session.linkedFiles.contains(where: { $0.id == fileID }) else { return fail(L10n.flowFileUnavailable) }
        guard url.isFileURL else { return fail(L10n.flowFileUnavailable) }
        let accessing = startAccess(url)
        defer { if accessing { stopAccess(url) } }
        guard isReachable(url) else { return fail(L10n.flowFileUnavailable) }
        do {
            let replacement = LinkedFile(
                id: fileID, name: url.lastPathComponent, icon: TrayManager.TrayFile.iconForFile(at: url),
                bookmarkData: try makeBookmark(url)
            )
            return finish(manager.replaceLinkedFile(replacement, in: sessionID))
        } catch {
            return fail(L10n.flowResourceBookmarkFailure)
        }
    }

    @discardableResult
    func unlinkFile(id fileID: UUID, from sessionID: UUID) -> Bool {
        guard writableSession(id: sessionID) != nil else { return false }
        return finish(manager.unlinkFile(id: fileID, from: sessionID))
    }

    private func writableSession(id: UUID) -> FocusSession? {
        if let error = manager.storageError { errorMessage = error; return nil }
        guard let session = manager.session(id: id) else {
            errorMessage = L10n.flowResourceTaskMissing
            return nil
        }
        return session
    }

    private func finish(_ saved: Bool) -> Bool {
        errorMessage = saved ? nil : (manager.storageError ?? L10n.flowResourceTaskMissing)
        return saved
    }

    private func fail(_ message: String) -> Bool {
        errorMessage = message
        return false
    }
}
