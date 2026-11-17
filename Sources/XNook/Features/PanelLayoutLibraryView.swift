import Observation
import SwiftUI

@Observable @MainActor
final class PanelLayoutLibrarySession {
    enum Selection: Equatable {
        case template(PanelLayoutTemplate)
        case saved(UUID)
    }

    enum PendingAction {
        case apply(PanelLayoutConfiguration)
        case update(UUID)
        case delete(UUID)
    }

    var selection: Selection = .template(.standard)
    var pendingAction: PendingAction?
    var renamingID: UUID?
    var renameText = ""
    var errorMessage: String?
    var statusMessage: String?

    init(currentLayout: PanelLayoutConfiguration, store: PanelLayoutProfileStore) {
        if let profile = store.profiles.first(where: { $0.configuration == currentLayout }) {
            selection = .saved(profile.id)
        } else if let template = PanelLayoutTemplate.allCases.first(where: { $0.configuration == currentLayout }) {
            selection = .template(template)
        }
    }

    func configuration(in store: PanelLayoutProfileStore) -> PanelLayoutConfiguration? {
        switch selection {
        case .template(let template): return template.configuration
        case .saved(let id): return store.profiles.first { $0.id == id }?.configuration
        }
    }

    func requestApply(store: PanelLayoutProfileStore, currentLayout: PanelLayoutConfiguration,
                      hasUnsavedChanges: Bool, onApply: (PanelLayoutConfiguration) throws -> Void,
                      onClose: () -> Void) {
        guard let configuration = configuration(in: store) else {
            errorMessage = PanelLayoutProfileError.notFound.localizedDescription
            return
        }
        if hasUnsavedChanges && configuration != currentLayout {
            pendingAction = .apply(configuration)
        } else {
            apply(configuration, onApply: onApply, onClose: onClose)
        }
    }

    func confirmPendingAction(_ confirmedAction: PendingAction? = nil,
                              store: PanelLayoutProfileStore, currentLayout: PanelLayoutConfiguration,
                              onApply: (PanelLayoutConfiguration) throws -> Void, onClose: () -> Void) {
        guard let action = confirmedAction ?? pendingAction else { return }
        pendingAction = nil
        do {
            switch action {
            case .apply(let configuration):
                apply(configuration, onApply: onApply, onClose: onClose)
                return
            case .update(let id):
                try store.update(id: id, configuration: currentLayout)
            case .delete(let id):
                try store.delete(id: id)
                if selection == .saved(id) { selection = .template(.standard) }
                if renamingID == id { renamingID = nil }
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveCurrent(_ configuration: PanelLayoutConfiguration, store: PanelLayoutProfileStore) {
        do {
            let profile = try store.saveNew(configuration: configuration)
            selection = .saved(profile.id)
            errorMessage = nil
            statusMessage = L10n.localized(zh: "已另存为「\(profile.name)」", en: "Saved as “\(profile.name)”")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func beginRename(_ profile: SavedPanelLayout) {
        renamingID = profile.id
        renameText = profile.name
        errorMessage = nil
        statusMessage = nil
    }

    func saveRename(store: PanelLayoutProfileStore) {
        guard let id = renamingID else { return }
        do {
            try store.rename(id: id, name: renameText)
            renamingID = nil
            errorMessage = nil
        } catch {
            // 保留编辑框和输入，让用户直接修正名称后重试。
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ configuration: PanelLayoutConfiguration,
                       onApply: (PanelLayoutConfiguration) throws -> Void, onClose: () -> Void) {
        do {
            try onApply(configuration)
            errorMessage = nil
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct PanelLayoutLibraryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var store: PanelLayoutProfileStore
    let currentLayout: PanelLayoutConfiguration
    let isEditing: Bool
    let hasUnsavedChanges: Bool
    let onApply: (PanelLayoutConfiguration) throws -> Void
    let onClose: () -> Void
    @State private var session: PanelLayoutLibrarySession

    init(store: PanelLayoutProfileStore, currentLayout: PanelLayoutConfiguration,
         isEditing: Bool = false, hasUnsavedChanges: Bool = false,
         onApply: @escaping (PanelLayoutConfiguration) throws -> Void, onClose: @escaping () -> Void) {
        self.store = store
        self.currentLayout = currentLayout
        self.isEditing = isEditing
        self.hasUnsavedChanges = hasUnsavedChanges
        self.onApply = onApply
        self.onClose = onClose
        _session = State(initialValue: PanelLayoutLibrarySession(currentLayout: currentLayout, store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle(L10n.localized(zh: "内置布局", en: "Built-in Layouts"))
                    ForEach(PanelLayoutTemplate.allCases) { template in
                        layoutRow(selection: .template(template), name: template.localizedName,
                                  summary: template.summary, configuration: template.configuration,
                                  identifier: template.rawValue)
                    }
                    sectionTitle(L10n.localized(zh: "我的布局", en: "My Layouts"))
                        .padding(.top, 8)
                    if store.profiles.isEmpty {
                        Text(L10n.localized(zh: "将当前布局另存为方案，随时切换回来。",
                                            en: "Save your current layout to return to it anytime."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 8)
                    }
                    ForEach(store.profiles) { profile in
                        layoutRow(selection: .saved(profile.id), name: profile.name,
                                  summary: profileSummary(profile),
                                  configuration: profile.configuration, identifier: profile.id.uuidString,
                                  profile: profile)
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: .infinity)
            .expandedPanelDebugFrame(id: "panelLayoutLibraryScroll")
            Divider()
            footer
        }
        .frame(width: 520, height: 440)
        .background(IslandStyle.surface(for: colorScheme))
        .foregroundStyle(.primary)
        .controlSize(.small)
        .accessibilityIdentifier("panelLayoutLibrary")
        .expandedPanelDebugFrame(id: "panelLayoutLibrary")
        .alert(confirmationTitle, isPresented: Binding(
            get: { session.pendingAction != nil },
            set: { if !$0 { session.pendingAction = nil } }
        ), presenting: session.pendingAction) { action in
            Button(L10n.localized(zh: "取消", en: "Cancel"), role: .cancel) { session.pendingAction = nil }
            Button(confirmationButton, role: .destructive) {
                session.confirmPendingAction(action, store: store, currentLayout: currentLayout,
                                             onApply: onApply, onClose: onClose)
            }
        } message: { _ in
            Text(confirmationMessage)
        }
    }

    private var header: some View {
        HStack {
            Label(L10n.localized(zh: "布局方案", en: "Layout Library"), systemImage: "rectangle.3.group")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.localized(zh: "关闭布局方案", en: "Close Layout Library"))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .expandedPanelDebugFrame(id: "panelLayoutLibraryHeader")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func profileSummary(_ profile: SavedPanelLayout) -> String {
        let count = profile.configuration.visibleItems.count
        return profile.configuration.fitsContent == true
            ? L10n.localized(zh: "\(count) 个组件 · 自动高度", en: "\(count) modules · Automatic height")
            : L10n.localized(zh: "\(count) 个组件", en: "\(count) modules")
    }

    private func layoutRow(selection: PanelLayoutLibrarySession.Selection, name: String, summary: String,
                           configuration: PanelLayoutConfiguration, identifier: String,
                           profile: SavedPanelLayout? = nil) -> some View {
        let selected = session.selection == selection
        return HStack(spacing: 0) {
            Button {
                session.selection = selection
                session.errorMessage = nil
                session.statusMessage = nil
            } label: {
                HStack(spacing: 12) {
                    PanelLayoutThumbnail(configuration: configuration)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(name).font(.system(size: 12, weight: .semibold))
                                .lineLimit(1).truncationMode(.tail)
                            if configuration == currentLayout {
                                Text(L10n.localized(zh: "当前", en: "Current"))
                                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                        }
                        Text(summary).font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(2).multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14)).foregroundStyle(selected ? Color.primary : Color.secondary.opacity(0.5))
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name)
            .accessibilityValue(selected ? L10n.localized(zh: "已选中", en: "Selected") : "")
            .accessibilityIdentifier("panelLayoutLibrarySelect-" + identifier)
            if let profile {
                Menu {
                    Button(L10n.localized(zh: "重命名", en: "Rename")) { session.beginRename(profile) }
                    Button(L10n.localized(zh: "用当前布局更新", en: "Update with Current Layout")) {
                        session.pendingAction = .update(profile.id)
                    }
                    Divider()
                    Button(L10n.localized(zh: "删除", en: "Delete"), role: .destructive) {
                        session.pendingAction = .delete(profile.id)
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 28)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 24).padding(.trailing, 8)
                .disabled(!store.canEdit)
                .accessibilityLabel(L10n.localized(zh: "管理 \(profile.name)", en: "Manage \(profile.name)"))
            }
        }
        .background(IslandStyle.cardRest(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(selected ? 0.6 : 0.08), lineWidth: 1))
        .expandedPanelDebugFrame(id: "panelLayoutLibraryRow-" + identifier)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = session.errorMessage ?? store.loadError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("panelLayoutLibraryError")
            }
            if session.renamingID != nil {
                HStack(spacing: 8) {
                    TextField(L10n.localized(zh: "布局名称", en: "Layout name"), text: $session.renameText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { session.saveRename(store: store) }
                        .accessibilityIdentifier("panelLayoutLibraryRename")
                    Button(L10n.localized(zh: "取消", en: "Cancel")) { session.renamingID = nil }
                    Button(L10n.localized(zh: "保存名称", en: "Save Name")) { session.saveRename(store: store) }
                        .disabled(!store.canEdit)
                }
            } else {
                Text(session.statusMessage ?? (isEditing
                     ? L10n.localized(zh: "载入后可继续调整，保存编辑后生效。", en: "Keep adjusting after loading. Save your edits to apply them.")
                     : L10n.localized(zh: "选择方案，再应用到当前面板。", en: "Select a layout, then apply it to this panel.")))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if session.configuration(in: store)?.fitsContent == true {
                    Text(L10n.localized(zh: "方案高度随内容适配；调整组件尺寸后保留手动高度。",
                                        en: "Layout height follows its content. Resizing a module keeps your manual height."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button(L10n.localized(zh: "另存当前布局", en: "Save Current Layout")) {
                        session.saveCurrent(currentLayout, store: store)
                    }
                    .disabled(!store.canEdit)
                    .accessibilityIdentifier("panelLayoutLibrarySaveCurrent")
                    Spacer(minLength: 8)
                    Button(isEditing
                           ? L10n.localized(zh: "载入编辑草稿", en: "Load into Draft")
                           : L10n.localized(zh: "应用布局", en: "Apply Layout")) {
                        session.requestApply(store: store, currentLayout: currentLayout,
                                             hasUnsavedChanges: isEditing && hasUnsavedChanges,
                                             onApply: onApply, onClose: onClose)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.configuration(in: store) == nil)
                    .accessibilityIdentifier("panelLayoutLibraryApply")
                }
            }
        }
        .padding(16)
        .expandedPanelDebugFrame(id: "panelLayoutLibraryFooter")
    }

    private var confirmationTitle: String {
        switch session.pendingAction {
        case .apply: return L10n.localized(zh: "替换未保存的草稿？", en: "Replace Unsaved Draft?")
        case .update: return L10n.localized(zh: "更新这套布局方案？", en: "Update This Layout?")
        case .delete: return L10n.localized(zh: "删除这套布局方案？", en: "Delete This Layout?")
        case nil: return ""
        }
    }

    private var confirmationButton: String {
        switch session.pendingAction {
        case .apply: return L10n.localized(zh: "丢弃草稿并载入", en: "Discard and Load")
        case .update: return L10n.localized(zh: "更新方案", en: "Update Layout")
        case .delete: return L10n.localized(zh: "删除方案", en: "Delete Layout")
        case nil: return ""
        }
    }

    private var confirmationMessage: String {
        switch session.pendingAction {
        case .apply:
            return L10n.localized(zh: "尚未保存的布局调整将被所选方案替换。载入后仍需保存编辑。",
                                  en: "The selected layout will replace your unsaved adjustments. Save your edits after loading.")
        case .update:
            return L10n.localized(zh: "方案中原有的组件位置和尺寸将被当前布局覆盖。",
                                  en: "The current layout will replace the positions and sizes saved in this layout.")
        case .delete:
            return L10n.localized(zh: "这套方案将从我的布局中移除，当前面板布局不会改变。",
                                  en: "This layout will be removed from My Layouts. Your current panel will stay as it is.")
        case nil: return ""
        }
    }
}

struct PanelLayoutThumbnail: View {
    let configuration: PanelLayoutConfiguration
    private let width: CGFloat = 112
    private let height: CGFloat = 56

    var body: some View {
        let rows = max(4, configuration.visibleItems.map { $0.row + $0.rows }.max() ?? 4)
        ZStack(alignment: .topLeading) {
            ForEach(0..<PanelLayoutConfiguration.columnCount, id: \.self) { column in
                Rectangle().fill(Color.primary.opacity(0.035))
                    .frame(width: width / 12 - 1, height: height)
                    .offset(x: CGFloat(column) * width / 12)
            }
            ForEach(configuration.visibleItems) { item in
                let itemWidth = CGFloat(item.columns) * width / 12 - 2
                let itemHeight = CGFloat(item.rows) * height / CGFloat(rows) - 2
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.15))
                    .overlay {
                        if itemHeight >= 10 {
                            Image(systemName: item.id.icon)
                                .font(.system(size: min(11, itemHeight - 4))).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: itemWidth, height: max(1, itemHeight))
                    .offset(x: CGFloat(item.column) * width / 12 + 1,
                            y: CGFloat(item.row) * height / CGFloat(rows) + 1)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
    }
}
