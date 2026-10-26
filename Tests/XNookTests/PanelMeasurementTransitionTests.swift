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
        reconcile(&cached, signature: normalSignature(store))
        XCTAssertEqual(cached, normal)
        XCTAssertEqual(ExpandedPanelLayout.height(measuredContentHeight: cached?.height, maximumHeight: 900), 295)
        XCTAssertNil(defaults.object(forKey: PanelLayoutStore.storageKey))
    }

    func testDetailMeasurementArrivingBeforeNavigationAndWidthCallbacksIsRetained() {
        let store = PanelLayoutStore(defaults: defaults)
        let signature = store.configuration.signature
        let detail = measurement(signature: signature, height: 295, width: 460, selection: .media)
        // Binding 已指向媒体；子视图先布局并上报，父级 onChange 才依次执行。
        var cached = NotchContentView.acceptedPanelMeasurement(detail, width: 460, selectedWidget: .media,
            enabledWidgets: widgets, layoutSignature: signature)
        reconcile(&cached, signature: signature, width: 460, selection: .media)
        reconcile(&cached, signature: signature, width: 460, selection: .media)

        XCTAssertEqual(cached, detail)
        XCTAssertEqual(ExpandedPanelLayout.height(measuredContentHeight: cached?.height, maximumHeight: 900), 295,
            "先到的真实高度不应被后到回调抹掉并长期回退到 400pt")
        XCTAssertNil(defaults.object(forKey: PanelLayoutStore.storageKey))
    }

    func testContextCallbacksBeforeMeasurementRejectOnlyThePreviousPage() {
        let store = PanelLayoutStore(defaults: defaults)
        let previous = measurement(signature: normalSignature(store), height: 380)
        let signature = store.configuration.signature
        var cached: ExpandedPanelMeasurement? = previous
        reconcile(&cached, signature: signature, width: 460, selection: .media)
        XCTAssertNil(cached)

        let detail = measurement(signature: signature, height: 310, width: 460, selection: .media)
        cached = NotchContentView.acceptedPanelMeasurement(detail, width: 460, selectedWidget: .media,
            enabledWidgets: widgets, layoutSignature: signature)
        reconcile(&cached, signature: signature, width: 460, selection: .media)
        let lateOverview = NotchContentView.acceptedPanelMeasurement(previous, width: 460, selectedWidget: .media,
            enabledWidgets: widgets, layoutSignature: signature)
        XCTAssertNil(lateOverview, "旧页迟到测量不能进入生产接收路径")
        XCTAssertEqual(cached, detail)
    }

    func testRapidPageAndWidthChangesKeepOnlyTheLatestMatchingMeasurement() {
        let store = PanelLayoutStore(defaults: defaults)
        let contexts: [(NotchContentView.WidgetType?, CGFloat, CGFloat)] = [
            (.media, 460, 295), (nil, 800, 344), (.calendar, 800, 300), (nil, 320, 380), (.media, 460, 299)
        ]
        var cached: ExpandedPanelMeasurement?
        for (index, context) in contexts.enumerated() {
            let (selection, width, height) = context
            let signature = NotchContentView.normalPanelMeasurementSignature(layoutStore: store,
                automaticallyFit: true, selectedWidget: selection)
            let previous = cached
            if index.isMultiple(of: 2) {
                reconcile(&cached, signature: signature, width: width, selection: selection)
                XCTAssertNil(cached)
            }
            let next = measurement(signature: signature, height: height, width: width, selection: selection)
            cached = NotchContentView.acceptedPanelMeasurement(next, width: width, selectedWidget: selection,
                enabledWidgets: widgets, layoutSignature: signature)
            reconcile(&cached, signature: signature, width: width, selection: selection)
            XCTAssertEqual(cached, next)
            XCTAssertEqual(ExpandedPanelLayout.height(measuredContentHeight: cached?.height, maximumHeight: 900), height)
            if let previous {
                XCTAssertNil(NotchContentView.acceptedPanelMeasurement(previous, width: width, selectedWidget: selection,
                    enabledWidgets: widgets, layoutSignature: signature))
            }
        }
    }

    func testNotesCloseRollbackUsesTheFinalSelectionForReconciliation() {
        let signature = PanelLayoutStore(defaults: defaults).configuration.signature
        let notes = measurement(signature: signature, height: 350, width: 800, selection: .notes)
        var cached: ExpandedPanelMeasurement? = notes
        // 用户请求媒体但笔记未能保存，生产回调先退回笔记，再用最终选择校验。
        reconcile(&cached, signature: signature, width: 800, selection: .notes)
        XCTAssertEqual(cached, notes)
        let requestedPage = measurement(signature: signature, height: 295, width: 460, selection: .media)
        XCTAssertNil(NotchContentView.acceptedPanelMeasurement(requestedPage, width: 800, selectedWidget: .notes,
            enabledWidgets: widgets, layoutSignature: signature))
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
        var cached = accept(measurement(signature: currentSignature), signature: currentSignature)
        reconcile(&cached, signature: currentSignature)
        XCTAssertNotNil(cached, "新布局测量先到时，随后签名回调不应清除它")
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
        reconcile(&cached, signature: normalSignature(store))

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

    private func measurement(signature: String, height: CGFloat = 295, width: CGFloat = 800,
                             selection: NotchContentView.WidgetType? = nil) -> ExpandedPanelMeasurement {
        ExpandedPanelMeasurement(width: width, height: height, selectedWidget: selection,
            enabledWidgets: widgets, layoutSignature: signature)
    }

    private func reconcile(_ measurement: inout ExpandedPanelMeasurement?, signature: String,
                           width: CGFloat = 800, selection: NotchContentView.WidgetType? = nil) {
        NotchContentView.reconcilePanelMeasurement(&measurement, width: width, selectedWidget: selection,
            enabledWidgets: widgets, layoutSignature: signature)
    }

    private func accept(_ measurement: ExpandedPanelMeasurement?, signature: String) -> ExpandedPanelMeasurement? {
        NotchContentView.acceptedPanelMeasurement(measurement, width: 800, selectedWidget: nil,
            enabledWidgets: widgets, layoutSignature: signature)
    }
}
