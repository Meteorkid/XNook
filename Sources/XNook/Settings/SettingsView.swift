import SwiftUI
import ServiceManagement
import AppKit

// MARK: - 设置视图

@MainActor
struct SettingsView: View {
    @Environment(UpdateManager.self) private var updateManager
    @State private var search: SettingsSearchState
    @State private var permissions: SettingsPermissions
    @State private var globalPanelShortcut: GlobalPanelShortcutController
    @State private var claudeReceiver: ClaudeCompletionReceiver
    @State private var claudeConfigurationCopied = false
    private let claudeConfiguration: String?
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var reduceMotion = SettingsDefaults.bool(for: "reduceMotion")
    @AppStorage("launchAtLogin") private var launchAtLogin = SettingsDefaults.bool(for: "launchAtLogin")
    @State private var panelLayoutStore: PanelLayoutStore
    @State private var layoutSaveError: String?
    @AppStorage("panelLayout.v1") private var panelLayoutData = Data()

    init(layoutDefaults: UserDefaults = .standard, search: SettingsSearchState? = nil,
         permissions: SettingsPermissions? = nil, claudeReceiver: ClaudeCompletionReceiver? = nil,
         claudeConfiguration: String? = nil, globalPanelShortcut: GlobalPanelShortcutController? = nil) {
        _panelLayoutStore = State(initialValue: PanelLayoutStore(defaults: layoutDefaults))
        _search = State(initialValue: search ?? SettingsSearchState())
        _permissions = State(initialValue: permissions ?? SettingsPermissions())
        _globalPanelShortcut = State(initialValue: globalPanelShortcut ?? AppDelegate.shared?.globalPanelShortcut
            ?? GlobalPanelShortcutController(defaults: layoutDefaults))
        _claudeReceiver = State(initialValue: claudeReceiver ?? AppDelegate.shared?.claudeCompletionReceiver
            ?? ClaudeCompletionReceiver(deliver: { _ in }))
        self.claudeConfiguration = claudeConfiguration ?? ClaudeHookConfiguration.bundledJSON
    }
    @AppStorage("quietHoursEnabled") private var quietHoursEnabled = SettingsDefaults.bool(for: "quietHoursEnabled")
    @AppStorage("quietHoursStart") private var quietHoursStart = SettingsDefaults.string(for: "quietHoursStart", fallback: "22:00")
    @AppStorage("quietHoursEnd") private var quietHoursEnd = SettingsDefaults.string(for: "quietHoursEnd", fallback: "07:00")
    @AppStorage("calendarReminderSoundEnabled") private var calendarReminderSoundEnabled = SettingsDefaults.bool(for: "calendarReminderSoundEnabled")
    @AppStorage("calendarReminderLeadMinutes") private var calendarReminderLeadMinutes = SettingsDefaults.double(for: "calendarReminderLeadMinutes", fallback: 5.0)
    @AppStorage("calendarReminderSoundName") private var calendarReminderSoundName = SettingsDefaults.string(for: "calendarReminderSoundName", fallback: "Glass")
    @AppStorage("showNookFlowHistory") private var showNookFlowHistory = SettingsDefaults.bool(for: "showNookFlowHistory", fallback: true)
    @AppStorage("nookFlowHistoryDisplayLimit") private var nookFlowHistoryDisplayLimit = SettingsDefaults.int(for: "nookFlowHistoryDisplayLimit", fallback: FocusSessionView.defaultHistoryDisplayLimit)
    @AppStorage("panelBaseHeight") private var panelBaseHeight = SettingsDefaults.double(for: "panelBaseHeight")
    @AppStorage("panelAutoSize") private var panelAutoSize = SettingsDefaults.bool(for: "panelAutoSize")
    @AppStorage("panelHeightMode") private var panelHeightMode = SettingsDefaults.string(for: "panelHeightMode")
    @AppStorage("panelWidth") private var panelWidth = SettingsDefaults.double(for: "panelWidth")
    @AppStorage("enabledWidgets") private var enabledWidgetsData = Data()
    @AppStorage("lyricsOffset") private var lyricsOffset = SettingsDefaults.double(for: "lyricsOffset")

    private var panelHeightRange: ClosedRange<Double> {
        let upper = max(1, Double(panelContentSizeLimit.height))
        return min(160, upper)...upper
    }

    private var selectedPanelHeightMode: PanelHeightMode {
        PanelHeightMode.resolved(storedValue: panelHeightMode, legacyAutomaticallyFit: panelAutoSize)
    }

    /// 改宽度前先固定旧高度语义；升级后首次操作不会顺带切换高度模式。
    static func widthAdaptationBinding(automaticallyFit: Binding<Bool>, heightMode: Binding<String>) -> Binding<Bool> {
        Binding(get: { automaticallyFit.wrappedValue }, set: { enabled in
            guard enabled != automaticallyFit.wrappedValue else { return }
            if PanelHeightMode(rawValue: heightMode.wrappedValue) == nil {
                heightMode.wrappedValue = PanelHeightMode.resolved(storedValue: heightMode.wrappedValue,
                    legacyAutomaticallyFit: automaticallyFit.wrappedValue).rawValue
            }
            automaticallyFit.wrappedValue = enabled
        })
    }

    private var panelWidthRange: ClosedRange<Double> {
        let upper = max(1, Double(panelContentSizeLimit.width))
        return min(160, upper)...upper
    }

    private var panelContentSizeLimit: CGSize {
        AppDelegate.shared?.notchWindow?.maximumExpandedContentSize()
            ?? CGSize(width: NotchWindow.maxExpandedWidth, height: NotchWindow.maxExpandedHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            searchField
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if search.isSearching { searchResults } else { paneContent }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .expandedPanelDebugFrame(id: "settingsViewport")
                .id(search.isSearching ? "search" : search.pane.rawValue)
                .task(id: search.targetID) {
                    guard let target = search.targetID else { return }
                    // 等待目标页进入布局；新搜索/切页会取消本次定位。
                    await Task.yield()
                    guard !Task.isCancelled, search.targetID == target, !search.isSearching else { return }
                    if reduceMotion || systemReduceMotion { proxy.scrollTo(target, anchor: .center) }
                    else { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .center) } }
                }
            }
        }
        .frame(width: 560)
        .frame(minHeight: 400, maxHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            clampPanelHeightToVisibleRange()
            panelLayoutStore.reload()
            permissions.refresh()
        }
        .onChange(of: search.targetID) { _, target in
            if let target { expandedDescriptions.insert(target) }
        }
        .onChange(of: launchAtLogin) { _, _ in permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
        .background(Button(L10n.settingsSearch) { searchFocused = true }
            .keyboardShortcut("f", modifiers: .command).hidden())
        .onChange(of: panelLayoutData) { _, _ in panelLayoutStore.reload() }
        .onChange(of: enabledWidgetsData) { _, _ in panelLayoutStore.reload() }
        .onChange(of: showNookFlowHistory) { _, _ in panelLayoutStore.reload() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in panelLayoutStore.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            clampPanelHeightToVisibleRange()
        }
    }

    // MARK: - 工具栏

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L10n.settingsSearch, text: $search.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityIdentifier("settings-search")
                .onSubmit { if let first = search.results.first { openSearchResult(first) } }
                .onExitCommand { search.query = "" }
            if !search.query.isEmpty {
                Button { search.query = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.settingsSearchClear)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(search.results.isEmpty ? L10n.settingsSearchEmpty : L10n.settingsResults(search.results.count))
                .font(.system(size: 13, weight: .semibold))
            if search.results.isEmpty {
                Text(L10n.settingsSearchHint).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(search.results) { entry in
                Button { openSearchResult(entry) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title).font(.system(size: 13, weight: .medium))
                            Text(entry.pane.title).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("search-result-" + entry.id)
            }
        }
    }

    private func openSearchResult(_ entry: SettingsSearchEntry) {
        searchFocused = false
        search.navigate(to: entry)
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            ForEach(SettingsPane.allCases) { pane in
                Button {
                    search.selectPane(pane)
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
                        search.pane == pane
                            ? RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor.opacity(0.15))
                            : nil
                    )
                    .foregroundColor(search.pane == pane ? .accentColor : .secondary)
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
        switch search.pane {
        case .general:
            generalPane
        case .display:
            displayPane
        case .integration:
            integrationPane
        case .license:
            LicenseActivationView().settingsSearchTarget(id: "softwareLicense", highlightedID: search.targetID)
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
                    SettingsPermissionsView(permissions: permissions, highlightedID: search.targetID)
                    dividerLine
                    HStack {
                        Button(L10n.settingsRefreshPermissions) { permissions.refresh() }
                        Spacer()
                        Button(L10n.openPrivacySecurityButton) { SystemPrivacySettings.openPrivacySecurity() }
                    }
                    .controlSize(.small)
                    .padding(.vertical, 8)
                }
            }

            section(L10n.sectionInteraction) {
                card {
                    GlobalPanelShortcutSettingsView(controller: globalPanelShortcut)
                        .settingsSearchTarget(id: "globalPanelShortcut", highlightedID: search.targetID)
                    dividerLine
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
                        AppStorageSlider(key: "expandedInactivityAutoHideDelay", range: 0.1...600, format: "%.2fs")
                    }
                    dividerLine
                    settingRow(L10n.hoverExitCollapseDelay, id: "hoverExit",
                              description: L10n.hoverExitCollapseDelayDesc) {
                        AppStorageSlider(key: "hoverExitCollapseDelay", range: 0.01...10, format: "%.2fs")
                    }
                }
            }

            section(L10n.activitySection) {
                card {
                    settingRow(L10n.activityEnabled, id: "activityNotificationsEnabled", description: L10n.activityEnabledHelp) {
                        AppStorageToggle(key: "activityNotificationsEnabled")
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
                    settingRow(L10n.activityCalendarEnabled, id: "calendarReminderActivityEnabled", description: L10n.activityCalendarHelp) {
                        AppStorageToggle(key: "calendarReminderActivityEnabled")
                    }
                    dividerLine
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

    /// 直接观察持久化数据，让同一设置页的开关随组件组合变化更新。
    private func moduleVisibility(_ id: PanelModuleID) -> Binding<Bool> {
        Binding(get: { panelLayoutStore.configuration.items.first { $0.id == id }?.isVisible ?? false }, set: { visible in
            panelLayoutStore.reload()
            var next = panelLayoutStore.configuration
            next.setVisible(id, visible: visible)
            do { try panelLayoutStore.save(next); layoutSaveError = nil }
            catch { layoutSaveError = error.localizedDescription }
        })
    }

    private var historyDisplayLimitBinding: Binding<Int> {
        Binding(
            get: { FocusSessionView.sanitizedHistoryDisplayLimit(nookFlowHistoryDisplayLimit) },
            set: { nookFlowHistoryDisplayLimit = FocusSessionView.sanitizedHistoryDisplayLimit($0) }
        )
    }

    private var displayPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            section(L10n.sectionAppearance) {
                card {
                    row(L10n.applicationAppearance) {
                        ThemePickerView()
                            .frame(width: 180)
                    }
                    .settingsSearchTarget(id: "applicationAppearance", highlightedID: search.targetID)
                    dividerLine
                    IslandBackgroundSettingsView(highlightedID: search.targetID)
                        .padding(.vertical, 8)
                }
            }

            section(L10n.sectionIslandSize) {
                card {
                    settingRow(L10n.islandWidth, id: "islandWidth",
                              description: L10n.islandWidthDesc) {
                        AppStorageSlider(key: "islandWidth", range: 40...600, format: "%.2fpt")
                    }
                    dividerLine
                    settingRow(L10n.islandHeight, id: "islandHeight",
                              description: L10n.islandHeightDesc) {
                        AppStorageSlider(key: "islandHeight", range: 8...120, format: "%.2fpt")
                    }
                }
            }

            section(L10n.sectionIslandSizeWithLyrics) {
                card {
                    settingRow(L10n.islandWidthWithLyrics, id: "islandWidthWithLyrics",
                              description: L10n.islandWidthWithLyricsDesc) {
                        AppStorageSlider(key: "islandWidthWithLyrics", range: 60...800, format: "%.2fpt")
                    }
                    dividerLine
                    settingRow(L10n.islandHeightWithLyrics, id: "islandHeightWithLyrics",
                              description: L10n.islandHeightWithLyricsDesc) {
                        AppStorageSlider(key: "islandHeightWithLyrics", range: 10...160, format: "%.2fpt")
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
                    settingRow(L10n.lyricsOffset, id: "lyricsOffset", description: L10n.lyricsOffsetHelp) {
                        HStack(spacing: 8) {
                            AppStorageSlider(key: "lyricsOffset", range: -5...5, step: 0.1, format: "%+.1fs")
                            Button(L10n.lyricsResetOffset) { lyricsOffset = 0 }
                                .controlSize(.small)
                                .fixedSize()
                                .disabled(lyricsOffset == 0)
                        }
                    }
                    dividerLine
                    settingRow(L10n.tickerSpeed, id: "tickerSpeed",
                              description: L10n.tickerSpeedDesc) {
                        AppStorageSlider(key: "tickerSpeed", range: 1...200, format: "%.2fpt/s")
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
                        AppStorageSlider(key: "panelWidth", range: panelWidthRange, format: "%.2fpt")
                    }
                    dividerLine
                    settingRow(L10n.panelAutoSize, id: "panelAutoSize",
                              description: L10n.panelAutoSizeDesc) {
                        Toggle("", isOn: Self.widthAdaptationBinding(automaticallyFit: $panelAutoSize,
                            heightMode: $panelHeightMode))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                    dividerLine
                    settingRow(L10n.panelHeightMode, id: "panelHeightMode",
                              description: L10n.panelHeightModeDesc) {
                        Picker(L10n.panelHeightMode, selection: Binding(
                            get: { selectedPanelHeightMode }, set: { panelHeightMode = $0.rawValue }
                        )) {
                            Text(L10n.panelHeightAutomatic).tag(PanelHeightMode.automatic)
                            Text(L10n.panelHeightLimited).tag(PanelHeightMode.limited)
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 268)
                    }
                    dividerLine
                    settingRow(L10n.panelBaseHeight, id: "panelBaseHeight",
                              description: L10n.panelBaseHeightDesc) {
                        AppStorageSlider(key: "panelBaseHeight", range: panelHeightRange, format: "%.2fpt")
                            .disabled(selectedPanelHeightMode != .limited)
                    }
                    Text(selectedPanelHeightMode == .automatic ? L10n.panelHeightAutomaticStatus
                        : L10n.panelHeightLimitedStatus(panelBaseHeight))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 10)
                        .accessibilityIdentifier("settingsPanelHeightStatus")
                        .expandedPanelDebugFrame(id: "settingsPanelHeightStatus")
                }
            }

            section(L10n.sectionNookFlow) {
                card {
                    settingRow(L10n.showNookFlowHistory, id: "showNookFlowHistory",
                              description: L10n.showNookFlowHistoryDesc) {
                        Toggle("", isOn: moduleVisibility(.recentTasks)).labelsHidden().disabled(!panelLayoutStore.canEdit)
                    }
                    dividerLine
                    settingRow(L10n.nookFlowHistoryDisplayLimit, id: "nookFlowHistoryDisplayLimit",
                              description: L10n.nookFlowHistoryDisplayLimitDesc) {
                        Picker("", selection: historyDisplayLimitBinding) {
                            ForEach(FocusSessionView.historyDisplayLimitRange, id: \.self) { count in
                                Text(L10n.nookFlowHistoryDisplayCount(count)).tag(count)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 120)
                        .disabled(!moduleVisibility(.recentTasks).wrappedValue)
                    }
                }
            }

            section(L10n.sectionWidgets) {
                card {
                    Text(L10n.settingsModuleChangesHint)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 10)
                    dividerLine
                    ForEach(PanelModuleID.allCases) { module in
                        if module != PanelModuleID.allCases.first { dividerLine }
                        settingRow(module.localizedName, id: "widget_\(module.rawValue)", description: "") {
                            Toggle("", isOn: moduleVisibility(module))
                                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                                .disabled(!panelLayoutStore.canEdit)
                        }
                    }
                    dividerLine
                    Button {
                        if let delegate = AppDelegate.shared { delegate.openLayoutEditor() }
                        else { NotificationCenter.default.post(name: .xnookEditPanelLayout, object: nil) }
                    } label: {
                        Label(L10n.settingsLayoutEditor, systemImage: "rectangle.3.group")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.vertical, 10)
                    .accessibilityIdentifier("settingsPanelLayoutEditor")
                    .settingsSearchTarget(id: "panelLayoutEditor", highlightedID: search.targetID)
                    Text(L10n.settingsLayoutGuide)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 10)
                    if let message = layoutSaveError ?? panelLayoutStore.loadError {
                        Text(message).font(.caption).foregroundStyle(.secondary)
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

    private func clampPanelHeightToVisibleRange() {
        panelBaseHeight = min(max(panelBaseHeight, panelHeightRange.lowerBound), panelHeightRange.upperBound)
        panelWidth = min(max(panelWidth, panelWidthRange.lowerBound), panelWidthRange.upperBound)
    }

    // MARK: - Integration 面板

    private var integrationPane: some View {
        let counterpart = AppSwitcher.shared.otherIsland ?? .xisland
        let status = AppSwitcher.shared.peerStatus(for: counterpart)

        return VStack(alignment: .leading, spacing: 16) {
            section("Claude Code") {
                card {
                    settingRow(L10n.claudeCompletion, id: "claudeCompletionEnabled", description: L10n.claudeCompletionHelp) {
                        AppStorageToggle(key: "claudeCompletionEnabled")
                    }
                    dividerLine
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.claudeReceiverState(claudeReceiver.state))
                            .font(.system(size: 12, weight: .medium))
                            .accessibilityIdentifier("settingsClaudeReceiverStatus")
                        Button(L10n.claudeCopyConfiguration) {
                            guard let claudeConfiguration else { return }
                            NSPasteboard.general.clearContents()
                            claudeConfigurationCopied = NSPasteboard.general.setString(claudeConfiguration, forType: .string)
                        }
                        .controlSize(.small)
                        .disabled(claudeConfiguration == nil)
                        .accessibilityIdentifier("settingsClaudeCopyConfiguration")
                        Text(claudeConfigurationCopied ? L10n.claudeConfigurationCopied
                             : (claudeConfiguration == nil ? L10n.claudeHelperMissing : L10n.claudeConfigurationHelp))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 8)
                }
            }
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
                            AppSwitcher.shared.switchToIslandWithPreview(named: counterpart.rawValue, direction: .left)
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
        .settingsSearchTarget(id: id, highlightedID: search.targetID)
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
}

// MARK: - 预览

#if !XNOOK_DISABLE_PREVIEWS
#Preview {
    SettingsView()
        .environment(ThemeManager())
        .environment(UpdateManager())
}
#endif
