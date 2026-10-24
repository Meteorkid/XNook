import SwiftUI
import UniformTypeIdentifiers

/// 文件托盘 Widget 视图
struct TrayWidgetView: View {
    @Bindable var trayManager: TrayManager
    var isDetail = false
    var onShowAll: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var reduceMotion = false
    @State private var showAllFiles = false
    private var motion: Animation? { reduceMotion || systemReduceMotion ? nil : .easeInOut(duration: 0.2) }
    private let overviewFileLimit = 2

    /// 当前显示的文件列表
    private var displayFiles: ArraySlice<TrayManager.TrayFile> {
        let maxVisible = (isDetail || showAllFiles) ? trayManager.files.count : overviewFileLimit
        return trayManager.files.prefix(maxVisible)
    }

    /// 是否有更多文件未显示
    private var hasMoreFiles: Bool {
        trayManager.files.count > overviewFileLimit && !showAllFiles && !isDetail
    }

    private var statusMessage: String? {
        switch trayManager.issue {
        case .readFailed: return L10n.trayReadFailed
        case .saveFailed: return L10n.traySaveFailed
        case .bookmarkCreationFailed: return L10n.trayBookmarkFailed
        case .fileUnavailable: return L10n.trayFileUnavailable
        case nil:
            return trayManager.unavailableFileCount > 0
                ? L10n.unavailableTrayFiles(trayManager.unavailableFileCount)
                : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 标题
            HStack(spacing: 6) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.green)
                Text(L10n.widgetTray)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Text(L10n.fileCount(trayManager.files.count + trayManager.unavailableFileCount))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .frame(minHeight: 24)

            if let statusMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle")
                    Text(statusMessage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { trayManager.loadFiles() } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.reloadTray)
                    .accessibilityLabel(L10n.reloadTray)
                }
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            if trayManager.files.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text(L10n.dropFilesHere)
                        .font(.system(size: 12, weight: .medium))
                    Text(L10n.trayDropHint)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .expandedPanelDebugFrame(id: "expandedPanelTrayDropZone")
            } else {
                fileList
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $trayManager.isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(trayManager.isDropTargeted ? Color.green.opacity(0.6) : Color.clear, lineWidth: 2)
                .allowsHitTesting(false)
        )
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(displayFiles) { file in
                fileRow(file: file)
                    .expandedPanelDebugFrame(id: "expandedPanelTrayFile-\(file.id.uuidString)")
            }

            if !isDetail && !showAllFiles && (onShowAll != nil || hasMoreFiles) {
                Button {
                    if let onShowAll { onShowAll() }
                    else { withAnimation(motion) { showAllFiles = true } }
                } label: {
                    Text(onShowAll != nil ? L10n.panelOpenAllFiles : L10n.showAllFiles(trayManager.files.count - overviewFileLimit))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .expandedPanelDebugFrame(id: "expandedPanelTrayShowAll")
            }

            if showAllFiles && !isDetail && trayManager.files.count > overviewFileLimit {
                Button {
                    withAnimation(motion) { showAllFiles = false }
                } label: {
                    Text(L10n.collapseFiles)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 文件行

    private func fileRow(file: TrayManager.TrayFile) -> some View {
        HStack(spacing: 6) {
            // 文件图标
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 24, height: 24)
                Image(systemName: file.icon)
                    .font(.system(size: 11))
                    .foregroundColor(.green)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .foregroundColor(.primary)

                Text(TrayManager.formatFileSize(file.size))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 删除按钮
            Button(action: { withAnimation(motion) { trayManager.removeFile(file) } }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.removeFile)
            .accessibilityLabel(L10n.removeFile)
            .expandedPanelDebugFrame(id: "expandedPanelTrayRemove-\(file.id.uuidString)")

            // 打开按钮
            Button(action: { trayManager.openFile(file) }) {
                Image(systemName: "arrow.up.right.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.openFile)
            .accessibilityLabel(L10n.openFile)
            .expandedPanelDebugFrame(id: "expandedPanelTrayOpen-\(file.id.uuidString)")
        }
        .padding(.horizontal, isDetail ? 6 : 0)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(isDetail ? 0.05 : 0))
        .cornerRadius(6)
        .contentShape(Rectangle())
        .contextMenu { fileContextMenu(file: file) }
        .onTapGesture { trayManager.openFile(file) }
        .onDrag { provider(for: file) }
    }

    // MARK: - 拖出文件（复制）

    private func provider(for file: TrayManager.TrayFile) -> NSItemProvider {
        let provider = NSItemProvider()
        guard let result = file.resolveURL() else { return provider }
        // 直接注册 URL：Finder 和其他应用通过系统 pasteboard 复制文件
        provider.registerObject(result.url as NSURL, visibility: .all)
        return provider
    }

    // MARK: - 右键菜单

    @ViewBuilder
    private func fileContextMenu(file: TrayManager.TrayFile) -> some View {
        Button(L10n.openFile) { trayManager.openFile(file) }
        Button(L10n.revealInFinder) { trayManager.revealInFinder(file) }
        Button(L10n.copyToClipboard) { trayManager.copyToClipboard(file) }
        Divider()
        Button(L10n.removeFile) { withAnimation(motion) { trayManager.removeFile(file) } }
    }

    // MARK: - 处理拖放

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            provider.loadObject(ofClass: NSURL.self) { reading, _ in
                guard let nsurl = reading as? NSURL else { return }
                DispatchQueue.main.async { trayManager.addFile(from: nsurl as URL) }
            }
            accepted = true
        }
        return accepted
    }
}

#if !XNOOK_DISABLE_PREVIEWS
#Preview {
    TrayWidgetView(trayManager: TrayManager())
        .background(Color.black)
}
#endif
