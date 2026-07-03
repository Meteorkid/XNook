[中文](README_zh.md) | English

<p align="center">
  <img src="Assets/app-icon.png" width="128" alt="X Nook">
</p>

<h1 align="center">X Nook</h1>

<p align="center">
  A macOS Dynamic Island-style tool center.<br>
  The companion app to X Island — media, calendar, notes, and file tray at your fingertips.
</p>

## Demo

<p align="center">
  <img src="Assets/demo.gif" width="560" alt="X Nook Demo">
</p>

| Collapsed | Expanded | Switch to X Island |
|:---------:|:--------:|:------------------:|
| <img src="Assets/screenshots/collapsed.png" width="220" alt="Collapsed"> | <img src="Assets/screenshots/expanded.png" width="220" alt="Expanded"> | <img src="Assets/screenshots/switch.png" width="220" alt="Switch"> |

## What It Does

X Nook sits at the top of your screen as a compact pill. Hover to expand and access your tools.

**Core features:**

- **Media Player** — Control music playback with album art display
- **Calendar Widget** — View upcoming events at a glance
- **Notes Widget** — Quick note-taking with Markdown support
- **File Tray** — Drag and drop files for quick access
- **App Switcher** — Double-finger swipe to switch between X Nook and X Island
- **Multi-display** — Automatically follows your mouse between screens
- **Notch-aware** — Designed for MacBook notch displays
- **Trackpad Gesture** — Two-finger scroll down to expand (configurable)
- **Jelly Animation** — Bounce animation when cursor enters the pill, with configurable intensity (weak/medium/strong)
- **Magnetic Effect** — Pill attracts toward cursor within proximity range
- **Invisible Cursor** — System cursor hidden while hovering the pill, restored on exit
- **Preferences** — Customize behavior in the settings window (⌘,)

**Coming soon:**

- Shortcuts integration
- Camera mirror widget
- Bluetooth device display
- Fluid gradient animations

## Requirements

- macOS 14.0 or later
- Xcode 15.0 or later

## Install

### Option 1: Build the App Bundle

```bash
chmod +x build-app.sh
./build-app.sh
open ".build/X Nook.app"
```

This is the recommended way to run X Nook locally because it includes the
required `Info.plist` privacy descriptions in the generated app bundle.

### Option 2: Development Build

Open `Package.swift` in Xcode for code navigation, or run a compile-only check:

```bash
swift build
```

## Architecture

```
XNook/
├── App/
│   ├── XNookApp.swift              # Entry point
│   └── AppDelegate.swift           # App delegate
├── Core/
│   ├── NotchWindow.swift           # Custom window management
│   ├── NotchDetector.swift         # Notch detection
│   ├── AppSwitcher.swift           # App switching
│   ├── IslandSizeCalculator.swift  # Island size calculation
│   ├── IslandStyle.swift           # Island styling
│   ├── NotchShapeGeometry.swift    # Notch shape geometry
│   └── SingleInstanceLock.swift    # Single instance lock
├── Features/
│   ├── NotchContentView.swift      # Main UI
│   ├── MediaWidget/                # Media player
│   ├── CalendarWidget/             # Calendar integration
│   ├── NotesWidget/                # Notes editor
│   └── TrayWidget/                 # File tray
├── Localization/
│   └── L10n.swift                  # Internationalization
└── Settings/
    └── SettingsView.swift          # Preferences
```

## Related Projects

- [X Island](https://github.com/Meteorkid/XIsland) — AI coding agent monitor
- [NotchNook](https://lo.cafe/notchnook) — The original Notch tool center (closed source)

## License

MIT License

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
