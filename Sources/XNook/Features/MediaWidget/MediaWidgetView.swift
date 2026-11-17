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
            .help(mediaManager.isWaitingForPreferredSource
                  ? L10n.waitingForSource(mediaManager.currentSource?.displayName ?? "")
                  : mediaManager.currentSource?.displayName ?? L10n.noTrack)

            // 歌曲信息
            VStack(spacing: 2) {
                Text(mediaManager.isWaitingForPreferredSource
                     ? L10n.waitingForSource(mediaManager.currentSource?.displayName ?? "")
                     : (mediaManager.currentTitle.isEmpty ? L10n.noTrack : mediaManager.currentTitle))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(.primary)

                if !mediaManager.isWaitingForPreferredSource {
                    Text(mediaManager.currentArtist.isEmpty ? L10n.unknownArtist : mediaManager.currentArtist)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                        .foregroundColor(.secondary)
                }

                // 展开面板里标出来源，便于确认当前看到的是哪个播放器
                if isDetail, let sourceName = mediaManager.currentSource?.displayName {
                    Text(sourceName)
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .foregroundColor(.secondary.opacity(0.75))
                }
            }

            // 控制按钮 — 等待锁定来源时禁用，避免控制到别的播放器
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
            .disabled(mediaManager.isWaitingForPreferredSource)
            .opacity(mediaManager.isWaitingForPreferredSource ? 0.4 : 1)

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
