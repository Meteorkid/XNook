import XCTest
@testable import XNook

@MainActor
final class PanelHeightModeTests: XCTestCase {
    func testMissingOrUnknownModeKeepsLegacyAutomaticAndManualBehavior() {
        for raw in ["", "unknown", "AUTOMATIC"] {
            XCTAssertEqual(PanelHeightMode.resolved(storedValue: raw, legacyAutomaticallyFit: true), .automatic)
            XCTAssertEqual(PanelHeightMode.resolved(storedValue: raw, legacyAutomaticallyFit: false), .limited)
            XCTAssertTrue(PanelHeightMode.fitsDefaultContent(storedValue: raw, legacyAutomaticallyFit: true))
            XCTAssertFalse(PanelHeightMode.fitsDefaultContent(storedValue: raw, legacyAutomaticallyFit: false))
        }
    }

    func testExplicitHeightModeDoesNotFollowAutomaticWidthSwitch() {
        for widthFits in [false, true] {
            XCTAssertEqual(PanelHeightMode.resolved(storedValue: "automatic", legacyAutomaticallyFit: widthFits), .automatic)
            XCTAssertEqual(PanelHeightMode.resolved(storedValue: "limited", legacyAutomaticallyFit: widthFits), .limited)
            XCTAssertTrue(PanelHeightMode.fitsDefaultContent(storedValue: "automatic", legacyAutomaticallyFit: widthFits))
            XCTAssertTrue(PanelHeightMode.fitsDefaultContent(storedValue: "limited", legacyAutomaticallyFit: widthFits))
        }
        XCTAssertEqual(ExpandedPanelLayout.width(preferred: 800, available: 1200,
            automaticallyFit: false, widgetCount: 3, selectedWidget: .media), 800)
        XCTAssertEqual(ExpandedPanelLayout.width(preferred: 800, available: 1200,
            automaticallyFit: true, widgetCount: 3, selectedWidget: .media), 460)
    }

    func testCustomLimitShrinksShortContentAndCapsLongContent() {
        for widthFits in [false, true] {
            let maximum = ExpandedPanelLayout.maximumHeight(availableHeight: 900,
                automaticallyFit: PanelHeightMode.resolved(storedValue: "limited", legacyAutomaticallyFit: widthFits) == .automatic,
                manualMaxHeight: 300)
            XCTAssertEqual(ExpandedPanelLayout.height(measuredContentHeight: 180, maximumHeight: maximum), 180)
            XCTAssertEqual(ExpandedPanelLayout.height(measuredContentHeight: 620, maximumHeight: maximum), 300)
            let automatic = ExpandedPanelLayout.maximumHeight(availableHeight: 900,
                automaticallyFit: PanelHeightMode.resolved(storedValue: "automatic", legacyAutomaticallyFit: widthFits) == .automatic,
                manualMaxHeight: 200)
            XCTAssertEqual(ExpandedPanelLayout.height(measuredContentHeight: 620, maximumHeight: automatic), 620)
        }
        XCTAssertEqual(ExpandedPanelLayout.maximumHeight(availableHeight: 240,
            automaticallyFit: false, manualMaxHeight: 300), 240)
    }

    func testReadingLegacyPreferencesDoesNotPersistAModeOrRewriteSavedLayout() throws {
        let suite = "XNookTests.PanelHeightMode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.register(defaults: ["panelHeightMode": ""])
        defaults.set(false, forKey: "panelAutoSize")
        defaults.set(280.0, forKey: "panelBaseHeight")
        let layoutData = try JSONEncoder().encode(PanelLayoutConfiguration.factoryDefault)
        defaults.set(layoutData, forKey: PanelLayoutStore.storageKey)
        let before = try XCTUnwrap(defaults.persistentDomain(forName: suite)) as NSDictionary
        let raw = defaults.string(forKey: "panelHeightMode") ?? ""
        XCTAssertEqual(PanelHeightMode.resolved(storedValue: raw,
            legacyAutomaticallyFit: defaults.bool(forKey: "panelAutoSize")), .limited)
        let store = PanelLayoutStore(defaults: defaults)
        for mode in PanelHeightMode.allCases {
            XCTAssertFalse(store.shouldFitDefaultContent(automaticallyFit:
                PanelHeightMode.fitsDefaultContent(storedValue: mode.rawValue, legacyAutomaticallyFit: false)),
                "显式高度模式不应收拢已经保存的组件网格")
        }
        XCTAssertEqual(defaults.string(forKey: "panelHeightMode"), "")
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["panelHeightMode"])
        XCTAssertEqual(defaults.data(forKey: PanelLayoutStore.storageKey), layoutData)
        XCTAssertEqual(defaults.persistentDomain(forName: suite) as NSDictionary?, before)
    }
}
