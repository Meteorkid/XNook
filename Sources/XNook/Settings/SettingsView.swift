import SwiftUI

/// 设置界面
struct SettingsView: View {
    @AppStorage("showOnAllSpaces") private var showOnAllSpaces = true
    @AppStorage("hideInFullscreen") private var hideInFullscreen = false
    @AppStorage("autoExpandOnHover") private var autoExpandOnHover = true
    @AppStorage("enableHaptics") private var enableHaptics = true

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

            AboutView()
            .tabItem {
                Label("About", systemImage: "info.circle")
            }
        }
        .frame(width: 500, height: 350)
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

            Text("Version 1.0.0")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            HStack(spacing: 20) {
                Link("GitHub", destination: URL(string: "https://github.com/Meteorkid/XNook")!)
                    .foregroundColor(.accentColor)

                Link("X Island", destination: URL(string: "https://github.com/Meteorkid/XIsland")!)
                    .foregroundColor(.accentColor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
}
