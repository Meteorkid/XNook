import SwiftUI

/// 背景预设独立于设置窗口外观；生效条件直接显示，避免选择玻璃后无声回退。
struct IslandBackgroundSettingsView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("islandBackgroundStyle") private var rawStyle = SettingsDefaults.string(for: "islandBackgroundStyle")
    @AppStorage("islandGlassDepth") private var glassDepth = SettingsDefaults.double(for: "islandGlassDepth")
    var supportsGlass = IslandCapabilities.supportsLiquidGlass && IslandCapabilities.useLiquidGlassBackground
    /// 预览与隔离测试可注入系统条件，正常设置页始终读取真实辅助功能偏好。
    var reducedTransparencyOverride: Bool? = nil

    private var style: IslandBackgroundStyle { IslandBackgroundStyle.resolved(from: rawStyle) }
    private var styleBinding: Binding<IslandBackgroundStyle> {
        Binding(get: { style }, set: { rawStyle = $0.rawValue })
    }
    private var depthBinding: Binding<Double> {
        Binding(get: { IslandBackgroundPolicy.sanitizedGlassDepth(glassDepth) },
            set: { glassDepth = IslandBackgroundPolicy.sanitizedGlassDepth($0) })
    }
    private var transparencyReduced: Bool { reducedTransparencyOverride ?? reduceTransparency }
    private var glassAvailable: Bool { supportsGlass && !transparencyReduced }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.islandBackgroundStyle)
                .font(.system(size: 13, weight: .medium))
            Picker(L10n.islandBackgroundStyle, selection: styleBinding) {
                Text(L10n.backgroundSolid).tag(IslandBackgroundStyle.solid)
                Text(L10n.backgroundBlack).tag(IslandBackgroundStyle.black)
                Text(L10n.appearanceLight).tag(IslandBackgroundStyle.light)
                Text(L10n.backgroundGlass).tag(IslandBackgroundStyle.glass)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityIdentifier("islandBackgroundPresets")
            .expandedPanelDebugFrame(id: "backgroundPresets")

            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(style == .glass && !glassAvailable ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("islandBackgroundStatus")
                .expandedPanelDebugFrame(id: "backgroundStatus")

            if style == .glass {
                HStack(spacing: 8) {
                    Text(L10n.islandGlassDepth)
                        .font(.system(size: 12))
                    Slider(value: depthBinding, in: IslandBackgroundPolicy.glassDepthRange)
                        .accessibilityLabel(L10n.islandGlassDepth)
                        .accessibilityIdentifier("islandGlassDepthSlider")
                        .disabled(!glassAvailable)
                    Text(String(format: "%.0f%%", depthBinding.wrappedValue * 100))
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
                .expandedPanelDebugFrame(id: "glassDepthControls")
                Text(L10n.islandGlassDepthDesc)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .expandedPanelDebugFrame(id: "backgroundSettingsRoot")
    }

    private var statusText: String {
        switch style {
        case .solid: return L10n.backgroundFollowDescription
        case .black: return L10n.backgroundBlackDescription
        case .light: return L10n.backgroundLightDescription
        case .glass:
            if !supportsGlass { return L10n.glassUnsupported }
            if transparencyReduced { return L10n.glassReducedTransparency }
            return L10n.glassEnabled
        }
    }
}
