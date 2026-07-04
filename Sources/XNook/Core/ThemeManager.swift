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

    var onSchemeChange: (() -> Void)?

    var mode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.storageKey)
            updateResolvedScheme()
            syncAppAppearance()
            onSchemeChange?()
            if mode == .system {
                startObservingSystemAppearance()
            } else {
                stopObservingSystemAppearance()
            }
        }
    }

    private(set) var resolvedScheme: ColorScheme
    var effectiveAppearanceObservation: NSKeyValueObservation?

    init() {
        let initialMode: AppearanceMode = {
            if let raw = UserDefaults.standard.string(forKey: Self.storageKey),
               let saved = AppearanceMode(rawValue: raw) {
                return saved
            }
            return .system
        }()

        mode = initialMode
        resolvedScheme = initialMode == .dark ? .dark : .light
        updateResolvedScheme()
        syncAppAppearance()

        if initialMode == .system {
            startObservingSystemAppearance()
        }
    }

    func startObservingSystemAppearance() {
        guard effectiveAppearanceObservation == nil else { return }
        guard NSApp != nil else { return }

        effectiveAppearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.updateResolvedScheme()
                self?.syncAppAppearance()
                self?.onSchemeChange?()
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

        switch mode {
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .system:
            NSApp.appearance = nil
        }
    }
}
