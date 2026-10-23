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

    func testLiquidGlassBackgroundIsEnabled() {
        XCTAssertTrue(IslandCapabilities.useLiquidGlassBackground)
    }

    // MARK: - 诊断

    func testDiagnosticsSummaryMentionsGlassScope() {
        let summary = IslandCapabilities.diagnosticsSummary
        XCTAssertTrue(summary.contains("系统档位"))
        XCTAssertTrue(summary.contains("玻璃材质"))
        XCTAssertTrue(summary.contains("图标绘制"))
        // 玻璃仅在深色模式生效，摘要里必须体现，避免用户以为浅色模式也用上了
        if IslandCapabilities.supportsLiquidGlass && IslandCapabilities.useLiquidGlassBackground {
            XCTAssertTrue(summary.contains("深色模式"),
                          "诊断摘要应说明玻璃材质仅在深色模式生效")
        }
    }

    // MARK: - 玻璃调参

    /// 背衬不透明度是安全参数，不是审美参数。
    ///
    /// 实测（macOS 26.6.1，WCAG 对比度）：深色模式 + 浅色背景下，
    /// 无背衬时文字对比度只有 1.11:1（不可读），0.45 背衬可达 8.62:1。
    /// 任何低于 0.45 的取值都会让文字在浅色壁纸上失去对比度。
    func testGlassBackingMeetsContrastThreshold() {
        XCTAssertGreaterThanOrEqual(IslandGlassTuning.backingCollapsed, 0.45,
                                    "背衬低于 0.45 会让深色模式下的白字失去对比度")
        XCTAssertGreaterThanOrEqual(IslandGlassTuning.backingExpanded, 0.45)
    }

    /// 展开态背衬不应低于收起态——展开面积大、文字多，需要压得更实。
    func testExpandedBackingIsAtLeastCollapsed() {
        XCTAssertGreaterThanOrEqual(IslandGlassTuning.backingExpanded,
                                    IslandGlassTuning.backingCollapsed)
    }

    /// 高光层取值必须极低：它叠在玻璃之上，取高了会反向抬亮面板，
    /// 抵消背衬压暗的效果。
    func testHighlightOpacityStaysSubtle() {
        XCTAssertLessThanOrEqual(IslandGlassTuning.highlightCollapsed, 0.10)
        XCTAssertLessThanOrEqual(IslandGlassTuning.highlightExpanded, 0.10)
    }

    func testOpacityValuesAreValidFractions() {
        let values = [
            IslandGlassTuning.backingCollapsed,
            IslandGlassTuning.backingExpanded,
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
    func testGlassBackgroundRendersInBothSchemes() {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 10, bottomLeadingRadius: 18,
            bottomTrailingRadius: 18, topTrailingRadius: 10,
            style: .continuous
        )
        for scheme in [ColorScheme.dark, ColorScheme.light] {
            let view = IslandGlassBackground(shape: shape, scheme: scheme, isExpanded: false)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 260, height: 44)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.width, 0, "\(scheme) 下背景层应正常布局")
        }
    }

    /// 展开态与收起态都要能渲染。
    @MainActor
    func testGlassBackgroundRendersExpanded() {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 10, bottomLeadingRadius: 18,
            bottomTrailingRadius: 18, topTrailingRadius: 10,
            style: .continuous
        )
        let view = IslandGlassBackground(shape: shape, scheme: .dark, isExpanded: true)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
    }
}
