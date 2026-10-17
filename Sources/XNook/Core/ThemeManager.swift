import AppKit
import Observation
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case dark
    case light
    case system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dark:
            return L10n.appearanceDark
        case .light:
            return L10n.appearanceLight
        case .system:
            return L10n.appearanceSystem
        }
    }
}

@Observable @MainActor
final class ThemeManager {
    private static let storageKey = "appearanceMode"
    private let defaults: UserDefaults

    var onSchemeChange: (() -> Void)?

    var mode: AppearanceMode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: Self.storageKey)
            stopObservingSystemAppearance()
            // 先解除旧的强制外观，再读取系统配色，否则切回 system 会读到旧值。
            syncAppAppearance()
            let previousScheme = resolvedScheme
            updateResolvedScheme()
            if resolvedScheme != previousScheme { onSchemeChange?() }
            if mode == .system {
                startObservingSystemAppearance()
            }
        }
    }

    private(set) var resolvedScheme: ColorScheme
    var effectiveAppearanceObservation: NSKeyValueObservation?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let initialMode: AppearanceMode = {
            if let raw = defaults.string(forKey: Self.storageKey),
               let saved = AppearanceMode(rawValue: raw) {
                return saved
            }
            return .system
        }()

        mode = initialMode
        resolvedScheme = initialMode == .dark ? .dark : .light
        syncAppAppearance()
        updateResolvedScheme()

        if initialMode == .system {
            startObservingSystemAppearance()
        }
    }

    func startObservingSystemAppearance() {
        guard mode == .system, effectiveAppearanceObservation == nil else { return }
        guard NSApp != nil else { return }

        effectiveAppearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.mode == .system else { return }
                let previousScheme = self.resolvedScheme
                self.updateResolvedScheme()
                // 观察回调只能读取外观；回写 appearance 会重新触发同一个 KVO。
                if self.resolvedScheme != previousScheme { self.onSchemeChange?() }
            }
        }
    }

    func stopObservingSystemAppearance() {
        effectiveAppearanceObservation?.invalidate()
        effectiveAppearanceObservation = nil
    }

    private func updateResolvedScheme() {
        switch mode {
        case .dark:
            resolvedScheme = .dark
        case .light:
            resolvedScheme = .light
        case .system:
            guard NSApp != nil else {
                resolvedScheme = .dark
                return
            }
            let appearance = NSApp.effectiveAppearance
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            resolvedScheme = match == .darkAqua ? .dark : .light
        }
    }

    private func syncAppAppearance() {
        guard NSApp != nil else { return }

        let appearanceName: NSAppearance.Name?
        switch mode {
        case .dark:
            appearanceName = .darkAqua
        case .light:
            appearanceName = .aqua
        case .system:
            appearanceName = nil
        }
        guard NSApp.appearance?.name != appearanceName else { return }
        NSApp.appearance = appearanceName.flatMap(NSAppearance.init(named:))
    }
}
