import SwiftUI

/// 音频波形可视化动画 — 播放时跳动，暂停时静止
struct MusicVisualizerView: View {
    let isPlaying: Bool
    var barCount: Int = 4
    var barColor: Color = .white

    @State private var phases: [Double] = Array(repeating: 0, count: 4)

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor.opacity(0.8))
                    .frame(width: 2.5, height: barHeight(for: i))
            }
        }
        .frame(height: 14)
        .onAppear {
            if isPlaying { startAnimation() }
        }
        .onChange(of: isPlaying) { _, playing in
            if playing { startAnimation() }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let base: CGFloat = 3
        let max额外: CGFloat = 11
        if !isPlaying { return base }
        return base + max额外 * abs(CGFloat(sin(phases[index])))
    }

    private func startAnimation() {
        // 为每个 bar 设置不同的频率和相位，制造不规则跳动
        for i in 0..<barCount {
            let phase = Double(i) * 1.2
            withAnimation(.linear(duration: 0.05)) {
                phases[i] = phase
            }
        }

        // 用 Timer 驱动持续动画
        Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { timer in
            guard isPlaying else {
                timer.invalidate()
                return
            }
            for i in 0..<barCount {
                let freq = 2.0 + Double(i) * 0.7
                phases[i] += freq * 0.08
            }
        }
    }
}

// MARK: - Preview

#Preview {
    MusicVisualizerView(isPlaying: true)
        .padding()
        .background(Color.black)
}
