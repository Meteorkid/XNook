import SwiftUI
import ServiceManagement

// MARK: - 设置面板枚举

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case display
    case integration
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L10n.general
        case .display: L10n.display
        case .integration: L10n.integration
        case .about: L10n.about
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .display: "paintbrush.fill"
        case .integration: "rectangle.connected.to.line.below"
        case .about: "info.circle.fill"
        }
    }
}

// MARK: - 设置视图

struct SettingsView: View {
    @Environment(UpdateManager.self) private var updateManager
    @State private var selection: SettingsPane = .general
    @AppStorage("quietHoursEnabled") private var quietHoursEnabled = SettingsDefaults.bool(for: "quietHoursEnabled")
    @AppStorage("quietHoursStart") private var quietHoursStart = SettingsDefaults.string(for: "quietHoursStart", fallback: "22:00")
    @AppStorage("quietHoursEnd") private var quietHoursEnd = SettingsDefaults.string(for: "quietHoursEnd", fallback: "07:00")
    @AppStorage("calendarReminderSoundEnabled") private var calendarReminderSoundEnabled = SettingsDefaults.bool(for: "calendarReminderSoundEnabled")
    @AppStorage("calendarReminderLeadMinutes") private var calendarReminderLeadMinutes = SettingsDefaults.double(for: "calendarReminderLeadMinutes", fallback: 5.0)
    @AppStorage("calendarReminderSoundName") private var calendarReminderSoundName = SettingsDefaults.string(for: "calendarReminderSoundName", fallback: "Glass")

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
        .frame(width: 560, height: 500)
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
        case .integration:
            integrationPane
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
                        AppStorageToggle(key: "showOnAllSpaces")
                    }
                    dividerLine
                    settingRow(L10n.hideInFullscreen, id: "hideInFullscreen",
                              description: L10n.hideInFullscreenDesc) {
                        AppStorageToggle(key: "hideInFullscreen")
                    }
                }
            }

            section(L10n.sectionMacPrivacy) {
                card {
                    Text(L10n.macPrivacyIntro)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 8)
                    dividerLine
                    HStack(spacing: 8) {
                        macPrivacyButton(title: L10n.openPrivacySecurityButton) {
                            SystemPrivacySettings.openPrivacySecurity()
                        }
                        macPrivacyButton(title: L10n.openCalendarsButton) {
                            SystemPrivacySettings.openCalendars()
                        }
                    }
                    .padding(.vertical, 8)
                    dividerLine
                    HStack(spacing: 8) {
                        macPrivacyButton(title: L10n.openAutomationButton) {
                            SystemPrivacySettings.openAutomation()
                        }
                        macPrivacyButton(title: L10n.openLoginItemsButton) {
                            SystemPrivacySettings.openLoginItems()
                        }
                    }
                    .padding(.vertical, 8)
                }
            }

            section(L10n.sectionInteraction) {
                card {
                    settingRow(L10n.hoverToExpand, id: "hoverToExpand",
                              description: L10n.hoverToExpandDesc) {
                        AppStorageToggle(key: "hoverToExpandPanel")
                    }
                    dividerLine
                    settingRow(L10n.scrollDownToExpand, id: "scrollDownToExpand",
                              description: L10n.scrollDownToExpandDesc) {
                        AppStorageToggle(key: "scrollDownToExpandPanel")
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

            section(L10n.sectionQuietHours) {
                card {
                    settingRow(L10n.enableQuietHours, id: "quietHoursEnabled",
                              description: L10n.enableQuietHoursDesc) {
                        AppStorageToggle(key: "quietHoursEnabled")
                    }
                    dividerLine
                    settingRow(L10n.fromTime, id: "quietHoursStart",
                              description: L10n.fromTimeDesc) {
                        timePicker(selection: $quietHoursStart)
                    }
                    dividerLine
                    settingRow(L10n.toTime, id: "quietHoursEnd",
                              description: L10n.toTimeDesc) {
                        timePicker(selection: $quietHoursEnd)
                    }
                    dividerLine
                    row(L10n.statusLabel, subtitle: quietHoursStatusText) {
                        Circle()
                            .fill(quietHoursEnabled && CalendarReminderManager.isQuietHoursActive(
                                enabled: quietHoursEnabled,
                                start: quietHoursStart,
                                end: quietHoursEnd
                            ) ? Color.orange : Color.green.opacity(0.6))
                            .frame(width: 8, height: 8)
                    }
                }
            }

            section(L10n.sectionCalendarReminders) {
                card {
                    settingRow(L10n.enableCalendarReminderSound, id: "calendarReminderSoundEnabled",
                              description: L10n.enableCalendarReminderSoundDesc) {
                        AppStorageToggle(key: "calendarReminderSoundEnabled")
                    }
                    dividerLine
                    settingRow(L10n.calendarReminderLeadTime, id: "calendarReminderLeadMinutes",
                              description: L10n.calendarReminderLeadTimeDesc) {
                        Picker("", selection: $calendarReminderLeadMinutes) {
                            ForEach(CalendarReminderManager.leadMinuteOptions, id: \.self) { minutes in
                                Text(L10n.minutesBefore(minutes)).tag(Double(minutes))
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 120)
                    }
                    dividerLine
                    settingRow(L10n.calendarReminderSoundName, id: "calendarReminderSoundName",
                              description: L10n.calendarReminderSoundNameDesc) {
                        Picker("", selection: $calendarReminderSoundName) {
                            ForEach(CalendarReminderManager.soundOptions) { option in
                                Text(option.rawValue).tag(option.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 120)
                    }
                    dividerLine
                    settingRow(L10n.testReminderSound, id: "testReminderSound",
                              description: L10n.testReminderSoundDesc) {
                        Button(L10n.playTestSound) {
                            CalendarReminderManager.shared.playPreviewSound()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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
            section(L10n.sectionAppearance) {
                card {
                    row(L10n.sectionAppearance) {
                        ThemePickerView()
                            .frame(width: 180)
                    }
                }
            }

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

            section(L10n.sectionIslandSizeWithLyrics) {
                card {
                    settingRow(L10n.islandWidthWithLyrics, id: "islandWidthWithLyrics",
                              description: L10n.islandWidthWithLyricsDesc) {
                        AppStorageSlider(key: "islandWidthWithLyrics", range: 120...400, format: "%.0fpt")
                    }
                    dividerLine
                    settingRow(L10n.islandHeightWithLyrics, id: "islandHeightWithLyrics",
                              description: L10n.islandHeightWithLyricsDesc) {
                        AppStorageSlider(key: "islandHeightWithLyrics", range: 20...60, format: "%.0fpt")
                    }
                }
            }

            section(L10n.sectionTicker) {
                card {
                    settingRow(L10n.showTickerLine, id: "showTickerLine",
                              description: L10n.showTickerLineDesc) {
                        AppStorageToggle(key: "showTickerLine")
                    }
                    dividerLine
                    settingRow(L10n.showLyrics, id: "showLyrics",
                              description: L10n.showLyricsDesc) {
                        AppStorageToggle(key: "showLyrics")
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
                        AppStorageToggle(key: "reduceMotion")
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

    // MARK: - Integration 面板

    private var integrationPane: some View {
        let counterpart = AppSwitcher.shared.otherIsland ?? .xisland
        let status = AppSwitcher.shared.peerStatus(for: counterpart)

        return VStack(alignment: .leading, spacing: 16) {
            section(L10n.sectionSwitching) {
                card {
                    settingRow(L10n.enableSwipeSwitch, id: "enableSwipeSwitch",
                              description: L10n.enableSwipeSwitchDesc) {
                        SharedDefaultsToggle(
                            key: IslandIntegrationSettings.Key.swipeSwitchEnabled,
                            defaultValue: true
                        )
                    }
                    dividerLine
                    settingRow(L10n.switchSensitivity, id: "switchSensitivity",
                              description: L10n.switchSensitivityDesc) {
                        SharedSensitivityPicker()
                    }
                    dividerLine
                    settingRow(L10n.startupDisplay, id: "startupDisplay",
                              description: L10n.startupDisplayDesc) {
                        SharedStartupDisplayPicker()
                    }
                }
            }

            section(L10n.sectionCompanionIsland) {
                card {
                    row(counterpart.displayName, subtitle: counterpartStatusSummary(status)) {
                        StatusPill(
                            title: status.isRunning ? L10n.statusRunning : L10n.statusStopped,
                            color: status.isRunning ? .green : .secondary
                        )
                    }
                    dividerLine
                    settingRow(L10n.counterpartInstalled, id: "counterpartInstalled",
                              description: L10n.counterpartInstalledDesc) {
                        StatusPill(
                            title: status.isInstalled ? L10n.statusInstalled : L10n.statusMissing,
                            color: status.isInstalled ? .green : .secondary
                        )
                    }
                    dividerLine
                    settingRow(L10n.counterpartProtocol, id: "counterpartProtocol",
                              description: L10n.counterpartProtocolDesc) {
                        StatusPill(
                            title: status.isProtocolConfigured ? L10n.statusReady : L10n.statusMisconfigured,
                            color: status.isProtocolConfigured ? .green : .orange
                        )
                    }
                    dividerLine
                    settingRow(L10n.testSwitch, id: "testSwitch",
                              description: L10n.testSwitchDesc) {
                        Button(L10n.testSwitchButton) {
                            AppSwitcher.shared.switchToIsland(named: counterpart.rawValue)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!status.isInstalled || !status.isProtocolConfigured)
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
                    row(L10n.github) {
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

            section(L10n.sectionUpdates) {
                card {
                    row(L10n.statusLabel, subtitle: updateStatusDetailText) {
                        StatusPill(title: updateStatusText, color: updateStatusColor)
                    }
                    dividerLine
                    row(L10n.latestRelease) {
                        Text(updateLatestReleaseText)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    dividerLine
                    row(L10n.lastChecked) {
                        Text(updateLastCheckedText)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    dividerLine
                    settingRow(L10n.autoCheckForUpdates, id: "autoCheckForUpdates",
                              description: L10n.autoCheckForUpdatesDesc) {
                        Toggle("", isOn: Binding(
                            get: { updateManager.autoCheckForUpdates },
                            set: { newValue in
                                updateManager.autoCheckForUpdates = newValue
                                if newValue {
                                    updateManager.startAutoCheck()
                                } else {
                                    updateManager.stopAutoCheck()
                                }
                            }
                        ))
                        .toggleStyle(.switch)
                    }
                    dividerLine
                    settingRow(L10n.checkForUpdates, id: "checkForUpdates",
                              description: L10n.checkForUpdatesDesc) {
                        Button(updateCheckButtonTitle) {
                            Task { @MainActor in
                                await updateManager.checkForUpdates()
                            }
                        }
                        .font(.system(size: 12))
                        .buttonStyle(.bordered)
                        .disabled(isCheckingForUpdates)
                    }
                    if let releaseURL = updateManager.latestRelease?.htmlURL {
                        dividerLine
                        settingRow(L10n.openLatestRelease, id: "openLatestRelease",
                                  description: L10n.openLatestReleaseDesc) {
                            Button(L10n.open) {
                                NSWorkspace.shared.open(releaseURL)
                            }
                            .font(.system(size: 12))
                            .buttonStyle(.bordered)
                        }
                    }
                    if case .updateAvailable = updateManager.state,
                       updateManager.latestRelease?.dmgURL != nil {
                        dividerLine
                        settingRow(L10n.installUpdate, id: "installUpdate",
                                  description: L10n.installUpdateDesc) {
                            Button(L10n.install) {
                                Task { @MainActor in
                                    await updateManager.installUpdate()
                                }
                            }
                            .font(.system(size: 12))
                            .buttonStyle(.borderedProminent)
                        }
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

    private func counterpartStatusSummary(_ status: IslandPeerStatus) -> String {
        [
            status.isInstalled ? L10n.statusInstalled : L10n.statusMissing,
            status.isRunning ? L10n.statusRunning : L10n.statusStopped,
            status.isProtocolConfigured ? L10n.statusReady : L10n.statusMisconfigured,
        ].joined(separator: " · ")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private func timePicker(selection: Binding<String>) -> some View {
        let formatter = Self.timeFormatter
        let date = Binding<Date>(
            get: { formatter.date(from: selection.wrappedValue) ?? Date() },
            set: { selection.wrappedValue = formatter.string(from: $0) }
        )
        return DatePicker("", selection: date, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .frame(width: 120)
    }

    private var quietHoursStatusText: String {
        guard quietHoursEnabled else { return L10n.disabled }
        return CalendarReminderManager.isQuietHoursActive(
            enabled: quietHoursEnabled,
            start: quietHoursStart,
            end: quietHoursEnd
        ) ? L10n.quietHoursActive : L10n.quietHoursInactive
    }

    private var isCheckingForUpdates: Bool {
        if case .checking = updateManager.state {
            return true
        }
        return false
    }

    private var updateLatestReleaseText: String {
        updateManager.latestRelease?.normalizedVersion ?? L10n.notCheckedYet
    }

    private var updateLastCheckedText: String {
        guard let lastCheckedAt = updateManager.lastCheckedAt else {
            return L10n.notCheckedYet
        }
        return lastCheckedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var updateCheckButtonTitle: String {
        isCheckingForUpdates ? L10n.checkForUpdatesButtonChecking : L10n.checkForUpdates
    }

    private var updateStatusText: String {
        switch updateManager.state {
        case .idle:
            return L10n.updateStatusIdle
        case .checking:
            return L10n.updateStatusChecking
        case .upToDate:
            return L10n.updateStatusUpToDate
        case .updateAvailable(let version):
            return L10n.updateStatusAvailable(version)
        case .installing(let stage):
            return L10n.updateInstalling(stage)
        case .failed:
            return L10n.updateStatusFailed
        }
    }

    private var updateStatusDetailText: String? {
        switch updateManager.state {
        case .failed(let message):
            return message
        case .updateAvailable(let version):
            return L10n.updateStatusAvailable(version)
        case .installing:
            return L10n.updateInstallingDetail
        default:
            return nil
        }
    }

    private var updateStatusColor: Color {
        switch updateManager.state {
        case .failed:
            return .red
        case .updateAvailable:
            return .orange
        case .checking:
            return .blue
        default:
            return .secondary
        }
    }

    private func macPrivacyButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.bordered)
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

private struct SharedDefaultsToggle: View {
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

private struct SharedSensitivityPicker: View {
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

private struct SharedStartupDisplayPicker: View {
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

private struct StatusPill: View {
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

/// 开机自启动开关
private struct LaunchAtLoginToggle: View {
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

private struct GifPickerButton: View {
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

private struct GifThumbnailView: View {
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

// MARK: - 预览

#Preview {
    SettingsView()
        .environment(ThemeManager())
        .environment(UpdateManager())
}
