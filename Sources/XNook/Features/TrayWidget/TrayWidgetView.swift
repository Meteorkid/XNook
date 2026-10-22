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

    /// 当前显示的文件列表
    private var displayFiles: ArraySlice<TrayManager.TrayFile> {
        let maxVisible = (isDetail || showAllFiles) ? trayManager.files.count : min(trayManager.files.count, 4)
        return trayManager.files.prefix(maxVisible)
    }

    /// 是否有更多文件未显示
    private var hasMoreFiles: Bool {
        trayManager.files.count > 4 && !showAllFiles && !isDetail
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
        VStack(spacing: 6) {
            // 标题
            HStack {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.green)
                Text(L10n.widgetTray)
                    .font(.system(size: 10, weight: .semibold))
                Spacer()
                Text(L10n.fileCount(trayManager.files.count + trayManager.unavailableFileCount))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }

            if let statusMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle")
                    Text(statusMessage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { trayManager.loadFiles() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help(L10n.reloadTray)
                    .accessibilityLabel(L10n.reloadTray)
                }
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            if trayManager.files.isEmpty {
                // 空状态
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.1))
                            .frame(width: 40, height: 40)
                        Image(systemName: "tray")
                            .font(.system(size: 18))
                            .foregroundColor(.green)
                    }
                    Text(L10n.dropFilesHere)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                if isDetail {
                    fileList
                } else {
                    ScrollView { fileList }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $trayManager.isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(trayManager.isDropTargeted ? Color.green.opacity(0.6) : Color.clear, lineWidth: 2)
        )
    }

    private var fileList: some View {
                    VStack(spacing: 4) {
                        ForEach(displayFiles) { file in
                            fileRow(file: file)
                        }

                        // 显示更多 / 收起按钮
                        if hasMoreFiles {
                            Button {
                                if let onShowAll { onShowAll() }
                                else { withAnimation(motion) { showAllFiles = true } }
                            } label: {
                                HStack {
                                    Spacer()
                                    Text(L10n.showAllFiles(trayManager.files.count - 4))
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        if showAllFiles && !isDetail && trayManager.files.count > 4 {
                            Button {
                                withAnimation(motion) { showAllFiles = false }
                            } label: {
                                HStack {
                                    Spacer()
                                    Text(L10n.collapseFiles)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
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

            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .foregroundColor(.primary)

                Text(TrayManager.formatFileSize(file.size))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // 删除按钮
            Button(action: { withAnimation(motion) { trayManager.removeFile(file) } }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.removeFile)

            // 打开按钮
            Button(action: { trayManager.openFile(file) }) {
                Image(systemName: "arrow.up.right.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.openFile)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.05))
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
