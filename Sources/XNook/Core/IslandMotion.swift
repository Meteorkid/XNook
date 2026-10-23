import SwiftUI

/// 展开 / 收起的动效参数。
///
/// 两条曲线刻意取相反取向：
/// - **展开**阻尼较低（约 0.55），保留一次明显回弹。面板是"从刘海长出来"的，
///   需要一点生命感，完全无过冲会显得生硬。
/// - **收起**阻尼接近临界（约 0.98），几乎不过冲。收回是"消失"，尾部抖动会显得廉价。
///
/// 参数按屏幕尺寸分档：形变距离随屏幕变大，同样的响应时间在大屏上会显得急促。
/// 基准档取经验值，紧凑 / 大屏档按距离等比缩放响应时间。
enum IslandMotion {
    /// 屏幕尺寸档位
    enum Tier: String, CaseIterable, Sendable {
        case compact
        case regular
        case large
    }

    struct Spring: Equatable, Sendable {
        var response: Double
        var dampingFraction: Double

        /// 每次访问新建 Animation：Animation 不是 Sendable，不放进 Preset 存储。
        var animation: Animation {
            .spring(response: response, dampingFraction: dampingFraction)
        }
    }

    struct Preset: Equatable, Sendable {
        var expand: Spring
        var collapse: Spring
        var hover: Spring
    }

    // MARK: - 分档阈值

    /// 小于此宽度按紧凑屏处理
    static let compactUpperBound: CGFloat = 1440
    /// 大于等于此宽度按大屏处理
    static let largeLowerBound: CGFloat = 1920

    static func tier(forScreenWidth width: CGFloat) -> Tier {
        guard width.isFinite, width > 0 else { return .regular }
        if width < compactUpperBound { return .compact }
        if width < largeLowerBound { return .regular }
        return .large
    }

    // MARK: - 参数表

    static let regularPreset = Preset(
        expand: Spring(response: 0.4, dampingFraction: 0.55),
        collapse: Spring(response: 0.3, dampingFraction: 0.98),
        hover: Spring(response: 0.25, dampingFraction: 0.55)
    )

    static let compactPreset = Preset(
        expand: Spring(response: 0.34, dampingFraction: 0.6),
        collapse: Spring(response: 0.26, dampingFraction: 0.98),
        hover: Spring(response: 0.22, dampingFraction: 0.6)
    )

    static let largePreset = Preset(
        expand: Spring(response: 0.46, dampingFraction: 0.55),
        collapse: Spring(response: 0.34, dampingFraction: 0.98),
        hover: Spring(response: 0.28, dampingFraction: 0.55)
    )

    static func preset(for tier: Tier) -> Preset {
        switch tier {
        case .compact: return compactPreset
        case .regular: return regularPreset
        case .large: return largePreset
        }
    }

    static func preset(forScreenWidth width: CGFloat) -> Preset {
        preset(for: tier(forScreenWidth: width))
    }

    // MARK: - 时长推算

    /// 弹簧从开始到视觉稳定所需的近似时长。
    /// 低阻尼会拖长尾部震荡，系数取得比临界阻尼更大；收起看门狗用它推算兜底超时。
    static func settleDuration(for spring: Spring) -> TimeInterval {
        let overshootFactor = spring.dampingFraction < 0.8 ? 2.4 : 1.6
        return spring.response * overshootFactor
    }
}
