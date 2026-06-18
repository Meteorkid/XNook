import SwiftUI
import UniformTypeIdentifiers

/// 文件托盘 Widget 视图
struct TrayWidgetView: View {
    @ObservedObject var trayManager: TrayManager

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
                Text(L10n.fileCount(trayManager.files.count))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
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
                // 文件列表
                VStack(spacing: 4) {
                    ForEach(trayManager.files.prefix(4)) { file in
                        fileRow(file: file)
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $trayManager.isDropTargeted) { providers in
            handleDrop(providers: providers)
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
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .foregroundColor(.primary)

                Text(TrayManager.formatFileSize(file.size))
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: { trayManager.openFile(file) }) {
                Image(systemName: "arrow.up.right.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(6)
        .onTapGesture { trayManager.openFile(file) }
    }

    // MARK: - 处理拖放

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async { trayManager.addFile(from: url) }
                }
            }
        }
        return true
    }
}

#Preview {
    TrayWidgetView(trayManager: TrayManager())
        .background(Color.black)
}
