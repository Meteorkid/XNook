import Foundation

enum IslandBackgroundStyle: String, Sendable {
    /// 兼容已有设置：未指定独立背景时跟随应用外观。
    case solid
    case black
    case light
    case glass

    static func resolved(from rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .solid
    }
}

/// 背景偏好与系统回退规则，不读取用户的实际设置。
enum IslandBackgroundPolicy {
    static let glassDepthRange: ClosedRange<Double> = 0.5...1.0
    static let defaultGlassDepth: Double = 0.75

    static func isDark(style: IslandBackgroundStyle, applicationIsDark: Bool) -> Bool {
        switch style {
        case .solid: return applicationIsDark
        case .black, .glass: return true
        case .light: return false
        }
    }

    static func sanitizedGlassDepth(_ value: Double) -> Double {
        guard value.isFinite else { return defaultGlassDepth }
        return min(max(value, glassDepthRange.lowerBound), glassDepthRange.upperBound)
    }

    static func usesGlass(
        style: IslandBackgroundStyle,
        supportsGlass: Bool,
        isDark: Bool,
        reduceTransparency: Bool
    ) -> Bool {
        style == .glass && supportsGlass && isDark && !reduceTransparency
    }
}
