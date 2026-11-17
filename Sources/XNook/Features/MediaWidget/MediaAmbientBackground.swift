import SwiftUI

enum MediaAmbientStyle: String, CaseIterable, Identifiable {
    case off, glow, dynamicBlur

    var id: Self { self }

    var localizedName: String {
        switch self {
        case .off: return L10n.localized(zh: "关闭", en: "Off")
        case .glow: return L10n.localized(zh: "封面柔光", en: "Artwork Glow")
        case .dynamicBlur: return L10n.localized(zh: "动态模糊", en: "Moving Blur")
        }
    }

    static func resolved(_ rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? .glow
    }
}

/// 只累计实际播放动效的时间，暂停和隐藏后保留当前位置。
struct MediaAmbientMotion {
    static let cycleDuration: TimeInterval = 20
    static let frameInterval: TimeInterval = 1.0 / 15.0

    private var accumulatedTime: TimeInterval = 0
    private var runningSince: Date?

    static func shouldAnimate(style: MediaAmbientStyle, hasPalette: Bool, isPlaying: Bool,
                              isVisible: Bool, reduceMotion: Bool) -> Bool {
        style == .dynamicBlur && hasPalette && isPlaying && isVisible && !reduceMotion
    }

    mutating func setRunning(_ isRunning: Bool, at date: Date) {
        if isRunning {
            if runningSince == nil { runningSince = date }
        } else if runningSince != nil {
            accumulatedTime = elapsedTime(at: date)
            runningSince = nil
        }
    }

    func elapsedTime(at date: Date) -> TimeInterval {
        guard let runningSince else { return accumulatedTime }
        return accumulatedTime + max(0, date.timeIntervalSince(runningSince))
    }

    /// 位移为画布宽高的比例；仅改变位置，透明度与模糊范围始终恒定。
    static func displacement(at time: TimeInterval) -> CGSize {
        guard time.isFinite else { return .zero }
        let phase = time.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration * 2 * .pi
        return CGSize(width: sin(phase) * 0.10, height: (cos(phase) - 1) * 0.06)
    }
}

/// 附着在媒体卡片的 background 中，直接复用已提取的封面两色。
struct MediaAmbientBackground: View {
    let style: MediaAmbientStyle
    let palette: AlbumArtworkPalette?
    let isPlaying: Bool
    let isVisible: Bool
    let reduceMotion: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var motion = MediaAmbientMotion()

    private var shouldAnimate: Bool {
        MediaAmbientMotion.shouldAnimate(style: style, hasPalette: palette != nil,
            isPlaying: isPlaying, isVisible: isVisible, reduceMotion: reduceMotion)
    }

    var body: some View {
        Color.clear
            .overlay {
                if style != .off, let palette {
                    if shouldAnimate {
                        // 不保留暂停的 TimelineView；静止时整个调度节点会被移除。
                        TimelineView(.animation(minimumInterval: MediaAmbientMotion.frameInterval)) { timeline in
                            colors(palette, time: motion.elapsedTime(at: timeline.date))
                        }
                    } else {
                        colors(palette, time: motion.elapsedTime(at: .now))
                    }
                }
            }
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { motion.setRunning(shouldAnimate, at: .now) }
            .onChange(of: shouldAnimate) { _, isRunning in motion.setRunning(isRunning, at: .now) }
            .onDisappear { motion.setRunning(false, at: .now) }
    }

    private func colors(_ palette: AlbumArtworkPalette, time: TimeInterval) -> some View {
        let isDark = colorScheme == .dark
        let isDynamic = style == .dynamicBlur
        let displacement = isDynamic ? MediaAmbientMotion.displacement(at: time) : .zero
        let primary = Color(red: palette.primary.red, green: palette.primary.green, blue: palette.primary.blue)
        let secondary = Color(red: palette.secondary.red, green: palette.secondary.green, blue: palette.secondary.blue)
        let intensity = isDark ? (isDynamic ? 0.20 : 0.13) : (isDynamic ? 0.075 : 0.045)

        return Canvas(rendersAsynchronously: true) { context, size in
            let bounds = Path(CGRect(origin: .zero, size: size))
            let radius = max(size.width, size.height) * 0.82
            context.fill(bounds, with: .linearGradient(
                Gradient(colors: [primary.opacity(isDark ? 0.035 : 0.018), secondary.opacity(isDark ? 0.025 : 0.012)]),
                startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
            context.fill(bounds, with: .radialGradient(
                Gradient(colors: [primary.opacity(intensity), primary.opacity(0)]),
                center: CGPoint(x: size.width * (0.18 + displacement.width),
                                y: size.height * (0.35 + displacement.height)),
                startRadius: 0, endRadius: radius))
            context.fill(bounds, with: .radialGradient(
                Gradient(colors: [secondary.opacity(intensity * 0.8), secondary.opacity(0)]),
                center: CGPoint(x: size.width * (0.84 - displacement.width),
                                y: size.height * (0.78 - displacement.height)),
                startRadius: 0, endRadius: radius * 0.86))
        }
    }
}
