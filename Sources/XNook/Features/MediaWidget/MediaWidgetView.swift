import SwiftUI

/// 媒体播放 Widget 视图
struct MediaWidgetView: View {
    var mediaManager: MediaManager
    var isDetail = false
    var onShowAll: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var reduceMotion = SettingsDefaults.bool(for: "reduceMotion")
    @AppStorage("showLyrics") private var showLyrics = SettingsDefaults.bool(for: "showLyrics")

    private var shouldReduceMotion: Bool { reduceMotion || systemReduceMotion }
    private var title: String { mediaManager.currentTitle.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var artist: String { mediaManager.currentArtist.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var album: String { mediaManager.currentAlbum.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasTrack: Bool { !title.isEmpty || !artist.isEmpty || !album.isEmpty }
    private var duration: TimeInterval { mediaManager.duration.isFinite ? max(0, mediaManager.duration) : 0 }
    private var elapsedTime: TimeInterval {
        let elapsed = mediaManager.elapsedTime.isFinite ? max(0, mediaManager.elapsedTime) : 0
        return duration > 0 ? min(elapsed, duration) : elapsed
    }

    var body: some View {
        VStack(spacing: 8) {
            if !isDetail { overviewHeader }
            content
                .expandedPanelDebugFrame(id: "mediaWidgetContent")
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(.primary)
        .expandedPanelDebugFrame(id: "mediaWidgetRoot")
    }

    private var overviewHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
            Text(L10n.widgetMedia)
                .fontWeight(.semibold)
            Spacer(minLength: 4)
            if let onShowAll {
                Button(action: onShowAll) {
                    MotionIcon(systemName: "chevron.right", fontSize: 10, reduceMotion: shouldReduceMotion)
                        .frame(width: 28, height: 24)
                        // 标题行保持24pt；点击轮廓上下各扩2pt，覆盖28pt高度。
                        .contentShape(Rectangle().inset(by: -2))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L10n.mediaShowDetails)
                .accessibilityLabel(L10n.mediaShowDetails)
                .accessibilityIdentifier("mediaWidgetShowDetails")
                .expandedPanelDebugFrame(id: "mediaWidgetShowDetails")
            }
        }
        .font(.system(size: 13))
        .frame(height: 24)
        .expandedPanelDebugFrame(id: "mediaWidgetHeader")
    }

    private var content: some View {
        Group {
            if hasTrack {
                VStack(spacing: isDetail ? 16 : 0) {
                    MediaArtworkLayout {
                        artworkButton
                        VStack(alignment: .leading, spacing: 8) {
                            trackInfo
                            if !isDetail { playbackControls }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .expandedPanelDebugFrame(id: "mediaWidgetTrackGroup")
                    }
                    if isDetail {
                        if duration > 0 { playbackProgress }
                        if showLyrics { lyricsStatus }
                        playbackControls
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var artworkButton: some View {
        Group {
            if let source = mediaManager.currentSource {
                Button(action: { mediaManager.openCurrentPlayer() }) {
                    artworkView.contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .help(source.rawValue)
                .accessibilityLabel(L10n.mediaOpenPlayer)
            } else {
                // 无可跳转的来源时仍展示已有曲目封面，避免禁用按钮把图片一起淡化。
                artworkView
                    .accessibilityLabel(title.isEmpty ? L10n.noTrack : title)
            }
        }
        .expandedPanelDebugFrame(id: "mediaWidgetArtwork")
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.isEmpty ? L10n.noTrack : title)
                .font(.system(size: isDetail ? 15 : 13, weight: .semibold))
                .lineLimit(isDetail ? 2 : 1)
                .truncationMode(.tail)
                .help(title.isEmpty ? L10n.noTrack : title)
                .expandedPanelDebugFrame(id: "mediaWidgetTitle")

            if !album.isEmpty {
                Text(album)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.65))
                    .lineLimit(1)
                    .help(album)
                    .expandedPanelDebugFrame(id: "mediaWidgetAlbum")
            }

            Text(artist.isEmpty ? L10n.unknownArtist : artist)
                .font(.system(size: 11))
                .foregroundStyle(Color.primary.opacity(0.65))
                .lineLimit(1)
                .help(artist.isEmpty ? L10n.unknownArtist : artist)
                .expandedPanelDebugFrame(id: "mediaWidgetArtist")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .expandedPanelDebugFrame(id: "mediaWidgetInfo")
    }

    private var playbackControls: some View {
        HStack(spacing: 0) {
            controlButton(icon: "backward.fill", label: L10n.mediaPrevious) { mediaManager.previousTrack() }
                .expandedPanelDebugFrame(id: "mediaWidgetPrevious")

            Button(action: {
                mediaManager.isPlaying ? mediaManager.pause() : mediaManager.play()
            }) {
                Image(systemName: mediaManager.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 37, height: 37)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(mediaManager.isPlaying ? L10n.mediaPause : L10n.mediaPlay)
            .accessibilityLabel(mediaManager.isPlaying ? L10n.mediaPause : L10n.mediaPlay)
            .expandedPanelDebugFrame(id: "mediaWidgetPlayPause")

            controlButton(icon: "forward.fill", label: L10n.mediaNext) { mediaManager.nextTrack() }
                .expandedPanelDebugFrame(id: "mediaWidgetNext")
        }
        .foregroundStyle(.primary)
        .expandedPanelDebugFrame(id: "mediaWidgetControls")
    }

    private func controlButton(
        icon: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            MotionIcon(systemName: icon, fontSize: 16, reduceMotion: shouldReduceMotion)
                .frame(width: 37, height: 37)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var playbackProgress: some View {
        VStack(spacing: 5) {
            // 使用进度条表达只读时间轴，不呈现尚无播放器接口支持的拖动控件。
            ProgressView(value: elapsedTime, total: duration)
                .progressViewStyle(.linear)
                .tint(Color.primary.opacity(0.8))
                .accessibilityLabel(L10n.mediaPlaybackProgress)
                .accessibilityValue("\(mediaManager.formatTime(elapsedTime)) / \(mediaManager.formatTime(duration))")
            HStack {
                Text(mediaManager.formatTime(elapsedTime))
                Spacer(minLength: 8)
                Text(mediaManager.formatTime(duration))
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Color.primary.opacity(0.6))
        }
        .expandedPanelDebugFrame(id: "mediaWidgetProgress")
    }

    private var lyricsStatus: some View {
        let line = mediaManager.currentLyricLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let plainLine = mediaManager.plainLyricPreview
        return VStack(spacing: 4) {
            if !line.isEmpty {
                Text(line)
            } else if !plainLine.isEmpty {
                Text(plainLine)
                Text(L10n.mediaPlainLyrics)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.primary.opacity(0.45))
            } else {
                Text(mediaManager.lyricsManager.isFetching ? L10n.mediaLyricsLoading : L10n.mediaLyricsUnavailable)
                    .foregroundStyle(Color.primary.opacity(0.45))
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.primary.opacity(0.8))
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .frame(maxWidth: .infinity)
        .expandedPanelDebugFrame(id: "mediaWidgetLyrics")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text(L10n.mediaNothingPlaying)
                .font(.system(size: 12))
                .foregroundStyle(Color.primary.opacity(0.6))
                .multilineTextAlignment(.center)
            Button(action: { mediaManager.openCurrentPlayer() }) {
                Text(L10n.mediaOpenPlayer)
                    .font(.system(size: 12, weight: .medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 32)
                    .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(mediaManager.currentSource?.rawValue ?? ScriptingBridgeHelper.SupportedApp.music.rawValue)
            .expandedPanelDebugFrame(id: "mediaWidgetOpenPlayer")
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .expandedPanelDebugFrame(id: "mediaWidgetEmptyState")
    }

    @ViewBuilder
    private var artworkView: some View {
        if let artwork = mediaManager.currentArtwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 100, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .id(mediaManager.artworkVersion)
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.06))
                .frame(width: 100, height: 100)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.primary.opacity(0.45))
                )
        }
    }
}

/// 窄屏改为上下排列，封面和控制保持原尺寸；布局切换不重建按钮状态。
private struct MediaArtworkLayout: Layout {
    private let artworkSize: CGFloat = 100
    private let spacing: CGFloat = 12
    private let minimumInfoWidth: CGFloat = 111

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 290
        let horizontal = width >= artworkSize + spacing + minimumInfoWidth
        let infoWidth = horizontal ? width - artworkSize - spacing : width
        let infoHeight = subviews[1].sizeThatFits(ProposedViewSize(width: infoWidth, height: nil)).height
        return CGSize(width: width, height: horizontal ? max(artworkSize, infoHeight) : artworkSize + spacing + infoHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let horizontal = bounds.width >= artworkSize + spacing + minimumInfoWidth
        let infoWidth = horizontal ? bounds.width - artworkSize - spacing : bounds.width
        let infoProposal = ProposedViewSize(width: infoWidth, height: nil)
        let infoHeight = subviews[1].sizeThatFits(infoProposal).height
        subviews[0].place(
            at: CGPoint(x: horizontal ? bounds.minX : bounds.midX - artworkSize / 2,
                y: horizontal ? bounds.midY - artworkSize / 2 : bounds.minY),
            proposal: ProposedViewSize(width: artworkSize, height: artworkSize)
        )
        subviews[1].place(
            at: CGPoint(x: horizontal ? bounds.minX + artworkSize + spacing : bounds.minX,
                y: horizontal ? bounds.midY - infoHeight / 2 : bounds.minY + artworkSize + spacing),
            proposal: infoProposal
        )
    }
}

#if !XNOOK_DISABLE_PREVIEWS
#Preview {
    MediaWidgetView(mediaManager: MediaManager())
        .background(Color.black)
}
#endif
