import Foundation
import Observation

@Observable @MainActor
final class PanelLayoutEditingSession {
    private(set) var isEditing = false
    var draft: PanelLayoutConfiguration = .factoryDefault
    private(set) var errorMessage: String?
    private var baseSignature: String?

    func begin(from store: PanelLayoutStore) {
        guard !isEditing else { return }
        store.reload()
        guard store.canEdit else { errorMessage = store.loadError; return }
        draft = store.configuration
        baseSignature = store.configuration.signature
        errorMessage = nil
        isEditing = true
    }

    func cancel() {
        isEditing = false
        baseSignature = nil
        errorMessage = nil
    }

    func restoreDefault() { draft = .factoryDefault }

    @discardableResult
    func save(to store: PanelLayoutStore) -> Bool {
        guard isEditing else { return false }
        store.reload()
        guard store.canEdit, store.configuration.signature == baseSignature else {
            errorMessage = store.loadError ?? L10n.localized(zh: "布局已在其他窗口改变，请取消后重新编辑。", en: "The layout changed in another window. Cancel and edit again.")
            return false
        }
        do {
            try store.save(draft)
            cancel()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
