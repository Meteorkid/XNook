import SwiftUI

/// 灵动岛视觉样式 - 与 X Island 保持一致
enum IslandStyle {

    // MARK: - 文字颜色 (自动适配深色/浅色模式)

    /// 主要文字 - 高对比度标题/标签
    static var primaryText: Color { .primary }

    /// 次要文字 - 正文/描述
    static var secondaryText: Color { .secondary }

    /// 第三级文字 - 时间戳、元数据、提示
    static func tertiaryText(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.35) : .black.opacity(0.40)
    }

    // MARK: - 背景/装饰颜色 (按模式区分)

    /// 胶囊 + 展开面板背景
    static func surface(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .black : Color(white: 0.965)
    }

    /// 会话卡片 - 背景上的微妙提升
    static func cardRest(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.06) : Color(white: 0.91)
    }

    static func cardHover(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.10) : Color(white: 0.87)
    }

    /// 卡片边框 - 每种模式的全不透明专用颜色
    static func cardStrokeColor(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white : Color(white: 0.75)
    }

    static func cardStrokeRest(for scheme: ColorScheme) -> CGFloat {
        scheme == .dark ? 0.08 : 1.0
    }

    static func cardStrokeHover(for scheme: ColorScheme) -> CGFloat {
        scheme == .dark ? 0.14 : 1.0
    }

    /// 嵌套行（权限副本、问题选项、跳转芯片）
    static func insetFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.06) : Color(white: 0.89)
    }

    /// 代码/diff/markdown 井
    static func codeWell(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.05) : Color(white: 0.88)
    }

    /// 分隔线/分割线
    static func divider(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white : Color(white: 0.78)
    }

    static func dividerOpacity(for scheme: ColorScheme) -> CGFloat {
        scheme == .dark ? 0.08 : 1.0
    }

    /// 胶囊边框颜色和不透明度
    static func strokeColor(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white : Color(white: 0.75)
    }

    static func strokeOpacity(for scheme: ColorScheme) -> CGFloat {
        scheme == .dark ? 0.14 : 1.0
    }

    /// 阴影
    static func shadowColor(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .clear : .black
    }

    static func shadowOpacity(for scheme: ColorScheme) -> CGFloat {
        scheme == .dark ? 0.04 : 0.08
    }

    /// 强调色
    static func accent(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .cyan : .blue
    }

    // MARK: - 向后兼容的静态属性 (仅用于 Preview / 遗留代码，生产代码请用参数化版本)

    static var surface: Color { surface(for: .dark) }
    static var cardRest: Color { cardRest(for: .dark) }
    static var cardHover: Color { cardHover(for: .dark) }
    static var insetFill: Color { insetFill(for: .dark) }
    static var codeWell: Color { codeWell(for: .dark) }
}
