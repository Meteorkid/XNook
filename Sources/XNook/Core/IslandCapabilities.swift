import SwiftUI
import AppKit

/// 系统能力探测的单一事实源。
///
/// 存在的理由：版本判断散落在各处时，很容易漏掉某个调用点，或者把
/// 「API 存在」误当成「可以安全使用」。后者在本项目里有过实例——
/// `.drawOn` 虽然可用，但它的 `isActive` 是状态语义，初始为 `true` 会让图标消失
/// （已用离屏渲染实证：`isActive = false` 齿轮完整可见，`isActive = true` 全白）。
///
/// 因此这里把能力分成两类：
/// - **可用性**（availability）：系统版本是否够高，纯粹由版本决定
/// - **启用开关**（enabled）：即使可用，是否允许使用。给有语义陷阱的 API 留出
///   显式关闭的余地，而不是"能用就一定要用"
enum IslandCapabilities {

    // MARK: - 版本档位

    /// 当前系统所处的版本档位。用于日志与诊断，不直接驱动分支。
    enum Tier: String, Sendable {
        case ventura = "macOS 13"
        case sonoma = "macOS 14"
        case sequoia = "macOS 15"
        case tahoe = "macOS 26"
        case newer = "macOS 27+"
    }

    static var currentTier: Tier {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        switch version.majorVersion {
        case ..<14: return .ventura
        case 14: return .sonoma
        case 15: return .sequoia
        case 26: return .tahoe
        default: return .newer
        }
    }

    // MARK: - 可用性

    /// SF Symbols 7 的绘制效果（`.drawOn` / `.drawOff`）与玻璃材质同属 macOS 26。
    static var supportsLiquidGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// 原生图标绘制效果是否可用。
    static var supportsNativeSymbolDraw: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// 符号渐变渲染（`.symbolColorRenderingMode(.gradient)`）。
    static var supportsSymbolGradient: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    // MARK: - 启用开关

    /// 是否使用系统原生绘制效果替换遮罩扫出。
    ///
    /// **默认关闭，这是刻意的决定，不是遗漏。**
    ///
    /// 原生效果的 `isActive` 是状态而非触发：`true` 表示图标处于未绘制（不可见），
    /// 切到 `false` 才绘制出现。要做"悬停时重放一次"，必须让状态在
    /// `true → false` 之间切换；而一旦某条路径让它停在 `true`
    /// （视图复用、onAppear 未触发、动画被中断），图标会**永久消失**。
    ///
    /// 对一个常驻屏幕顶部的应用，图标不可见属于可感知故障，代价高于收益。
    /// 遮罩方案初始 `drawProgress = 1`，任何情况下图标都是可见的。
    ///
    /// 如需实测原生效果，把这里改成 `true` 即可；`IconMotionModifier`
    /// 已实现完整的两段式触发与超时兜底。
    static var useNativeSymbolDraw: Bool { false }

    /// 是否在面板背景使用玻璃材质。
    ///
    /// 与图标动效不同，玻璃材质没有"内容消失"类风险：效果不可用时视觉回退到
    /// 纯色填充，最坏情况只是不好看。因此默认开启。
    ///
    /// 注意：这里只控制「是否尝试」，实际是否生效还取决于配色方案——
    /// `IslandGlassBackground` 限定深色模式才用玻璃，因为浅色模式下玻璃
    /// 无法保证文字对比度（实测即便加 92% 白色背衬也只有 3.11:1）。
    /// 关闭这里会走回纯色填充，与 macOS 14/15 视觉一致。
    static var useLiquidGlassBackground: Bool { true }

    // MARK: - 诊断

    /// 供设置界面「关于」页展示的版本能力摘要。
    static var diagnosticsSummary: String {
        var lines: [String] = []
        lines.append("系统档位：\(currentTier.rawValue)")
        let glassState = supportsLiquidGlass
            ? (useLiquidGlassBackground ? "启用（仅深色模式）" : "可用但已关闭")
            : "不可用（纯色回退）"
        lines.append("玻璃材质：\(glassState)")
        let drawState = supportsNativeSymbolDraw
            ? (useNativeSymbolDraw ? "启用" : "可用但已关闭（遮罩扫出）")
            : "不可用（遮罩扫出）"
        lines.append("原生图标绘制：\(drawState)")
        return lines.joined(separator: "\n")
    }
}
