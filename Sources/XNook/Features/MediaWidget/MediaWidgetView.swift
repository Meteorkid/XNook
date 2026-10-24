import SwiftUI

/// 媒体播放 Widget 视图
struct MediaWidgetView: View {
    var mediaManager: MediaManager
    var isDetail = false
    var onShowAll: (() -> Void)? = nil
    var availableHeight: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var reduceMotion = SettingsDefaults.bool(for: "reduceMotion")

    private var shouldReduceMotion: Bool { reduceMotion || systemReduceMotion }

    /// 由封面提取的强调色；取不到时退回默认强调色。
    private var accent: Color {
        (mediaManager.artworkPalette?.primary.nsColor).map(Color.init(nsColor:))
            ?? Color.accentColor
    }

    var body: some View {
        Group {
            if isDetail {
                VStack(spacing: 8) {
                    Spacer()
                    artworkButton
                    trackInformation
                    playbackControls
                    Spacer()
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if availableHeight != nil {
                        HStack {
                            Label(L10n.widgetMedia, systemImage: "music.note")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer(minLength: 4)
                            if let onShowAll {
                                Button(action: onShowAll) { Image(systemName: "chevron.right").frame(width: 22, height: 22) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(L10n.localized(zh: "媒体详情", en: "Media details"))
                            }
                        }
                    }
                    HStack(spacing: 12) {
                        artworkButton
                        VStack(alignment: .leading, spacing: 12) {
                            trackInformation
                            playbackControls
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 64)
                }
            }
        }
    }

    private var artworkButton: some View {
        Button(action: { mediaManager.openCurrentPlayer() }) { artworkView }
            .buttonStyle(.plain)
            .disabled(mediaManager.currentSource == nil)
            .help(mediaManager.currentSource?.rawValue ?? L10n.noTrack)
            .expandedPanelDebugFrame(id: "gridWidgetMediaArtwork")
    }

    private var trackInformation: some View {
        VStack(alignment: isDetail ? .center : .leading, spacing: 3) {
            Text(mediaManager.currentTitle.isEmpty ? L10n.noTrack : mediaManager.currentTitle)
                .font(.system(size: isDetail ? 11 : 12, weight: .semibold))
                .lineLimit(1)
                .foregroundColor(.primary)
            Text(mediaManager.currentArtist.isEmpty ? L10n.unknownArtist : mediaManager.currentArtist)
                .font(.system(size: isDetail ? 9 : 10, weight: .medium))
                .lineLimit(1)
                .foregroundColor(.secondary)
        }
        .expandedPanelDebugFrame(id: "gridWidgetMediaTrack")
    }

    private var playbackControls: some View {
        HStack(spacing: isDetail ? 16 : 12) {
            controlButton(icon: "backward.fill", size: 11) { mediaManager.previousTrack() }
                .accessibilityLabel(L10n.gridMediaPrevious)
            Button(action: {
                mediaManager.isPlaying ? mediaManager.pause() : mediaManager.play()
            }) {
                Image(systemName: mediaManager.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(accent)
            .accessibilityLabel(mediaManager.isPlaying ? L10n.gridMediaPause : L10n.gridMediaPlay)
            controlButton(icon: "forward.fill", size: 11) { mediaManager.nextTrack() }
                .accessibilityLabel(L10n.gridMediaNext)
        }
        .foregroundColor(.primary)
        .expandedPanelDebugFrame(id: "gridWidgetMediaControls")
    }

    private func controlButton(
        icon: String,
        size: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            MotionIcon(systemName: icon, fontSize: size, reduceMotion: shouldReduceMotion)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
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
