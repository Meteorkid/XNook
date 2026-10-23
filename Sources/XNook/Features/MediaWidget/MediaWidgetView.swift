import SwiftUI

/// 媒体播放 Widget 视图
struct MediaWidgetView: View {
    var mediaManager: MediaManager
    var isDetail = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var reduceMotion = SettingsDefaults.bool(for: "reduceMotion")

    private var shouldReduceMotion: Bool { reduceMotion || systemReduceMotion }

    /// 由封面提取的强调色；取不到时退回默认强调色。
    private var accent: Color {
        (mediaManager.artworkPalette?.primary.nsColor).map(Color.init(nsColor:))
            ?? Color.accentColor
    }

    var body: some View {
        VStack(spacing: 8) {
            if isDetail { Spacer() }

            // 专辑封面
            Button(action: { mediaManager.openCurrentPlayer() }) {
                artworkView
            }
            .buttonStyle(.plain)
            .disabled(mediaManager.currentSource == nil)
            .help(mediaManager.currentSource?.rawValue ?? L10n.noTrack)

            // 歌曲信息
            VStack(spacing: 2) {
                Text(mediaManager.currentTitle.isEmpty ? L10n.noTrack : mediaManager.currentTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(.primary)

                Text(mediaManager.currentArtist.isEmpty ? L10n.unknownArtist : mediaManager.currentArtist)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .foregroundColor(.secondary)
            }

            // 控制按钮 — 悬停时按封面强调色提亮
            HStack(spacing: 16) {
                controlButton(icon: "backward.fill", size: 11) { mediaManager.previousTrack() }

                Button(action: {
                    mediaManager.isPlaying ? mediaManager.pause() : mediaManager.play()
                }) {
                    Image(systemName: mediaManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .foregroundColor(accent)

                controlButton(icon: "forward.fill", size: 11) { mediaManager.nextTrack() }
            }
            .foregroundColor(.primary)

            if isDetail { Spacer() }
        }
    }

    private func controlButton(
        icon: String,
        size: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            MotionIcon(systemName: icon, fontSize: size, reduceMotion: shouldReduceMotion)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var artworkView: some View {
        if let artwork = mediaManager.currentArtwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
                .cornerRadius(8)
                // 阴影取封面主色，让封面与面板产生关联而不是浮在表面
                .shadow(color: accent.opacity(0.35), radius: 6, y: 2)
                .id(mediaManager.artworkVersion)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [.pink.opacity(0.3), .purple.opacity(0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 20))
                        .foregroundColor(.pink)
                )
        }
    }
}

#if !XNOOK_DISABLE_PREVIEWS
#Preview {
    MediaWidgetView(mediaManager: MediaManager())
        .background(Color.black)
}
#endif
