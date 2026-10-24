import XCTest
import SwiftUI
@testable import XNook

final class IslandCapabilitiesTests: XCTestCase {

    // MARK: - 版本档位

    /// 档位划分必须与实际系统版本一致，否则诊断信息会误导排查。
    func testCurrentTierMatchesRunningSystem() {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let expected: IslandCapabilities.Tier
        switch major {
        case ..<14: expected = .ventura
        case 14: expected = .sonoma
        case 15: expected = .sequoia
        case 26: expected = .tahoe
        default: expected = .newer
        }
        XCTAssertEqual(IslandCapabilities.currentTier, expected)
    }

    /// 三个能力位同属 macOS 26：SF Symbols 7 绘制效果与玻璃材质是同一代 API。
    /// 一旦出现「玻璃可用但绘制效果不可用」，说明版本判断被改坏了。
    func testMacOS26FeaturesShareOneGate() {
        XCTAssertEqual(IslandCapabilities.supportsLiquidGlass,
                       IslandCapabilities.supportsNativeSymbolDraw)
        XCTAssertEqual(IslandCapabilities.supportsLiquidGlass,
                       IslandCapabilities.supportsSymbolGradient)
    }

    // MARK: - 启用开关

    /// 原生绘制效果**必须**保持关闭。
    ///
    /// 这不是"当前状态"的快照，而是安全红线：`.drawOn` 的 `isActive` 是状态语义，
    /// 停在 `true` 会让图标永久消失。常驻屏幕顶部的应用里，图标不可见属于可感知
    /// 故障。若将来要启用，必须同时改掉这条测试并说明兜底方案。
    func testNativeSymbolDrawStaysDisabled() {
        XCTAssertFalse(IslandCapabilities.useNativeSymbolDraw)
    }

    func testLiquidGlassCapabilityIsEnabled() {
        XCTAssertTrue(IslandCapabilities.useLiquidGlassBackground)
    }

    func testBackgroundDefaultsToSolid() {
        XCTAssertEqual(SettingsDefaults.string(for: "islandBackgroundStyle"), "solid")
    }

    // MARK: - 诊断

    func testDiagnosticsSummaryMentionsGlassScope() {
        let summary = IslandCapabilities.diagnosticsSummary(backgroundStyle: .glass, supportsGlass: true)
        XCTAssertTrue(summary.contains("系统档位"))
        XCTAssertTrue(summary.contains("玻璃材质"))
        XCTAssertTrue(summary.contains("图标绘制"))
        XCTAssertTrue(summary.contains("背景选择：液态玻璃"))
        XCTAssertTrue(summary.contains("已启用（岛使用深色配色）"))
    }

    func testDiagnosticsSummaryReportsSolidSelection() {
        let summary = IslandCapabilities.diagnosticsSummary(backgroundStyle: .solid, supportsGlass: true)
        XCTAssertTrue(summary.contains("背景选择：跟随外观"))
        XCTAssertTrue(summary.contains("当前使用纯色"))
    }

    func testDiagnosticsSummaryReportsGlassFallbackOnOlderSystems() {
        let summary = IslandCapabilities.diagnosticsSummary(backgroundStyle: .glass, supportsGlass: false)
        XCTAssertTrue(summary.contains("背景选择：液态玻璃"))
        XCTAssertTrue(summary.contains("不可用（纯色回退）"))
    }

    func testDiagnosticsReportsReducedTransparencyFallback() {
        let summary = IslandCapabilities.diagnosticsSummary(backgroundStyle: .glass, supportsGlass: true,
            reduceTransparency: true)
        XCTAssertTrue(summary.contains("未启用（系统减少透明度，纯黑回退）"))
    }

    func testDiagnosticsNamesExplicitBlackAndLight() {
        XCTAssertTrue(IslandCapabilities.diagnosticsSummary(backgroundStyle: .black, supportsGlass: true)
            .contains("背景选择：纯黑"))
        XCTAssertTrue(IslandCapabilities.diagnosticsSummary(backgroundStyle: .light, supportsGlass: true)
            .contains("背景选择：浅色"))
    }

    // MARK: - 玻璃调参

    /// 背衬不透明度是安全参数，不是审美参数。
    ///
    /// 实测（macOS 26.6.1，WCAG 对比度）：深色模式 + 浅色背景下，
    /// 无背衬时文字对比度只有 1.11:1（不可读），0.45 背衬可达 8.62:1。
    /// 任何低于 0.45 的取值都会让文字在浅色壁纸上失去对比度。
    func testGlassBackingMeetsContrastThreshold() {
        XCTAssertGreaterThanOrEqual(IslandBackgroundPolicy.glassDepthRange.lowerBound, 0.50,
                                    "最浅背衬仍需给文字对比度留出余量")
    }

    /// 高光层取值必须极低：它叠在玻璃之上，取高了会反向抬亮面板，
    /// 抵消背衬压暗的效果。
    func testHighlightOpacityStaysSubtle() {
        XCTAssertLessThanOrEqual(IslandGlassTuning.highlightCollapsed, 0.10)
        XCTAssertLessThanOrEqual(IslandGlassTuning.highlightExpanded, 0.10)
    }

    func testOpacityValuesAreValidFractions() {
        let values = [
            IslandBackgroundPolicy.defaultGlassDepth,
            IslandGlassTuning.highlightCollapsed,
            IslandGlassTuning.highlightExpanded
        ]
        for v in values {
            XCTAssertGreaterThan(v, 0)
            XCTAssertLessThan(v, 1)
        }
    }

    // MARK: - 渲染

    /// 两种配色方案都必须能渲染，且不因版本分支崩溃。
    /// 部署目标是 macOS 14，玻璃路径里的 `#available` 分支必须编译通过。
    @MainActor
    func testGlassBackgroundRendersInBothSchemes() throws {
        let suiteName = "XNook.BackgroundRendering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        SettingsDefaults.register(on: defaults)
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 10, bottomLeadingRadius: 18,
            bottomTrailingRadius: 18, topTrailingRadius: 10,
            style: .continuous
        )
        for style in [IslandBackgroundStyle.solid, .black, .light, .glass] {
            defaults.set(style.rawValue, forKey: "islandBackgroundStyle")
            for scheme in [ColorScheme.dark, ColorScheme.light] {
                let view = IslandGlassBackground(shape: shape, scheme: scheme, isExpanded: false)
                    .defaultAppStorage(defaults)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: 260, height: 44)
                host.layoutSubtreeIfNeeded()
                XCTAssertGreaterThan(host.fittingSize.width, 0, "\(style) / \(scheme) 下背景层应正常布局")
            }
        }
    }

    /// 展开态与收起态都要能渲染。
    @MainActor
    func testGlassBackgroundRendersExpanded() throws {
        let suiteName = "XNook.BackgroundRendering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        SettingsDefaults.register(on: defaults)
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 10, bottomLeadingRadius: 18,
            bottomTrailingRadius: 18, topTrailingRadius: 10,
            style: .continuous
        )
        let view = IslandGlassBackground(shape: shape, scheme: .dark, isExpanded: true)
            .defaultAppStorage(defaults)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
    }
}
