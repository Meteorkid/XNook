import SwiftUI
import AppKit

/// 玻璃材质的高光调参；背衬深浅由用户在安全范围内调整。
enum IslandGlassTuning {
    /// 玻璃之上叠加的高光不透明度。
    ///
    /// 背衬已经保证对比度，这一层纯粹为了质感，取值必须保持极低。
    static let highlightCollapsed: Double = 0.05
    static let highlightExpanded: Double = 0.03
}

/// 灵动岛背景材质。
///
/// 默认使用不透明纯色；液态玻璃预设让岛采用深色配色，macOS 26 可使用 Liquid Glass。
/// 低版本或开启「减少透明度」时回退到纯黑填充。
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
/// 因此玻璃预设固定使用深色岛配色，设置窗口仍可保持浅色；浅色岛预设使用纯色。
///
/// ## 注意事项
///
/// 刻意不用 `NSGlassEffectView`：那是 AppKit 视图，嵌进 SwiftUI 需要
/// `NSViewRepresentable` 包装并手工同步圆角与 frame；`.glassEffect(_:in:)`
/// 直接接收 `Shape`，圆角由系统按形状裁剪，少一层手工同步的出错面。
struct IslandGlassBackground<ShapeType: Shape>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("islandBackgroundStyle") private var backgroundStyle = SettingsDefaults.string(for: "islandBackgroundStyle")
    @AppStorage("islandGlassDepth") private var glassDepth = SettingsDefaults.double(for: "islandGlassDepth")

    let shape: ShapeType
    let scheme: ColorScheme
    /// 展开态减少高光，避免大面积背景被抬亮。
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
        IslandBackgroundPolicy.usesGlass(
            style: IslandBackgroundStyle.resolved(from: backgroundStyle),
            supportsGlass: IslandCapabilities.supportsLiquidGlass && IslandCapabilities.useLiquidGlassBackground,
            isDark: usesDarkAppearance,
            reduceTransparency: reduceTransparency
        )
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

    // MARK: - 纯色与系统回退

    private var fallbackLayer: some View {
        shape.fill(solidFill)
    }

    private var backingOpacity: Double {
        IslandBackgroundPolicy.sanitizedGlassDepth(glassDepth)
    }

    private var highlightOpacity: Double {
        isExpanded ? IslandGlassTuning.highlightExpanded : IslandGlassTuning.highlightCollapsed
    }

    /// 回退填充：沿用此前的纯色方案，保证低版本与浅色模式的视觉与历史版本一致。
    private var solidFill: Color {
        usesDarkAppearance ? .black : Color(white: 0.965)
    }

    private var usesDarkAppearance: Bool {
        IslandBackgroundPolicy.isDark(style: IslandBackgroundStyle.resolved(from: backgroundStyle),
            applicationIsDark: scheme == .dark)
    }
}
