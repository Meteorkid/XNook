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

### Option 1: Build from Source

1. Clone the repository
2. Open `XNook.xcodeproj` in Xcode
3. Build and run (⌘R)

### Option 2: Swift Package Manager

```bash
swift build
swift run
```

## Architecture

```
XNook/
├── App/
│   ├── XNookApp.swift          # Entry point
│   └── AppDelegate.swift       # App delegate
├── Core/
│   ├── NotchWindow.swift       # Custom window management
│   ├── NotchDetector.swift     # Notch detection
│   ├── NotchViewModel.swift    # State management
│   └── AppSwitcher.swift       # App switching
├── Features/
│   ├── NotchContentView.swift  # Main UI
│   ├── MediaWidget/            # Media player
│   ├── CalendarWidget/         # Calendar integration
│   ├── NotesWidget/            # Notes editor
│   └── TrayWidget/             # File tray
└── Settings/
    └── SettingsView.swift      # Preferences
```

## Related Projects

- [X Island](https://github.com/Meteorkid/XIsland) — AI coding agent monitor
- [NotchNook](https://lo.cafe/notchnook) — The original Notch tool center (closed source)

## License

MIT License

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
