import SwiftUI

/// 设置界面
struct SettingsView: View {
    @AppStorage("showOnAllSpaces") private var showOnAllSpaces = true
    @AppStorage("hideInFullscreen") private var hideInFullscreen = false
    @AppStorage("autoExpandOnHover") private var autoExpandOnHover = true
    @AppStorage("enableHaptics") private var enableHaptics = true

    // Widget 启用/禁用设置
    @AppStorage("enableMediaWidget") private var enableMediaWidget = true
    @AppStorage("enableCalendarWidget") private var enableCalendarWidget = true
    @AppStorage("enableNotesWidget") private var enableNotesWidget = true
    @AppStorage("enableTrayWidget") private var enableTrayWidget = true

    var body: some View {
        TabView {
            GeneralSettingsView(
                showOnAllSpaces: $showOnAllSpaces,
                hideInFullscreen: $hideInFullscreen,
                autoExpandOnHover: $autoExpandOnHover,
                enableHaptics: $enableHaptics
            )
            .tabItem {
                Label("General", systemImage: "gear")
            }

            WidgetSettingsView(
                enableMediaWidget: $enableMediaWidget,
                enableCalendarWidget: $enableCalendarWidget,
                enableNotesWidget: $enableNotesWidget,
                enableTrayWidget: $enableTrayWidget
            )
            .tabItem {
                Label("Widgets", systemImage: "square.grid.2x2")
            }

            AboutView()
            .tabItem {
                Label("About", systemImage: "info.circle")
            }
        }
        .frame(width: 500, height: 400)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @Binding var showOnAllSpaces: Bool
    @Binding var hideInFullscreen: Bool
    @Binding var autoExpandOnHover: Bool
    @Binding var enableHaptics: Bool

    var body: some View {
        Form {
            Section("Window") {
                Toggle("Show on all Spaces", isOn: $showOnAllSpaces)
                Toggle("Hide in full screen", isOn: $hideInFullscreen)
            }

            Section("Interaction") {
                Toggle("Auto expand on hover", isOn: $autoExpandOnHover)
                Toggle("Enable haptic feedback", isOn: $enableHaptics)
            }

            Section("App Switcher") {
                HStack {
                    Text("Quick switch gesture")
                        .foregroundColor(.primary)
                    Spacer()
                    Text("Double-finger swipe on island")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Switch to")
                        .foregroundColor(.primary)
                    Spacer()
                    Text("X Island")
                        .foregroundColor(.secondary)
                    Image(systemName: "arrow.right")
                        .foregroundColor(.accentColor)
                }
            }
        }
        .padding(20)
    }
}

// MARK: - Widget Settings

struct WidgetSettingsView: View {
    @Binding var enableMediaWidget: Bool
    @Binding var enableCalendarWidget: Bool
    @Binding var enableNotesWidget: Bool
    @Binding var enableTrayWidget: Bool

    var body: some View {
        Form {
            Section("Enable Widgets") {
                Toggle(isOn: $enableMediaWidget) {
                    HStack {
                        Image(systemName: "play.fill")
                            .foregroundColor(.pink)
                        Text("Media Widget")
                    }
                }

                Toggle(isOn: $enableCalendarWidget) {
                    HStack {
                        Image(systemName: "calendar")
                            .foregroundColor(.blue)
                        Text("Calendar Widget")
                    }
                }

                Toggle(isOn: $enableNotesWidget) {
                    HStack {
                        Image(systemName: "note.text")
                            .foregroundColor(.yellow)
                        Text("Notes Widget")
                    }
                }

                Toggle(isOn: $enableTrayWidget) {
                    HStack {
                        Image(systemName: "tray.full")
                            .foregroundColor(.green)
                        Text("Tray Widget")
                    }
                }
            }

            Section("Info") {
                HStack {
                    Text("Enabled widgets")
                        .foregroundColor(.primary)
                    Spacer()
                    Text("\(enabledCount) of 4")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(20)
    }

    private var enabledCount: Int {
        [enableMediaWidget, enableCalendarWidget, enableNotesWidget, enableTrayWidget].filter { $0 }.count
    }
}

// MARK: - About View

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("X Nook")
                .font(.title2)
                .fontWeight(.semibold)

            Text("A macOS Dynamic Island-style tool center")
                .foregroundColor(.secondary)

            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
               let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                Text("Version \(version) (\(build))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Version 1.0.0")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            VStack(spacing: 8) {
                Text("Created by Meteorkid")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 20) {
                    Link("GitHub", destination: URL(string: "https://github.com/Meteorkid/XNook")!)
                        .foregroundColor(.accentColor)

                    Link("X Island", destination: URL(string: "https://github.com/Meteorkid/XIsland")!)
                        .foregroundColor(.accentColor)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
}
