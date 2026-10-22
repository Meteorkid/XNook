import SwiftUI
import ServiceManagement

// MARK: - 语言切换选择器

struct LanguagePicker: View {
    @AppStorage private var appLanguage: String

    init() {
        _appLanguage = AppStorage(wrappedValue: "auto", "appLanguage")
    }

    var body: some View {
        Picker("", selection: $appLanguage) {
            Text("Auto").tag("auto")
            Text("中文").tag("zh")
            Text("English").tag("en")
        }
        .pickerStyle(.segmented)
        .frame(width: 160)
        .onChange(of: appLanguage) { _, _ in
            // 通知 L10n 刷新（ UserDefaults 变更后 immediate 生效）
        }
    }
}

// MARK: - AppStorage 驱动的开关

struct AppStorageToggle: View {
    @AppStorage private var value: Bool

    init(key: String) {
        _value = AppStorage(
            wrappedValue: SettingsDefaults.bool(for: key),
            key
        )
    }

    var body: some View {
        Toggle("", isOn: $value)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
    }
}

// MARK: - AppStorage 驱动的无级滑块（支持手动输入）

struct AppStorageSlider: View {
    @AppStorage private var value: Double
    @State private var inputText: String = ""
    @State private var isEditing = false

    private let range: ClosedRange<Double>
    private let step: Double?
    private let format: String

    /// 无级调节（不传 step）
    init(key: String, range: ClosedRange<Double>, format: String = "%.0f") {
        _value = AppStorage(
            wrappedValue: SettingsDefaults.double(for: key, fallback: range.lowerBound),
            key
        )
        self.range = range
        self.step = nil
        self.format = format
    }

    /// 带步长调节
    init(key: String, range: ClosedRange<Double>, step: Double, format: String = "%.0f") {
        _value = AppStorage(
            wrappedValue: SettingsDefaults.double(for: key, fallback: range.lowerBound),
            key
        )
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        HStack(spacing: 8) {
            if let step {
                Slider(value: $value, in: range, step: step)
                    .frame(width: 140)
            } else {
                Slider(value: $value, in: range)
                    .frame(width: 140)
            }
            if isEditing {
                TextField("", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 65, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { commitInput() }
                    .onExitCommand { commitInput() }
            } else {
                Button(action: {
                    inputText = String(format: format, value)
                    isEditing = true
                }) {
                    Text(String(format: format, value))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 65, alignment: .trailing)
            }
        }
    }

    private func commitInput() {
        isEditing = false
        let cleaned = inputText.filter { "0123456789.".contains($0) }
        if let v = Double(cleaned) {
            value = min(max(v, range.lowerBound), range.upperBound)
        }
    }
}

// MARK: - 共享 UserDefaults 开关

struct SharedDefaultsToggle: View {
    @AppStorage private var value: Bool

    init(key: String, defaultValue: Bool) {
        _value = AppStorage(
            wrappedValue: defaultValue,
            key,
            store: IslandIntegrationSettings.sharedDefaults
        )
    }

    var body: some View {
        Toggle("", isOn: $value)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
    }
}

// MARK: - 共享灵敏度选择器

struct SharedSensitivityPicker: View {
    @AppStorage private var rawValue: String

    init() {
        _rawValue = AppStorage(
            wrappedValue: IslandSwitchSensitivity.medium.rawValue,
            IslandIntegrationSettings.Key.swipeSensitivity,
            store: IslandIntegrationSettings.sharedDefaults
        )
    }

    var body: some View {
        Picker("", selection: $rawValue) {
            Text(L10n.sensitivityLow).tag(IslandSwitchSensitivity.low.rawValue)
            Text(L10n.sensitivityMedium).tag(IslandSwitchSensitivity.medium.rawValue)
            Text(L10n.sensitivityHigh).tag(IslandSwitchSensitivity.high.rawValue)
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
    }
}

// MARK: - 共享启动显示模式选择器

struct SharedStartupDisplayPicker: View {
    @AppStorage private var rawValue: String

    init() {
        _rawValue = AppStorage(
            wrappedValue: IslandStartupDisplayMode.lastUsed.rawValue,
            IslandIntegrationSettings.Key.startupDisplayMode,
            store: IslandIntegrationSettings.sharedDefaults
        )
    }

    var body: some View {
        Picker("", selection: $rawValue) {
            Text(L10n.startupLastUsed).tag(IslandStartupDisplayMode.lastUsed.rawValue)
            Text("X Nook").tag(IslandStartupDisplayMode.xnook.rawValue)
            Text("X Island").tag(IslandStartupDisplayMode.xisland.rawValue)
        }
        .pickerStyle(.segmented)
        .frame(width: 260)
    }
}

// MARK: - 状态标签

struct StatusPill: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.12))
            )
    }
}

// MARK: - 开机自启动开关

struct LaunchAtLoginToggle: View {
    @AppStorage private var launchAtLogin: Bool

    init() {
        _launchAtLogin = AppStorage(
            wrappedValue: SettingsDefaults.bool(for: "launchAtLogin"),
            "launchAtLogin"
        )
    }

    var body: some View {
        Toggle("", isOn: Binding(
            get: { launchAtLogin },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    launchAtLogin = newValue
                } catch {
                    // 注册失败时回退开关状态
                    launchAtLogin = !newValue
                    print("[Settings] Launch at login error: \(error)")
                }
            }
        ))
        .toggleStyle(.switch)
        .labelsHidden()
        .controlSize(.small)
    }
}

// MARK: - GIF 选择器

struct GifPickerButton: View {
    @State private var gifList: [String] = UserDefaults.standard.stringArray(forKey: "customGifList") ?? []
    @State private var selectedGif: String = UserDefaults.standard.string(forKey: "selectedGifName") ?? ""
    @State private var failureMessage: String?
    @State private var isLoading = false

    private var gifsDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("XNook/gifs")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // GIF 列表
            if !gifList.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(gifList, id: \.self) { name in
                            GifThumbnailView(
                                name: name,
                                isSelected: name == selectedGif,
                                onSelect: {
                                    Task { await selectGif(name: name) }
                                },
                                onDelete: {
                                    deleteGif(name: name)
                                }
                            )
                        }
                    }
                }
                .frame(height: 60)
            }

            // 添加按钮
            Button(L10n.chooseGif) {
                let panel = NSOpenPanel()
                panel.title = L10n.chooseGif
                panel.allowedContentTypes = [.gif]
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = false

                if panel.runModal() == .OK {
                    let urls = panel.urls
                    Task { @MainActor in
                        isLoading = true
                        failureMessage = nil
                        defer { isLoading = false }
                        for url in urls {
                            await addGif(from: url)
                        }
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if let failureMessage {
                Text(failureMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(isLoading)
        .onReceive(NotificationCenter.default.publisher(for: GifResource.loadFailureNotification)) { notification in
            failureMessage = notification.userInfo?["message"] as? String
        }
        .task {
            // 启动时已拒绝的旧文件也在打开设置后给出原因，不需再次点击。
            do {
                let selectedName = UserDefaults.standard.string(forKey: "selectedGifName")
                let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                let bookmarkData = UserDefaults.standard.data(forKey: "customGifBookmark")
                _ = try await Task.detached(priority: .utility) {
                    try GifResource.selectedData(selectedName: selectedName, appSupport: appSupport, bookmarkData: bookmarkData)
                }.value
            } catch {
                failureMessage = L10n.gifLoadFailed(selectedGif.isEmpty ? "GIF" : selectedGif, reason: error.localizedDescription)
            }
        }
    }

    @MainActor
    private func selectGif(name: String) async {
        guard !isLoading, let dir = gifsDirectory else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let url = dir.appendingPathComponent(name)
            _ = try await Task.detached(priority: .userInitiated) { try GifResource(contentsOf: url).data }.value
            selectedGif = name
            UserDefaults.standard.set(name, forKey: "selectedGifName")
            failureMessage = nil
            NotificationCenter.default.post(name: .init("GifDidChange"), object: nil)
        } catch {
            failureMessage = L10n.gifLoadFailed(name, reason: error.localizedDescription)
        }
    }

    @MainActor
    private func addGif(from url: URL) async {
        guard let dir = gifsDirectory else { return }

        do {
            let data = try await Task.detached(priority: .userInitiated) {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                return try GifResource(contentsOf: url).data
            }.value
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // 验证后的同一份字节才允许复制及自动选中。
            let baseName = url.deletingPathExtension().lastPathComponent
            var fileName = "\(baseName).gif"
            var counter = 1
            while gifList.contains(fileName) || FileManager.default.fileExists(atPath: dir.appendingPathComponent(fileName).path) {
                fileName = "\(baseName)_\(counter).gif"
                counter += 1
            }
            try data.write(to: dir.appendingPathComponent(fileName), options: .atomic)
            gifList.append(fileName)
            UserDefaults.standard.set(gifList, forKey: "customGifList")
            if selectedGif.isEmpty {
                selectedGif = fileName
                UserDefaults.standard.set(fileName, forKey: "selectedGifName")
                NotificationCenter.default.post(name: .init("GifDidChange"), object: nil)
            }
        } catch {
            failureMessage = L10n.gifLoadFailed(url.lastPathComponent, reason: error.localizedDescription)
        }
    }

    private func deleteGif(name: String) {
        guard let dir = gifsDirectory else { return }
        let gifURL = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: gifURL)

        gifList.removeAll { $0 == name }
        UserDefaults.standard.set(gifList, forKey: "customGifList")

        if selectedGif == name {
            selectedGif = ""
            UserDefaults.standard.set(selectedGif, forKey: "selectedGifName")
            NotificationCenter.default.post(name: .init("GifDidChange"), object: nil)
            if let nextName = gifList.first {
                Task { await selectGif(name: nextName) }
            }
        }
    }
}

// MARK: - GIF 缩略图

struct GifThumbnailView: View {
    let name: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var thumbnail: NSImage?
    @State private var loadError: String?

    private var gifsDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("XNook/gifs")
    }

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .topTrailing) {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 50, height: 50)
                        .overlay(
                            Image(systemName: loadError == nil ? "film" : "exclamationmark.triangle")
                                .foregroundColor(.secondary)
                        )
                }

                // 删除按钮
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                        .background(Circle().fill(Color.white))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
        }
        .buttonStyle(.plain)
        .help(loadError ?? name)
        .accessibilityLabel(loadError == nil ? name : "\(name): \(L10n.gifUnavailable)")
        .task(id: name) { await loadThumbnail() }
    }

    @MainActor
    private func loadThumbnail() async {
        guard let dir = gifsDirectory else { return }
        let gifURL = dir.appendingPathComponent(name)
        do {
            let image = try await Task.detached(priority: .utility) {
                try GifResource(contentsOf: gifURL).thumbnail()
            }.value
            guard !Task.isCancelled else { return }
            thumbnail = NSImage(cgImage: image, size: NSSize(width: 50, height: 50))
            loadError = nil
        } catch {
            guard !Task.isCancelled else { return }
            thumbnail = nil
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Mac 隐私按钮

func macPrivacyButton(title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 30)
    }
    .buttonStyle(.bordered)
}
