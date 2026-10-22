import SwiftUI

/// 网页资料沿用任务 ID 定位，编辑草稿不随底层快照刷新而覆盖。
struct TaskLinksView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var links: TaskLinkCoordinator
    @State private var draft: TaskLinkEditDraft?
    @State private var address = ""
    @State private var title = ""
    @Binding var isEditing: Bool
    let sessionID: UUID

    init(manager: FocusSessionManager, sessionID: UUID, isEditing: Binding<Bool>,
         initialDraft: TaskLinkEditDraft? = nil) {
        _links = State(initialValue: TaskLinkCoordinator(manager: manager, openURL: { NSWorkspace.shared.open($0) }))
        _draft = State(initialValue: initialDraft)
        _isEditing = isEditing
        self.sessionID = sessionID
    }

    private var writesBlocked: Bool { links.manager.storageError != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.flowWebLinks, systemImage: "link").font(.headline)
                Spacer()
                Button(L10n.flowClose) { dismiss() }.disabled(isEditing)
            }
            if let session = links.manager.session(id: sessionID) {
                Text(session.title).font(.subheadline.weight(.semibold))
                    .lineLimit(2).textSelection(.enabled)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if session.taskURLs.isEmpty {
                            Text(L10n.flowNoWebLinks).foregroundStyle(.secondary)
                        }
                        ForEach(session.taskURLs) { link in
                            if draft?.original.id == link.id {
                                editor
                            } else {
                                linkRow(link)
                            }
                        }
                        if let draft, !session.taskURLs.contains(where: { $0.id == draft.original.id }) {
                            editor
                        }
                        Divider()
                        TextField(L10n.flowWebAddress, text: $address)
                            .textFieldStyle(.roundedBorder).accessibilityLabel(L10n.flowWebAddressLabel)
                        TextField(L10n.flowWebTitle, text: $title).textFieldStyle(.roundedBorder)
                            .onSubmit(addLink)
                        Button(L10n.flowAddWebLink, action: addLink)
                            .disabled(writesBlocked || isEditing || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text(L10n.flowWebLinkRule).font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(L10n.flowResourceTaskMissing).foregroundStyle(.secondary)
                editor
                Spacer(minLength: 0)
            }
            if let error = links.errorMessage ?? links.manager.storageError {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if writesBlocked {
                Button(L10n.flowRetry) {
                    if links.manager.retryLoadingStorage() { links.clearError() }
                }
            }
        }
        .font(.callout)
        .padding(18)
        .frame(width: 420, height: 430)
        .interactiveDismissDisabled(isEditing)
    }

    private func linkRow(_ link: LinkedTaskURL) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(link.title).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
            Text(link.urlString).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).textSelection(.enabled)
            HStack {
                Button(L10n.flowOpen) { links.openTaskURL(id: link.id, in: sessionID) }
                    .disabled(link.validatedURL == nil)
                    .accessibilityLabel(L10n.flowOpen + " " + link.title)
                Button(L10n.flowEditWebLink) {
                    links.clearError()
                    draft = TaskLinkEditDraft(link: link)
                    isEditing = true
                }
                .disabled(writesBlocked || isEditing)
                .accessibilityLabel(L10n.flowEditWebLink + " " + link.title)
                Button(L10n.flowUnlink) { links.unlinkTaskURL(id: link.id, from: sessionID) }
                    .disabled(writesBlocked || isEditing)
                    .accessibilityLabel(L10n.flowUnlink + " " + link.title)
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let binding = Binding($draft) {
            TaskLinkEditorView(draft: binding, writesBlocked: writesBlocked, onSave: {
                guard let draft else { return }
                if links.editTaskURL(draft.original, urlString: draft.address, title: draft.title, in: sessionID) {
                    finishEditing()
                }
            }, onCancel: finishEditing)
        }
    }

    private func finishEditing() {
        draft = nil
        isEditing = false
        links.clearError()
    }

    private func addLink() {
        guard !writesBlocked, !isEditing else { return }
        if links.addTaskURL(urlString: address, title: title, to: sessionID) {
            address = ""
            title = ""
        }
    }
}
