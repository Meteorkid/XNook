import AppKit

/// 授权失效仍可取回本地资料；不导出钥匙串和授权凭据。
@MainActor
enum LicenseDataExport {
    static func run() {
        let panel = NSOpenPanel()
        panel.title = "选择本地数据的导出目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            let result = try export(to: directory)
            NSWorkspace.shared.activateFileViewerSelecting([result])
        } catch {
            let alert = NSAlert()
            alert.messageText = "导出未完成"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    static func export(to directory: URL) throws -> URL {
        let files = FileManager.default
        let source = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XNook", isDirectory: true)
        let destination = directory.appendingPathComponent("XNook-Data-\(UUID().uuidString.prefix(8))", isDirectory: true)
        guard !destination.resolvingSymlinksInPath().path.hasPrefix(source.resolvingSymlinksInPath().path + "/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        if files.fileExists(atPath: source.path) {
            for item in try files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                try files.copyItem(at: item, to: destination.appendingPathComponent(item.lastPathComponent))
            }
        }
        if let flow = UserDefaults.standard.persistentDomain(forName: "com.meteorkid.xnook.nookflow") {
            let data = try PropertyListSerialization.data(fromPropertyList: flow, format: .xml, options: 0)
            try data.write(to: destination.appendingPathComponent("NookFlow.plist"), options: .atomic)
        }
        // 磁盘保存失败时也保留到期前的内存编辑，不能只导出旧文件。
        if let notes = AppDelegate.shared?.licenseRetainedNotesManager ?? AppDelegate.shared?.notesManagerForTermination {
            try JSONEncoder().encode(notes.notes).write(to: destination.appendingPathComponent("notes.json"), options: .atomic)
        }
        return destination
    }
}
