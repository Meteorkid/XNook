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
                                    selectedGif = name
                                    UserDefaults.standard.set(name, forKey: "selectedGifName")
                                    NotificationCenter.default.post(name: .init("GifDidChange"), object: nil)
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
                    for url in panel.urls {
                        addGif(from: url)
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func addGif(from url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        guard let dir = gifsDirectory else { return }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch { return }

        // 生成唯一文件名（避免重名覆盖）
        let baseName = url.lastPathComponent.replacingOccurrences(of: ".gif", with: "")
        var fileName = "\(baseName).gif"
        var counter = 1
        while gifList.contains(fileName) {
            fileName = "\(baseName)_\(counter).gif"
            counter += 1
        }

        let gifURL = dir.appendingPathComponent(fileName)
        do {
            try data.write(to: gifURL)
        } catch { return }

        gifList.append(fileName)
        UserDefaults.standard.set(gifList, forKey: "customGifList")

        // 如果是第一个 GIF，自动选中
        if selectedGif.isEmpty {
            selectedGif = fileName
            UserDefaults.standard.set(fileName, forKey: "selectedGifName")
            NotificationCenter.default.post(name: .init("GifDidChange"), object: nil)
        }
    }

    private func deleteGif(name: String) {
        guard let dir = gifsDirectory else { return }
        let gifURL = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: gifURL)

        gifList.removeAll { $0 == name }
        UserDefaults.standard.set(gifList, forKey: "customGifList")

        if selectedGif == name {
            selectedGif = gifList.first ?? ""
            UserDefaults.standard.set(selectedGif, forKey: "selectedGifName")
            NotificationCenter.default.post(name: .init("GifDidChange"), object: nil)
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
                            Image(systemName: "film")
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
        .onAppear { loadThumbnail() }
    }

    private func loadThumbnail() {
        guard let dir = gifsDirectory else { return }
        let gifURL = dir.appendingPathComponent(name)

        guard let source = CGImageSourceCreateWithURL(gifURL as CFURL, nil) else { return }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        thumbnail = NSImage(cgImage: cgImage, size: NSSize(width: 50, height: 50))
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
