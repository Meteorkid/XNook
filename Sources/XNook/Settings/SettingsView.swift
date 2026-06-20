import SwiftUI
import ServiceManagement

// MARK: - 设置面板枚举

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case display
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L10n.general
        case .display: L10n.display
        case .about: L10n.about
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .display: "paintbrush.fill"
        case .about: "info.circle.fill"
        }
    }
}

// MARK: - 设置视图

struct SettingsView: View {
    @State private var selection: SettingsPane = .general

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                paneContent
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 520, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 0) {
            ForEach(SettingsPane.allCases) { pane in
                Button {
                    selection = pane
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: pane.icon)
                            .font(.system(size: 11))
                        Text(pane.title)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        selection == pane
                            ? RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor.opacity(0.15))
                            : nil
                    )
                    .foregroundColor(selection == pane ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 面板内容

    @ViewBuilder
    private var paneContent: some View {
        switch selection {
        case .general:
            generalPane
        case .display:
            displayPane
        case .about:
            aboutPane
        }
    }

    // MARK: - General 面板

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 语言切换（置顶）
            section(L10n.language) {
                card {
                    settingRow(L10n.language, id: "language",
                              description: L10n.languageDesc) {
                        LanguagePicker()
                    }
                }
            }

            section(L10n.sectionStartup) {
                card {
                    settingRow(L10n.launchAtLogin, id: "launchAtLogin",
                              description: L10n.launchAtLoginDesc) {
                        LaunchAtLoginToggle()
                    }
                    dividerLine
                    settingRow(L10n.showOnAllSpaces, id: "showOnAllSpaces",
                              description: L10n.showOnAllSpacesDesc) {
                        AppStorageToggle(key: "showOnAllSpaces", defaultValue: true)
                    }
                    dividerLine
                    settingRow(L10n.hideInFullscreen, id: "hideInFullscreen",
                              description: L10n.hideInFullscreenDesc) {
                        AppStorageToggle(key: "hideInFullscreen", defaultValue: true)
                    }
                }
            }

            section(L10n.sectionInteraction) {
                card {
                    settingRow(L10n.hoverToExpand, id: "hoverToExpand",
                              description: L10n.hoverToExpandDesc) {
                        AppStorageToggle(key: "hoverToExpandPanel", defaultValue: true)
                    }
                    dividerLine
                    settingRow(L10n.scrollDownToExpand, id: "scrollDownToExpand",
                              description: L10n.scrollDownToExpandDesc) {
                        AppStorageToggle(key: "scrollDownToExpandPanel", defaultValue: false)
                    }
                    dividerLine
                    settingRow(L10n.expandedInactivityHide, id: "expandedInactivity",
                              description: L10n.expandedInactivityHideDesc) {
                        AppStorageSlider(key: "expandedInactivityAutoHideDelay", range: 0...120, step: 1, format: "%.0fs")
                    }
                    dividerLine
                    settingRow(L10n.hoverExitCollapseDelay, id: "hoverExit",
                              description: L10n.hoverExitCollapseDelayDesc) {
                        AppStorageSlider(key: "hoverExitCollapseDelay", range: 0.1...3.0, step: 0.05, format: "%.2fs")
                    }
                }
            }
        }
    }

    // MARK: - Display 面板

    /// 每次访问都从 UserDefaults 读取，确保始终与实际值同步
    private var enabledWidgets: Set<String> {
        if let data = UserDefaults.standard.data(forKey: "enabledWidgets"),
           let widgets = try? JSONDecoder().decode(Set<String>.self, from: data) {
            return widgets
        }
        return ["media", "calendar", "notes", "tray"]
    }

    private var displayPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            section(L10n.sectionIslandSize) {
                card {
                    settingRow(L10n.islandWidth, id: "islandWidth",
                              description: L10n.islandWidthDesc) {
                        AppStorageSlider(key: "islandWidth", range: 80...350, format: "%.0fpt")
                    }
                    dividerLine
                    settingRow(L10n.islandHeight, id: "islandHeight",
                              description: L10n.islandHeightDesc) {
                        AppStorageSlider(key: "islandHeight", range: 16...60, format: "%.1fpt")
                    }
                }
            }

            section(L10n.sectionTicker) {
                card {
                    settingRow(L10n.showTickerLine, id: "showTickerLine",
                              description: L10n.showTickerLineDesc) {
                        AppStorageToggle(key: "showTickerLine", defaultValue: true)
                    }
                    dividerLine
                    settingRow(L10n.showLyrics, id: "showLyrics",
                              description: L10n.showLyricsDesc) {
                        AppStorageToggle(key: "showLyrics", defaultValue: true)
                    }
                    dividerLine
                    settingRow(L10n.tickerSpeed, id: "tickerSpeed",
                              description: L10n.tickerSpeedDesc) {
                        AppStorageSlider(key: "tickerSpeed", range: 10...60, step: 5, format: "%.0fpt/s")
                    }
                }
            }

            section(L10n.customGif) {
                card {
                    settingRow(L10n.customGif, id: "customGif",
                              description: L10n.customGifDesc) {
                        HStack(spacing: 8) {
                            GifPickerButton()
                        }
                    }
                }
            }

            section(L10n.sectionPanelSize) {
                card {
                    settingRow(L10n.panelWidth, id: "panelWidth",
                              description: L10n.panelWidthDesc) {
                        AppStorageSlider(key: "panelWidth", range: 200...800, format: "%.0fpt")
                    }
                    dividerLine
                    settingRow(L10n.panelMaxHeight, id: "panelMaxHeight",
                              description: L10n.panelMaxHeightDesc) {
                        AppStorageSlider(key: "panelMaxHeight", range: 200...900, format: "%.0fpt")
                    }
                }
            }

            section(L10n.sectionWidgets) {
                card {
                    ForEach(NotchContentView.WidgetType.allCases, id: \.self) { widget in
                        if widget != NotchContentView.WidgetType.allCases.first {
                            dividerLine
                        }
                        settingRow(widget.localizedName, id: "widget_\(widget.rawValue)",
                                  description: "") {
                            Toggle("", isOn: Binding(
                                get: { enabledWidgets.contains(widget.rawValue) },
                                set: { newValue in
                                    var current = enabledWidgets
                                    if newValue {
                                        current.insert(widget.rawValue)
                                    } else {
                                        current.remove(widget.rawValue)
                                    }
                                    if let data = try? JSONEncoder().encode(current) {
                                        UserDefaults.standard.set(data, forKey: "enabledWidgets")
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                        }
                    }
                }
            }

            section(L10n.sectionAccessibility) {
                card {
                    settingRow(L10n.reduceMotion, id: "reduceMotion",
                              description: L10n.reduceMotionDesc) {
                        AppStorageToggle(key: "reduceMotion", defaultValue: false)
                    }
                    dividerLine
                    settingRow(L10n.jellyIntensity, id: "jellyIntensity",
                              description: L10n.jellyIntensityDesc) {
                        Picker("", selection: Binding(
                            get: { UserDefaults.standard.string(forKey: "jellyIntensity") ?? "medium" },
                            set: { UserDefaults.standard.set($0, forKey: "jellyIntensity") }
                        )) {
                            Text(L10n.jellyWeak).tag("weak")
                            Text(L10n.jellyMedium).tag("medium")
                            Text(L10n.jellyStrong).tag("strong")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                }
            }
        }
    }

    // MARK: - About 面板

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("X Nook") {
                card {
                    row(L10n.version) {
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    dividerLine
                    row("GitHub") {
                        Button(L10n.open) {
                            if let url = URL(string: "https://github.com/meteorkid/XNook") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .font(.system(size: 12))
                        .buttonStyle(.bordered)
                    }
                }
            }

            section(L10n.sectionCredits) {
                card {
                    row(L10n.inspiredBy) {
                        Text("X Island by @meteorkid")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 布局辅助（模仿 X Island）

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.quaternary.opacity(0.5), lineWidth: 0.5)
        )
    }

    private func row<Trailing: View>(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            trailing()
        }
        .padding(.vertical, 8)
    }

    /// 带可展开注释的设置行
    @State private var expandedDescriptions: Set<String> = []

    private func settingRow<Trailing: View>(
        _ title: String,
        id: String,
        description: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        let isExpanded = expandedDescriptions.contains(id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if isExpanded {
                                    expandedDescriptions.remove(id)
                                } else {
                                    expandedDescriptions.insert(id)
                                }
                            }
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 16)
                trailing()
            }
            if isExpanded {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 8)
    }

    private var dividerLine: some View {
        Divider().overlay(.quaternary.opacity(0.4))
    }
}

// MARK: - 通用组件

/// 语言切换选择器
private struct LanguagePicker: View {
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

/// AppStorage 驱动的开关
private struct AppStorageToggle: View {
    @AppStorage private var value: Bool

    init(key: String, defaultValue: Bool) {
        _value = AppStorage(wrappedValue: defaultValue, key)
    }

    var body: some View {
        Toggle("", isOn: $value)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
    }
}

/// AppStorage 驱动的无级滑块（支持手动输入）
private struct AppStorageSlider: View {
    @AppStorage private var value: Double
    @State private var inputText: String = ""
    @State private var isEditing = false

    private let range: ClosedRange<Double>
    private let step: Double?
    private let format: String

    /// 无级调节（不传 step）
    init(key: String, range: ClosedRange<Double>, format: String = "%.0f") {
        _value = AppStorage(wrappedValue: range.lowerBound, key)
        self.range = range
        self.step = nil
        self.format = format
    }

    /// 带步长调节
    init(key: String, range: ClosedRange<Double>, step: Double, format: String = "%.0f") {
        _value = AppStorage(wrappedValue: range.lowerBound, key)
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
                    .frame(width: 45, alignment: .trailing)
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
                .frame(width: 45, alignment: .trailing)
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

/// 开机自启动开关
private struct LaunchAtLoginToggle: View {
    @AppStorage private var launchAtLogin: Bool

    init() {
        _launchAtLogin = AppStorage(wrappedValue: false, "launchAtLogin")
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

private struct GifPickerButton: View {
    @State private var gifName: String = UserDefaults.standard.string(forKey: "customGifName") ?? ""

    var body: some View {
        HStack(spacing: 8) {
            if !gifName.isEmpty {
                Text(gifName)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(width: 80, alignment: .leading)
            }

            Button(L10n.chooseGif) {
                let panel = NSOpenPanel()
                panel.title = L10n.chooseGif
                panel.allowedContentTypes = [.gif]
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false

                if panel.runModal() == .OK, let url = panel.url {
                    // 保存 bookmark data
                    if let data = try? url.bookmarkData(options: .withSecurityScope) {
                        UserDefaults.standard.set(data, forKey: "customGifBookmark")
                        UserDefaults.standard.set(url.lastPathComponent, forKey: "customGifName")
                        gifName = url.lastPathComponent
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if !gifName.isEmpty {
                Button(L10n.clearGif) {
                    UserDefaults.standard.removeObject(forKey: "customGifBookmark")
                    UserDefaults.standard.removeObject(forKey: "customGifName")
                    gifName = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - 预览

#Preview {
    SettingsView()
}
