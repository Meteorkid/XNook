import AppKit
import SwiftUI
import XCTest
@testable import XNook

/// 只操作隔离宿主的原生控件，不启动应用、不发送系统事件、不写真实偏好。
/// XNOOK_RENDER_UI=1 swift test --filter IslandBackgroundSettingsTests
@MainActor
final class IslandBackgroundSettingsTests: XCTestCase {
    func testAllPresetsAndInlineStatusFitBothLanguagesAndAppearances() throws {
        try requireRendering()
        try forEachAppearance { language, scheme in
            for style in [IslandBackgroundStyle.solid, .black, .light, .glass] {
                try withDefaults { defaults in
                    defaults.set(style.rawValue, forKey: "islandBackgroundStyle")
                    defaults.set("system", forKey: "appearanceMode")
                    let preview = try BackgroundSettingsPreview(defaults: defaults, scheme: scheme)
                    defer { preview.close() }
                    try verifyAndRecord(preview, style: style,
                        name: "background-\(style.rawValue)-\(language)-\(schemeName(scheme))")
                    XCTAssertEqual(defaults.string(forKey: "appearanceMode"), "system")
                }
            }
        }
    }

    func testBlackAndLightControlActionsPersistWithoutChangingApplicationAppearance() throws {
        try requireRendering()
        try forEachAppearance { language, scheme in
            try withDefaults { defaults in
                let applicationMode = schemeName(scheme)
                defaults.set(applicationMode, forKey: "appearanceMode")
                let preview = try BackgroundSettingsPreview(defaults: defaults, scheme: scheme)
                defer { preview.close() }
                for (style, index) in [(IslandBackgroundStyle.black, 1), (.light, 2)] {
                    let method = try selectPreset(index: index, in: preview)
                    preview.settle()
                    XCTAssertEqual(defaults.string(forKey: "islandBackgroundStyle"), style.rawValue)
                    XCTAssertEqual(defaults.string(forKey: "appearanceMode"), applicationMode,
                        "岛的背景选择不能改写应用外观")
                    try verifyAndRecord(preview, style: style,
                        name: "background-selected-\(style.rawValue)-\(language)-\(applicationMode)", action: method)

                    // 新建 AppStorage 消费者，确认写入值能被重新加载。
                    let rebuilt = try BackgroundSettingsPreview(defaults: defaults, scheme: scheme)
                    defer { rebuilt.close() }
                    try assertSelectedPreset(index: index, in: rebuilt)
                    try verifyAndRecord(rebuilt, style: style,
                        name: "background-rebuilt-\(style.rawValue)-\(language)-\(applicationMode)", action: method)
                    XCTAssertEqual(defaults.string(forKey: "appearanceMode"), applicationMode)
                }
            }
        }
    }

    func testGlassDepthControlPersistsAndReloadsAtBothEndsOfItsRange() throws {
        try requireRendering()
        try forEachAppearance { language, scheme in
            try withDefaults { defaults in
                defaults.set("glass", forKey: "islandBackgroundStyle")
                defaults.set("system", forKey: "appearanceMode")
                let preview = try BackgroundSettingsPreview(defaults: defaults, scheme: scheme)
                defer { preview.close() }
                try assertDepth(0.75, enabled: true, in: preview)
                for depth in [0.5, 0.9, 1.0] {
                    let method = try setDepth(depth, in: preview)
                    preview.settle()
                    XCTAssertEqual(defaults.double(forKey: "islandGlassDepth"), depth, accuracy: 0.001)
                    XCTAssertEqual(defaults.string(forKey: "appearanceMode"), "system")
                    try assertDepth(depth, enabled: true, in: preview)
                    let rebuilt = try BackgroundSettingsPreview(defaults: defaults, scheme: scheme)
                    defer { rebuilt.close() }
                    try assertDepth(depth, enabled: true, in: rebuilt)
                    try verifyAndRecord(rebuilt, style: .glass,
                        name: "background-glass-depth-\(Int(depth * 100))-\(language)-\(schemeName(scheme))", action: method)
                }
            }
        }
    }

    func testUnavailableGlassKeepsVisibleReasonAndDisablesDepthControl() throws {
        try requireRendering()
        try forEachAppearance { language, scheme in
            for supportsGlass in [false, true] {
                try withDefaults { defaults in
                    defaults.set("glass", forKey: "islandBackgroundStyle")
                    defaults.set(0.9, forKey: "islandGlassDepth")
                    defaults.set("system", forKey: "appearanceMode")
                    let preview = try BackgroundSettingsPreview(defaults: defaults, scheme: scheme,
                        supportsGlass: supportsGlass, reduceTransparency: supportsGlass)
                    defer { preview.close() }
                    let reason = supportsGlass ? "reduce-transparency" : "unsupported"
                    try verifyAndRecord(preview, style: .glass,
                        name: "background-glass-\(reason)-\(language)-\(schemeName(scheme))")
                    try assertDepth(0.9, enabled: false, in: preview)
                    XCTAssertEqual(defaults.string(forKey: "islandBackgroundStyle"), "glass",
                        "回退保留用户的玻璃预设，条件恢复后可以自动生效")
                    XCTAssertEqual(defaults.double(forKey: "islandGlassDepth"), 0.9, accuracy: 0.001)
                    XCTAssertEqual(defaults.string(forKey: "appearanceMode"), "system")
                }
            }
        }
    }

    private func requireRendering() throws {
        #if !DEBUG
        throw XCTSkip("背景设置几何探针只在 Debug 构建启用")
        #endif
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("使用 XNOOK_RENDER_UI=1 执行隔离离屏原生渲染")
        }
        _ = NSApplication.shared
    }

    private func forEachAppearance(_ action: (String, ColorScheme) throws -> Void) throws {
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        for language in ["zh", "en"] {
            var arguments = original
            arguments["appLanguage"] = language
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            for scheme in [ColorScheme.light, .dark] { try action(language, scheme) }
        }
    }

    private func withDefaults(_ action: (UserDefaults) throws -> Void) throws {
        let suiteName = "XNook.IslandBackgroundSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try action(defaults)
    }

    private var presetLabels: [String] {
        [L10n.backgroundSolid, L10n.backgroundBlack, L10n.appearanceLight, L10n.backgroundGlass]
    }

    private func expectedStatus(style: IslandBackgroundStyle, preview: BackgroundSettingsPreview) -> String {
        switch style {
        case .solid: return L10n.backgroundFollowDescription
        case .black: return L10n.backgroundBlackDescription
        case .light: return L10n.backgroundLightDescription
        case .glass:
            if !preview.supportsGlass { return L10n.glassUnsupported }
            return preview.reduceTransparency ? L10n.glassReducedTransparency : L10n.glassEnabled
        }
    }

    private func selectPreset(index: Int, in preview: BackgroundSettingsPreview) throws -> String {
        if let control = nativeControl(NSSegmentedControl.self, in: preview.host) {
            XCTAssertEqual(control.segmentCount, 4)
            XCTAssertTrue(control.isEnabled(forSegment: index))
            control.selectedSegment = index
            XCTAssertTrue(control.sendAction(control.action, to: control.target), "分段选择应触发生产绑定")
            return "NSSegmentedControl.selectedSegment+sendAction"
        }
        if let element = accessibilityElements(in: preview.host).first(where: {
            $0.accessibilityLabel() == presetLabels[index] && $0.accessibilityRole() == .radioButton
        }) {
            XCTAssertTrue(element.accessibilityPerformPress(), "宿主内的辅助功能选择应成功")
            return "host-accessibilityPerformPress"
        }
        throw XCTSkip("当前 SwiftUI 离屏宿主未暴露分段操作入口；布局夹具已独立覆盖，不能据此声称点击通过")
    }

    private func assertSelectedPreset(index: Int, in preview: BackgroundSettingsPreview) throws {
        if let control = nativeControl(NSSegmentedControl.self, in: preview.host) {
            XCTAssertEqual(control.selectedSegment, index)
            return
        }
        let element = try XCTUnwrap(accessibilityElements(in: preview.host).first {
            $0.accessibilityLabel() == presetLabels[index] && $0.accessibilityRole() == .radioButton
        })
        XCTAssertEqual((element.accessibilityValue() as? NSNumber)?.boolValue, true)
    }

    private func setDepth(_ depth: Double, in preview: BackgroundSettingsPreview) throws -> String {
        if let control = nativeControl(NSSlider.self, in: preview.host) {
            XCTAssertTrue(control.isEnabled)
            control.doubleValue = nativeDepth(depth, control: control)
            XCTAssertTrue(control.sendAction(control.action, to: control.target), "滑块应触发生产绑定")
            return "NSSlider.doubleValue+sendAction"
        }
        if let element = sliderElement(in: preview) {
            XCTAssertTrue(element.isAccessibilityEnabled())
            element.setAccessibilityValue(NSNumber(value: depth))
            return "host-setAccessibilityValue"
        }
        throw XCTSkip("当前 SwiftUI 离屏宿主未暴露滑块操作入口；不能将偏好夹具重建当成滑块交互通过")
    }

    private func assertDepth(_ depth: Double, enabled: Bool, in preview: BackgroundSettingsPreview) throws {
        XCTAssertNotNil(preview.record.frames["glassDepthControls"])
        if let control = nativeControl(NSSlider.self, in: preview.host) {
            XCTAssertEqual(control.isEnabled, enabled)
            XCTAssertGreaterThan(control.maxValue, control.minValue)
            XCTAssertEqual(control.doubleValue, nativeDepth(depth, control: control), accuracy: 0.001)
            return
        }
        if let element = sliderElement(in: preview) {
            XCTAssertEqual(element.isAccessibilityEnabled(), enabled)
            let actual = try XCTUnwrap(element.accessibilityValue() as? NSNumber)
            XCTAssertEqual(actual.doubleValue, depth, accuracy: 0.001)
            return
        }
        throw XCTSkip("当前 SwiftUI 离屏宿主不公开滑块状态；PNG 与几何只能确认说明和控件区域可见")
    }

    private func nativeDepth(_ depth: Double, control: NSSlider) -> Double {
        // SwiftUI 把业务区间映射到 NSSlider 的 0...1；以控件实际范围换算，业务值另由持久化断言验证。
        let range = IslandBackgroundPolicy.glassDepthRange
        return control.minValue + (depth - range.lowerBound) / (range.upperBound - range.lowerBound)
            * (control.maxValue - control.minValue)
    }

    private func sliderElement(in preview: BackgroundSettingsPreview) -> NSAccessibilityProtocol? {
        accessibilityElements(in: preview.host).first {
            $0.accessibilityIdentifier() == "islandGlassDepthSlider" || $0.accessibilityRole() == .slider
        }
    }

    private func verifyAndRecord(_ preview: BackgroundSettingsPreview, style: IslandBackgroundStyle,
                                 name: String, action: String = "none-fixture-render") throws {
        let frames = preview.record.frames
        let root = try XCTUnwrap(frames["backgroundSettingsRoot"])
        let presets = try XCTUnwrap(frames["backgroundPresets"])
        let status = try XCTUnwrap(frames["backgroundStatus"])
        XCTAssertEqual(root.width, 484, accuracy: 0.5)
        assertContained(presets, in: root, identifier: "backgroundPresets")
        assertContained(status, in: root, identifier: "backgroundStatus")
        XCTAssertLessThanOrEqual(presets.maxY, status.minY)
        if style == .glass {
            let controls = try XCTUnwrap(frames["glassDepthControls"])
            assertContained(controls, in: root, identifier: "glassDepthControls")
            XCTAssertLessThanOrEqual(status.maxY, controls.minY)
        } else {
            XCTAssertNil(frames["glassDepthControls"])
        }

        let elements = accessibilityElements(in: preview.host)
        var labelInspection = "geometry-and-pixels-only"
        var segmentMeasurements: [[String: Any]] = []
        if let control = nativeControl(NSSegmentedControl.self, in: preview.host) {
            XCTAssertEqual(control.segmentCount, 4)
            let selected = [IslandBackgroundStyle.solid, .black, .light, .glass].firstIndex(of: style)
            XCTAssertEqual(control.selectedSegment, selected)
            for index in presetLabels.indices {
                XCTAssertEqual(control.label(forSegment: index), presetLabels[index])
                let width = control.width(forSegment: index)
                let textWidth = (presetLabels[index] as NSString).size(withAttributes:
                    [.font: control.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width
                if width > 0 {
                    XCTAssertLessThanOrEqual(textWidth, width, "背景标签不能裁切：\(presetLabels[index])")
                }
                segmentMeasurements.append(["label": presetLabels[index], "width": width, "textWidth": textWidth])
            }
            labelInspection = "native-segment-labels-and-widths"
        } else if presetLabels.allSatisfy({ label in elements.contains { $0.accessibilityLabel() == label } }) {
            labelInspection = "host-accessibility-labels-and-geometry"
            for label in presetLabels {
                let element = try XCTUnwrap(elements.first { $0.accessibilityLabel() == label })
                let textWidth = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
                XCTAssertGreaterThanOrEqual(element.accessibilityFrame().width + 1, textWidth,
                    "背景标签辅助功能区域不能短于文字：\(label)")
            }
        }

        let message = expectedStatus(style: style, preview: preview)
        let textBounds = (message as NSString).boundingRect(with: CGSize(width: status.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 11)])
        XCTAssertGreaterThanOrEqual(status.height + 2, ceil(textBounds.height), "完整回退/生效说明不能垂直裁切")
        var statusInspection = "geometry-and-pixels-only"
        if let element = elements.first(where: { $0.accessibilityIdentifier() == "islandBackgroundStatus" }) {
            XCTAssertTrue(element.accessibilityLabel() == message || element.accessibilityValue() as? String == message,
                "状态应完整解释当前背景或回退条件")
            statusInspection = "host-accessibility-full-text"
        }
        let bitmap = try XCTUnwrap(preview.host.bitmapImageRepForCachingDisplay(in: preview.host.bounds))
        preview.host.cacheDisplay(in: preview.host.bounds, to: bitmap)
        assertVisiblePixels(bitmap, frame: presets, preview: preview)
        assertVisiblePixels(bitmap, frame: status, preview: preview)
        XCTAssertFalse(preview.window.isVisible)

        let directory = WorkflowPreviewEvidence.directory.appendingPathComponent("appearance", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        let evidence: [String: Any] = [
            "view": "IslandBackgroundSettingsView", "style": style.rawValue,
            "language": L10n.effectiveLanguage, "colorScheme": schemeName(preview.scheme),
            "supportsGlass": preview.supportsGlass, "reduceTransparency": preview.reduceTransparency,
            "width": preview.host.bounds.width, "height": preview.host.bounds.height,
            "windowVisible": preview.window.isVisible, "temporaryDefaults": true, "systemEventsSent": false,
            "acceptanceScope": "isolated-offscreen-production-view", "realWindowAcceptance": false,
            "interactionMethod": action, "presetLabels": presetLabels, "expectedStatus": message,
            "labelInspection": labelInspection, "statusInspection": statusInspection,
            "nativeSegmentMeasurements": segmentMeasurements,
            "textInspectionLimit": labelInspection == "geometry-and-pixels-only" || statusInspection == "geometry-and-pixels-only"
                ? "Some SwiftUI text is not exposed in this offscreen host; PNG requires visual review." : "none",
            "frames": frames.mapValues { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
        ]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
    }

    private func nativeControl<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let control = view as? T { return control }
        return view.subviews.lazy.compactMap { self.nativeControl(type, in: $0) }.first
    }

    private func accessibilityElements(in view: NSView) -> [NSAccessibilityProtocol] {
        var visited = Set<ObjectIdentifier>()
        func collect(_ value: Any) -> [NSAccessibilityProtocol] {
            guard let element = value as? NSAccessibilityProtocol,
                  visited.insert(ObjectIdentifier(element as AnyObject)).inserted else { return [] }
            return [element] + (element.accessibilityChildren() ?? []).flatMap(collect)
        }
        return collect(view)
    }

    private func assertContained(_ frame: CGRect, in root: CGRect, identifier: String) {
        XCTAssertGreaterThan(frame.width, 0, identifier)
        XCTAssertGreaterThan(frame.height, 0, identifier)
        XCTAssertGreaterThanOrEqual(frame.minX, root.minX - 0.5, identifier)
        XCTAssertLessThanOrEqual(frame.maxX, root.maxX + 0.5, identifier)
        XCTAssertGreaterThanOrEqual(frame.minY, root.minY - 0.5, identifier)
        XCTAssertLessThanOrEqual(frame.maxY, root.maxY + 0.5, identifier)
    }

    private func assertVisiblePixels(_ bitmap: NSBitmapImageRep, frame: CGRect, preview: BackgroundSettingsPreview) {
        let scaleX = CGFloat(bitmap.pixelsWide) / preview.host.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / preview.host.bounds.height
        let background: CGFloat = preview.scheme == .dark ? 17.0 / 255.0 : 0.92
        var contrastingPixels = 0
        for y in max(0, Int(frame.minY * scaleY))..<min(bitmap.pixelsHigh, Int(ceil(frame.maxY * scaleY))) {
            for x in max(0, Int(frame.minX * scaleX))..<min(bitmap.pixelsWide, Int(ceil(frame.maxX * scaleX))) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if [color.redComponent, color.greenComponent, color.blueComponent].contains(where: { abs($0 - background) > 0.15 }) {
                    contrastingPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(contrastingPixels, 8, "背景选项或状态说明必须实际绘制")
    }

    private func schemeName(_ scheme: ColorScheme) -> String { scheme == .dark ? "dark" : "light" }
}

@MainActor
private final class BackgroundSettingsPreview {
    let host: NSHostingView<BackgroundSettingsTestRoot>
    let window: NSWindow
    let record = BackgroundSettingsGeometryRecord()
    let model = BackgroundSettingsRenderModel()
    let scheme: ColorScheme
    let supportsGlass: Bool
    let reduceTransparency: Bool

    init(defaults: UserDefaults, scheme: ColorScheme, supportsGlass: Bool = true, reduceTransparency: Bool = false) throws {
        self.scheme = scheme
        self.supportsGlass = supportsGlass
        self.reduceTransparency = reduceTransparency
        host = NSHostingView(rootView: BackgroundSettingsTestRoot(defaults: defaults, model: model,
            record: record, scheme: scheme, supportsGlass: supportsGlass, reduceTransparency: reduceTransparency))
        host.frame = NSRect(origin: .zero, size: model.size)
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: model.size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        settle()
        let root = try XCTUnwrap(record.frames["backgroundSettingsRoot"], "未捕获生产背景设置视图")
        XCTAssertTrue(root.height.isFinite && root.height > 0)
        model.height = ceil(root.height)
        window.setContentSize(model.size)
        settle()
    }

    func settle() {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        if let root = record.frames["backgroundSettingsRoot"], abs(model.height - ceil(root.height)) > 0.5 {
            model.height = ceil(root.height)
            window.setContentSize(model.size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    func close() { window.contentView = nil; window.close() }
}

@MainActor
private final class BackgroundSettingsRenderModel: ObservableObject {
    // 560pt 设置窗口减去两侧 24pt 页面边距和 14pt 卡片边距。
    @Published var height: CGFloat = 240
    var size: CGSize { CGSize(width: 484, height: height) }
}

private final class BackgroundSettingsGeometryRecord {
    var frames: [String: CGRect] = [:]
}

@MainActor
private struct BackgroundSettingsTestRoot: View {
    let defaults: UserDefaults
    @ObservedObject var model: BackgroundSettingsRenderModel
    let record: BackgroundSettingsGeometryRecord
    let scheme: ColorScheme
    let supportsGlass: Bool
    let reduceTransparency: Bool

    var body: some View {
        IslandBackgroundSettingsView(supportsGlass: supportsGlass, reducedTransparencyOverride: reduceTransparency)
            .frame(width: model.size.width)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: model.size.width, height: model.height, alignment: .top)
            .background(Color(white: scheme == .dark ? 17.0 / 255.0 : 0.92))
            .coordinateSpace(name: "expandedPanelDebugGeometry")
            .environment(\.colorScheme, scheme)
            .defaultAppStorage(defaults)
            .environment(\.reportsExpandedPanelDebugGeometry, true)
            .onPreferenceChange(ExpandedPanelDebugGeometryKey.self) { record.frames = $0 }
    }
}
