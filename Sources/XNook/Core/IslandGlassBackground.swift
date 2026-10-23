import SwiftUI
import AppKit

/// 玻璃材质的调参。
///
/// 这些数值由实测确定，不是审美取值——调整前请先读 `IslandGlassBackground`
/// 的文档注释，或重跑探针验证对比度。
enum IslandGlassTuning {

    /// 深色模式下黑色背衬的不透明度（收起态）。
    ///
    /// 这是**安全参数**：玻璃本身半透明，背衬负责把面板亮度压回可读区间。
    /// 实测阈值约 0.45（对比度 8.62:1），这里取 0.50 留出余量。
    /// 调低会让文字在浅色壁纸上失去对比度。
    static let backingCollapsed: Double = 0.50

    /// 深色模式下黑色背衬的不透明度（展开态）。
    /// 展开面积大、文字多，压得比收起态更实一点。
    static let backingExpanded: Double = 0.55

    /// 玻璃之上叠加的高光不透明度。
    ///
    /// 背衬已经保证对比度，这一层纯粹为了质感，取值必须保持极低。
    static let highlightCollapsed: Double = 0.05
    static let highlightExpanded: Double = 0.03
}

/// 灵动岛背景材质。
///
/// macOS 26 起系统提供 Liquid Glass，能折射背后的桌面内容；低版本回退到纯色填充。
/// 两条路径保持调用方给定的形状与圆角，不改变灵动岛的外轮廓。
///
/// ## 为什么玻璃只在深色模式下启用
///
/// 这是实测结论，不是保守估计。探针用「不透明背景窗口 + 透明玻璃窗口」复现真实
/// 合成路径，按 WCAG 计算面板底色与文字的对比度（macOS 26.6.1）：
///
/// | 配色方案 | 背景 | 无背衬 | 加背衬 |
/// |---|---|---|---|
/// | 深色（白字） | 浅色 | **1.11:1 文字不可读** | 0.50 黑背衬 → **8.94:1** |
/// | 浅色（黑字） | 深色 | **1.87:1** | 0.92 白背衬 → 仅 **3.11:1** |
///
/// 根因是**不对称**：玻璃材质对背景的响应是"压暗"。深色模式下黑色背衬顺应这个
/// 压暗，很轻松就把面板拉到可读区间；浅色模式下白色背衬要对抗压暗，效率极低——
/// 即便把白色背衬加到 92%，面板亮度也只到 0.29，黑字仍达不到 AA。
///
/// 因此浅色模式回退纯色填充。代价是浅色模式拿不到玻璃质感，收益是文字在任何
/// 背景下都可读——对一个常驻屏幕顶部的信息面板，可读性优先。
///
/// ## 注意事项
///
/// 刻意不用 `NSGlassEffectView`：那是 AppKit 视图，嵌进 SwiftUI 需要
/// `NSViewRepresentable` 包装并手工同步圆角与 frame；`.glassEffect(_:in:)`
/// 直接接收 `Shape`，圆角由系统按形状裁剪，少一层手工同步的出错面。
struct IslandGlassBackground<ShapeType: Shape>: View {
    let shape: ShapeType
    let scheme: ColorScheme
    /// 展开态面积大、文字多，背衬压得更实
    var isExpanded: Bool = false

    var body: some View {
        if shouldUseGlass {
            glassLayer
        } else {
            fallbackLayer
        }
    }

    /// 玻璃的启用条件。深色模式是硬约束，理由见类型文档。
    private var shouldUseGlass: Bool {
        IslandCapabilities.supportsLiquidGlass
            && IslandCapabilities.useLiquidGlassBackground
            && scheme == .dark
    }

    // MARK: - macOS 26 深色模式

    @ViewBuilder
    private var glassLayer: some View {
        if #available(macOS 26.0, *) {
            // 层次（自下而上）：黑色背衬 → 玻璃 → 极轻高光。
            // 背衬必须在玻璃**之下**：玻璃采样它背后的内容，垫在下面才能既保住
            // 折射质感又压住亮度。放在玻璃之上会直接盖掉玻璃效果。
            shape
                .fill(Color.clear)
                .glassEffect(.regular, in: shape)
                .background {
                    shape.fill(Color.black.opacity(backingOpacity))
                }
                .overlay {
                    shape.fill(Color.white.opacity(highlightOpacity))
                }
        } else {
            fallbackLayer
        }
    }

    // MARK: - 回退：低版本或浅色模式

    private var fallbackLayer: some View {
        shape.fill(solidFill)
    }

    private var backingOpacity: Double {
        isExpanded ? IslandGlassTuning.backingExpanded : IslandGlassTuning.backingCollapsed
    }

    private var highlightOpacity: Double {
        isExpanded ? IslandGlassTuning.highlightExpanded : IslandGlassTuning.highlightCollapsed
    }

    /// 回退填充：沿用此前的纯色方案，保证低版本与浅色模式的视觉与历史版本一致。
    private var solidFill: Color {
        scheme == .dark ? .black : Color(white: 0.965)
    }
}
