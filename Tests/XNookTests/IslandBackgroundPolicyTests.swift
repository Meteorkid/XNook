import XCTest
import AppKit
import SwiftUI
@testable import XNook

final class IslandBackgroundPolicyTests: XCTestCase {
    @MainActor
    func testOpaquePresetPixelsIgnoreTheOppositeApplicationAppearance() throws {
        _ = NSApplication.shared
        let suite = "XNook.OpaquePresetPixels.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for (style, scheme, expected) in [(IslandBackgroundStyle.black, ColorScheme.light, CGFloat(0)),
                                          (.light, .dark, CGFloat(0.965))] {
            defaults.set(style.rawValue, forKey: "islandBackgroundStyle")
            let host = NSHostingView(rootView: IslandGlassBackground(shape: Rectangle(), scheme: scheme)
                .defaultAppStorage(defaults))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 80, height: 40),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host.frame = NSRect(x: 0, y: 0, width: 80, height: 40)
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
                .flatMap { $0.usingColorSpace(.deviceRGB) })
            XCTAssertEqual(color.redComponent, expected, accuracy: 0.015)
            XCTAssertEqual(color.greenComponent, expected, accuracy: 0.015)
            XCTAssertEqual(color.blueComponent, expected, accuracy: 0.015)
            XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.01)
            XCTAssertFalse(window.isVisible)
        }
    }

    func testMissingAndInvalidStyleFallBackToSolid() {
        for rawValue in [nil, "", "unknown", "GLASS", " glass "] as [String?] {
            XCTAssertEqual(IslandBackgroundStyle.resolved(from: rawValue), .solid)
        }
        XCTAssertEqual(IslandBackgroundStyle.resolved(from: "solid"), .solid)
        XCTAssertEqual(IslandBackgroundStyle.resolved(from: "glass"), .glass)
        XCTAssertEqual(IslandBackgroundStyle.resolved(from: "black"), .black)
        XCTAssertEqual(IslandBackgroundStyle.resolved(from: "light"), .light)
    }

    func testExplicitPresetsResolveTheIslandWithoutChangingApplicationAppearance() {
        for applicationIsDark in [true, false] {
            XCTAssertEqual(IslandBackgroundPolicy.isDark(style: .solid, applicationIsDark: applicationIsDark), applicationIsDark)
            XCTAssertTrue(IslandBackgroundPolicy.isDark(style: .black, applicationIsDark: applicationIsDark))
            XCTAssertFalse(IslandBackgroundPolicy.isDark(style: .light, applicationIsDark: applicationIsDark))
            XCTAssertTrue(IslandBackgroundPolicy.isDark(style: .glass, applicationIsDark: applicationIsDark))
        }
    }

    func testFixedBlackAndLightRemainOpaqueEvenWhenGlassIsSupported() {
        for style in [IslandBackgroundStyle.black, .light] {
            XCTAssertFalse(IslandBackgroundPolicy.usesGlass(style: style, supportsGlass: true,
                isDark: IslandBackgroundPolicy.isDark(style: style, applicationIsDark: false), reduceTransparency: false))
        }
    }

    func testSolidNeverUsesGlassEvenWhenAvailable() {
        XCTAssertFalse(IslandBackgroundPolicy.usesGlass(
            style: .solid, supportsGlass: true, isDark: true, reduceTransparency: false
        ))
    }

    func testGlassRequiresSupportedDarkAppearanceWithoutReducedTransparency() {
        let cases: [(supportsGlass: Bool, isDark: Bool, reduceTransparency: Bool, expected: Bool)] = [
            (true, true, false, true),
            (false, true, false, false),
            (true, false, false, false),
            (true, true, true, false),
            (false, false, true, false)
        ]
        for item in cases {
            XCTAssertEqual(IslandBackgroundPolicy.usesGlass(
                style: .glass,
                supportsGlass: item.supportsGlass,
                isDark: item.isDark,
                reduceTransparency: item.reduceTransparency
            ), item.expected)
        }
    }

    func testGlassDepthClampsFiniteValuesToReadableRange() {
        let cases: [(Double, Double)] = [
            (-1, 0.5), (0, 0.5), (0.49, 0.5), (0.5, 0.5),
            (0.75, 0.75), (1, 1), (1.01, 1), (.greatestFiniteMagnitude, 1)
        ]
        for (input, expected) in cases {
            XCTAssertEqual(IslandBackgroundPolicy.sanitizedGlassDepth(input), expected)
        }
    }

    func testNonFiniteGlassDepthUsesDefault() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(IslandBackgroundPolicy.sanitizedGlassDepth(value), 0.75)
        }
    }

    func testDefaultRegistrationAndStoredPreferenceUseIsolatedSuite() throws {
        let suiteName = "XNook.BackgroundPreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SettingsDefaults.register(on: defaults)
        XCTAssertEqual(defaults.string(forKey: "islandBackgroundStyle"), "solid")
        XCTAssertEqual(defaults.double(forKey: "islandGlassDepth"), 0.75)

        defaults.set("glass", forKey: "islandBackgroundStyle")
        defaults.set(0.6, forKey: "islandGlassDepth")
        SettingsDefaults.register(on: defaults)
        let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertEqual(reopenedDefaults.string(forKey: "islandBackgroundStyle"), "glass")
        XCTAssertEqual(reopenedDefaults.double(forKey: "islandGlassDepth"), 0.6)
    }
}
