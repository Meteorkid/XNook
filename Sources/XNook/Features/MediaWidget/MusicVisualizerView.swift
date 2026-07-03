import SwiftUI

/// 音频波形可视化动画 — 播放时跳动，暂停时静止
struct MusicVisualizerView: View {
    let isPlaying: Bool
    var barCount: Int = 4
    var barColor: Color = .white

    var body: some View {
        // TimelineView 驱动动画，无 Timer 竞态问题
        TimelineView(.animation(minimumInterval: 0.08)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<barCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(barColor.opacity(0.8))
                        .frame(width: 2.5, height: barHeight(for: i, time: now))
                }
            }
        }
        .frame(height: 14)
    }

    private func barHeight(for index: Int, time: TimeInterval) -> CGFloat {
        let base: CGFloat = 3
        let max额外: CGFloat = 11
        guard isPlaying else { return base }
        // 每个 bar 不同频率，从时间直接算相位，无需存储状态
        let freq = 2.0 + Double(index) * 0.7
        let phase = Double(index) * 1.2 + freq * time
        return base + max额外 * abs(CGFloat(sin(phase)))
    }
}
