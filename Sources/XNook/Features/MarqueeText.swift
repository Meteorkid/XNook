import SwiftUI

/// 水平滚动文字组件 — 文字超出可用宽度时自动滚动
struct MarqueeText: View {
    let text: String
    let font: Font
    let availableWidth: CGFloat
    var speed: CGFloat = 25

    @State private var textWidth: CGFloat = 0
    @State private var startTime: Date = .now

    private var needsScroll: Bool { textWidth > availableWidth + 4 }

    var body: some View {
        Group {
            if needsScroll {
                TimelineView(.animation) { context in
                    label
                        .offset(x: calculateOffset(at: context.date))
                }
            } else {
                // 文字放得下时不要套 TimelineView：它跟随屏幕刷新率逐帧重建，
                // 而此时偏移恒为 0 —— 在 ProMotion 上等于常态 120fps 重绘一行静止文本。
                label
            }
        }
        .frame(width: availableWidth, height: 14)
        .clipped()
        .background(
            label
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: TextWidthKey.self, value: proxy.size.width)
                    }
                )
                .hidden()
        )
        .onPreferenceChange(TextWidthKey.self) { width in
            textWidth = width
        }
        .onChange(of: text) { _, _ in startTime = .now }
        .onAppear { startTime = .now }
    }

    private var label: some View {
        Text(text)
            .font(font)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func calculateOffset(at date: Date) -> CGFloat {
        guard needsScroll, speed > 0 else { return 0 }

        let totalDistance = textWidth - availableWidth + 16
        let scrollDuration = Double(totalDistance) / speed
        let pauseDuration: Double = 1.2
        let totalCycle = scrollDuration + pauseDuration

        let elapsed = date.timeIntervalSince(startTime)
        let adjustedElapsed = max(0, elapsed - 0.3)
        let cyclePosition = adjustedElapsed.truncatingRemainder(dividingBy: totalCycle)

        if cyclePosition < pauseDuration {
            return 0
        } else {
            let progress = (cyclePosition - pauseDuration) / scrollDuration
            return -totalDistance * min(progress, 1.0)
        }
    }
}

// MARK: - Text Width Preference Key

private struct TextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
