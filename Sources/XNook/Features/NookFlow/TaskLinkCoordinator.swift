import Foundation
import Observation

/// 协调任务网页的校验、保存与打开，将操作结果转换为界面提示。
@Observable @MainActor
final class TaskLinkCoordinator {
    let manager: FocusSessionManager
    private(set) var errorMessage: String?
    private let openURL: (URL) -> Bool

    init(manager: FocusSessionManager, openURL: @escaping (URL) -> Bool) {
        self.manager = manager
        self.openURL = openURL
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
