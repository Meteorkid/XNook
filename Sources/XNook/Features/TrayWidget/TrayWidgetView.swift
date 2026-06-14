import SwiftUI
import UniformTypeIdentifiers

/// 文件架 Widget 视图
struct TrayWidgetView: View {
    @ObservedObject var trayManager: TrayManager

    var body: some View {
        VStack(spacing: 12) {
            // 标题栏
            HStack {
                Image(systemName: "tray.full")
                    .font(.system(size: 12))
                    .foregroundColor(.green)
                Text("File Tray")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(trayManager.files.count) files")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            if trayManager.files.isEmpty {
                // 空状态
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                    Text("Drop files here")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("Drag & drop files to add them to the tray")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5]))
                )
            } else {
                // 文件列表
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(trayManager.files) { file in
                            FileRow(file: file) {
                                trayManager.openFile(file)
                            } onDelete: {
                                trayManager.removeFile(file)
                            } onReveal: {
                                trayManager.revealInFinder(file)
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .padding(16)
        .frame(width: 280)
        .onDrop(of: [.fileURL], isTargeted: $trayManager.isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - 处理拖放

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                    DispatchQueue.main.async {
                        trayManager.addFile(from: url)
                    }
                }
            }
        }
        return true
    }
}

// MARK: - File Row

struct FileRow: View {
    let file: TrayManager.TrayFile
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // 图标
            Image(systemName: file.icon)
                .font(.system(size: 16))
                .foregroundColor(.green)
                .frame(width: 24)

            // 内容
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .foregroundColor(.primary)

                Text(TrayManager.formatFileSize(file.size))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // 操作按钮
            HStack(spacing: 8) {
                Button(action: onOpen) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Button(action: onReveal) {
                    Image(systemName: "eye")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(6)
        .onTapGesture {
            onOpen()
        }
    }
}

// MARK: - Preview

#Preview {
    TrayWidgetView(trayManager: TrayManager())
        .background(Color.black)
}
