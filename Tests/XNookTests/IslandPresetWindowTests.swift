import AppKit
import XCTest
@testable import XNook

@MainActor
final class IslandPresetWindowTests: XCTestCase {
    func testPresetChangesOnlyIslandWindowAppearanceAndPreservesApplicationPreference() {
        _ = NSApplication.shared
        let originalAppearance = NSApp.appearance
        let defaults = UserDefaults.standard
        let originalArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let originalMode = defaults.string(forKey: "appearanceMode")
        let delegate = AppDelegate()
        let island = NotchWindow(markVisible: {}, onExplicitShow: {})
        let settings = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 560, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: true)
        settings.isReleasedWhenClosed = false
        defer {
            island.close()
            settings.close()
            defaults.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
            delegate.themeManager.stopObservingSystemAppearance()
            NSApp.appearance = originalAppearance
        }

        let appAppearance: NSAppearance.Name = delegate.themeManager.resolvedScheme == .dark ? .darkAqua : .aqua
        for (style, expected) in [("black", NSAppearance.Name.darkAqua), ("light", .aqua),
                                  ("glass", .darkAqua), ("solid", appAppearance)] {
            var arguments = originalArguments
            arguments["islandBackgroundStyle"] = style
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            delegate.updateWindowAppearance(island)
            delegate.updateWindowAppearance(settings)

            XCTAssertEqual(island.appearance?.name, expected, style)
            XCTAssertEqual(settings.appearance?.name, appAppearance, style)
            XCTAssertEqual(defaults.string(forKey: "appearanceMode"), originalMode)
            XCTAssertFalse(island.isVisible)
            XCTAssertFalse(settings.isVisible)
        }
    }
}
