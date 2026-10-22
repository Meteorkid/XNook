import SwiftUI

/// 草稿保留打开时的快照，保存失败或并发修改时不覆盖输入。
struct TaskLinkEditDraft {
    let original: LinkedTaskURL
    var address: String
    var title: String

    init(link: LinkedTaskURL) {
        original = link
        address = link.urlString
        title = link.title
    }
}

struct TaskLinkEditorView: View {
    @Binding var draft: TaskLinkEditDraft
    let writesBlocked: Bool
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.flowEditWebLink, systemImage: "pencil")
                .font(.subheadline.weight(.semibold))
            TextField(L10n.flowWebAddress, text: $draft.address)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.flowWebAddressLabel)
                .accessibilityIdentifier("task-link.edit.address")
                .focused($addressFocused)
                .onSubmit(saveIfAllowed)
            TextField(L10n.flowWebTitle, text: $draft.title)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.flowWebTitle)
                .accessibilityIdentifier("task-link.edit.title")
                .onSubmit(saveIfAllowed)
            HStack {
                Button(L10n.save, action: onSave)
                    .disabled(!canSave)
                    .accessibilityIdentifier("task-link.edit.save")
                Button(L10n.flowCancelWebLinkEdit, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("task-link.edit.cancel")
            }
        }
        .font(.callout)
        .onAppear { addressFocused = true }
    }

    private var canSave: Bool {
        !writesBlocked && !draft.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveIfAllowed() {
        if canSave { onSave() }
    }
}
