import SwiftUI

/// 音频波形可视化动画 — 播放时跳动，暂停时静止
struct MusicVisualizerView: View {
    let isPlaying: Bool
    var barCount: Int = 4
    var barColor: Color = .white

    @State private var phases: [Double] = []
    @State private var animationTimer: Timer?
    @State private var timerID = UUID()

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
            phases = Array(repeating: 0, count: barCount)
            if isPlaying { startAnimation() }
        }
        .onChange(of: isPlaying) { _, playing in
            if playing {
                startAnimation()
            } else {
                stopAnimation()
            }
        }
        .onDisappear {
            stopAnimation()
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let base: CGFloat = 3
        let max额外: CGFloat = 11
        if !isPlaying { return base }
        return base + max额外 * abs(CGFloat(sin(phases[index])))
    }

    private func startAnimation() {
        stopAnimation()  // 先停止旧的 Timer
        timerID = UUID()  // 生成新的 ID，旧 Timer 自动失效

        // 为每个 bar 设置不同的频率和相位，制造不规则跳动
        for i in 0..<barCount {
            let phase = Double(i) * 1.2
            withAnimation(.linear(duration: 0.05)) {
                phases[i] = phase
            }
        }

        // 用 Timer 驱动持续动画，通过 timerID 验证是否当前有效
        let currentID = timerID
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [self] timer in
            guard timerID == currentID else {
                timer.invalidate()
                return
            }
            for i in 0..<self.barCount {
                let freq = 2.0 + Double(i) * 0.7
                self.phases[i] += freq * 0.08
            }
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }
}

// MARK: - Preview

#Preview {
    MusicVisualizerView(isPlaying: true)
        .padding()
        .background(Color.black)
}
