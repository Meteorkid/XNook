import XCTest
@testable import XNook

@MainActor
final class PanelMeasurementTransitionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let widgets: [NotchContentView.WidgetType] = [.media, .calendar, .tray]

    override func setUpWithError() throws {
        suiteName = "XNookTests.PanelMeasurementTransition.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(try JSONEncoder().encode(Set(widgets.map(\.rawValue))), forKey: "enabledWidgets")
        defaults.set(false, forKey: "showNookFlowHistory")
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testNormalMeasurementArrivingBeforeEditingExitSurvivesTheTransition() throws {
        let store = PanelLayoutStore(defaults: defaults)
        let editor = PanelLayoutEditingSession()
        let signature = normalSignature(store)
        XCTAssertTrue(signature.hasSuffix("|contentFit=1"))
        editor.begin(from: store)
        XCTAssertTrue(editor.isEditing)
        let editingSignature = PanelGridGeometry.measurementSignature(for: editor.draft,
            fitsContent: store.shouldFitDefaultContent(automaticallyFit: true, isEditing: true))
        XCTAssertNotEqual(editingSignature, signature, "编辑占位卡与正常内容采用不同尺寸政策")

        // 子视图先报告正常高度，父级仍在编辑视口阶段；不能按编辑签名拒绝这次唯一报告。
        let normal = measurement(signature: signature, height: 295)
        var cached = accept(normal, signature: normalSignature(store))
        XCTAssertEqual(cached, normal)
        XCTAssertFalse(normal.matches(width: 800, selectedWidget: nil, enabledWidgets: widgets,
            layoutSignature: editingSignature), "原编辑态签名会拒绝这条有效测量")

        // 随后才收到退出编辑回调，复核缓存时无需等待第二次测量或重新展开。
        editor.cancel()
        cached = accept(cached, signature: normalSignature(store))
        XCTAssertEqual(cached, normal)
        XCTAssertEqual(ExpandedPanelLayout.height(measuredContentHeight: cached?.height, maximumHeight: 900), 295)
        XCTAssertNil(defaults.object(forKey: PanelLayoutStore.storageKey))
    }

    func testEditingMeasurementCannotReplaceNormalContentHeight() {
        let store = PanelLayoutStore(defaults: defaults)
        let signature = normalSignature(store)
        var editing = measurement(signature: signature, height: 460)
        editing.isEditingLayout = true
        XCTAssertNil(accept(editing, signature: signature))
        XCTAssertNotNil(accept(measurement(signature: signature), signature: signature))
    }

    func testSavedLayoutChangeRejectsAnEarlierNormalMeasurement() throws {
        let store = PanelLayoutStore(defaults: defaults)
        let oldSignature = normalSignature(store)
        let old = measurement(signature: oldSignature)
        var changed = store.configuration
        changed.move(.currentTask, column: 0, row: 12)
        try store.save(changed)
        let saved = defaults.data(forKey: PanelLayoutStore.storageKey)
        let currentSignature = normalSignature(store)

        XCTAssertNotEqual(currentSignature, oldSignature)
        XCTAssertFalse(currentSignature.hasSuffix("|contentFit=1"))
        XCTAssertNil(accept(old, signature: currentSignature))
        XCTAssertNotNil(accept(measurement(signature: currentSignature), signature: currentSignature))
        XCTAssertEqual(defaults.data(forKey: PanelLayoutStore.storageKey), saved)
    }

    func testMeasurementStillRequiresCurrentWidthSelectionWidgetsAndValidHeight() {
        let signature = normalSignature(PanelLayoutStore(defaults: defaults))
        let invalid = [
            ExpandedPanelMeasurement(width: 640, height: 295, selectedWidget: nil,
                enabledWidgets: widgets, layoutSignature: signature),
            ExpandedPanelMeasurement(width: 800, height: 295, selectedWidget: .media,
                enabledWidgets: widgets, layoutSignature: signature),
            ExpandedPanelMeasurement(width: 800, height: 295, selectedWidget: nil,
                enabledWidgets: [.media], layoutSignature: signature),
            measurement(signature: "outdated-layout"),
            measurement(signature: signature, height: .nan),
            measurement(signature: signature, height: 0)
        ]
        for candidate in invalid { XCTAssertNil(accept(candidate, signature: signature)) }
        XCTAssertNil(accept(nil, signature: signature))
    }

    func testCancelPreservesSavedCustomLayoutAndItsMeasurementPolicy() throws {
        let store = PanelLayoutStore(defaults: defaults)
        var configuration = store.configuration
        configuration.resize(.media, columns: 6, rows: 6)
        try store.save(configuration)
        let original = defaults.data(forKey: PanelLayoutStore.storageKey)
        let signature = normalSignature(store)
        let normal = measurement(signature: signature, height: 540)
        let editor = PanelLayoutEditingSession()
        editor.begin(from: store)
        editor.draft.setVisible(.calendar, visible: false)
        var cached = accept(normal, signature: normalSignature(store))
        editor.cancel()
        cached = accept(cached, signature: normalSignature(store))

        XCTAssertEqual(cached, normal)
        XCTAssertFalse(signature.hasSuffix("|contentFit=1"))
        XCTAssertEqual(store.configuration, configuration)
        XCTAssertEqual(defaults.data(forKey: PanelLayoutStore.storageKey), original)
    }

    func testManualHeightAndDetailViewDoNotAcquireDefaultContentFit() {
        let store = PanelLayoutStore(defaults: defaults)
        for signature in [
            NotchContentView.normalPanelMeasurementSignature(layoutStore: store,
                automaticallyFit: false, selectedWidget: nil),
            NotchContentView.normalPanelMeasurementSignature(layoutStore: store,
                automaticallyFit: true, selectedWidget: .media)
        ] {
            XCTAssertEqual(signature, store.configuration.signature)
        }
    }

    private func normalSignature(_ store: PanelLayoutStore) -> String {
        NotchContentView.normalPanelMeasurementSignature(layoutStore: store,
            automaticallyFit: true, selectedWidget: nil)
    }

    private func measurement(signature: String, height: CGFloat = 295) -> ExpandedPanelMeasurement {
        ExpandedPanelMeasurement(width: 800, height: height, selectedWidget: nil,
            enabledWidgets: widgets, layoutSignature: signature)
    }

    private func accept(_ measurement: ExpandedPanelMeasurement?, signature: String) -> ExpandedPanelMeasurement? {
        NotchContentView.acceptedPanelMeasurement(measurement, width: 800, selectedWidget: nil,
            enabledWidgets: widgets, layoutSignature: signature)
    }
}
