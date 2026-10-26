import SwiftUI

/// 媒体播放 Widget 视图
struct MediaWidgetView: View {
    var mediaManager: MediaManager
    var isDetail = false
    var onShowAll: (() -> Void)?
    var availableHeight: CGFloat? = nil
    @State private var showsLyricsDetails = false
    @State private var seekInteraction = MediaSeekInteraction()
    @Environment(\.mediaSeekInteractionEnabled) private var seekInteractionEnabled
    @Environment(\.mediaAmbientAnimationEnabled) private var ambientAnimationEnabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var reduceMotion = SettingsDefaults.bool(for: "reduceMotion")
    @AppStorage("showLyrics") private var showLyrics = SettingsDefaults.bool(for: "showLyrics")
    @AppStorage("mediaAmbientStyle") private var ambientStyle = SettingsDefaults.string(for: "mediaAmbientStyle")

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
    private var displayedElapsedTime: TimeInterval {
        if let preview = seekInteraction.previewTime { return preview }
        if case .pending(let target) = mediaManager.seekStatus { return target }
        return elapsedTime
    }

    var body: some View {
        VStack(spacing: 8) {
            if !isDetail { overviewHeader }
            content
                .expandedPanelDebugFrame(id: "mediaWidgetContent")
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(.primary)
        .background {
            GeometryReader { geometry in
                let padding = ExpandedPanelLayout.cardPadding
                MediaAmbientBackground(style: MediaAmbientStyle.resolved(ambientStyle),
                    palette: hasTrack ? mediaManager.artworkPalette : nil,
                    isPlaying: mediaManager.isPlaying, isVisible: ambientAnimationEnabled,
                    reduceMotion: shouldReduceMotion)
                    .frame(width: geometry.size.width + padding * 2, height: geometry.size.height + padding * 2)
                    .clipShape(RoundedRectangle(cornerRadius: IslandTokens.Radius.sheet))
                    .offset(x: -padding, y: -padding)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .expandedPanelDebugFrame(id: "mediaWidgetRoot")
        .onChange(of: mediaManager.seekContext) { _, context in
            if seekInteraction.context != context { seekInteraction.invalidate() }
        }
        .onChange(of: seekInteractionEnabled) { _, enabled in
            if !enabled { cancelSeekInteraction(preservingGesture: true) }
        }
        .onDisappear { if isDetail { cancelSeekInteraction() } }
    }

    private var overviewHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
            Text(L10n.widgetMedia)
                .fontWeight(.semibold)
            Spacer(minLength: 4)
            if let onShowAll {
                // 标题行保持24pt；固定命中轮廓外扩2pt，覆盖28pt高度。
                ScaleOnlyButton(reduceMotion: shouldReduceMotion, hitPadding: 2, action: onShowAll) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 28, height: 24)
                }
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
                            if isDetail {
                                lyricsDetailsButton
                            } else {
                                playbackControls
                            }
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
        .expandedPanelDebugFrame(id: "gridWidgetMediaArtwork")
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
        .expandedPanelDebugFrame(id: "gridWidgetMediaTrack")
    }

    private var playbackControls: some View {
        MediaPlaybackControlsLayout {
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
        .expandedPanelDebugFrame(id: "gridWidgetMediaControls")
    }

    private func controlButton(
        icon: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        ScaleOnlyButton(reduceMotion: shouldReduceMotion, action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 37, height: 37)
        }
        .help(label)
        .accessibilityLabel(label)
    }

    private var playbackProgress: some View {
        VStack(spacing: 5) {
            if mediaManager.seekContext != nil || mediaManager.seekStatus.isPending {
                Slider(value: Binding(get: { displayedElapsedTime }, set: { value in
                    guard seekInteractionEnabled, !mediaManager.seekStatus.isPending else { return }
                    if !seekInteraction.isEditing {
                        seekInteraction.begin(context: mediaManager.seekContext, elapsedTime: elapsedTime)
                    }
                    seekInteraction.update(to: value, currentContext: mediaManager.seekContext)
                }), in: 0...duration, onEditingChanged: { editing in
                    guard seekInteractionEnabled else {
                        cancelSeekInteraction(preservingGesture: editing)
                        return
                    }
                    if editing {
                        if !seekInteraction.isEditing {
                            seekInteraction.begin(context: mediaManager.seekContext, elapsedTime: elapsedTime)
                        }
                    } else if let request = seekInteraction.finish(currentContext: mediaManager.seekContext) {
                        mediaManager.seek(to: request.seconds, context: request.context)
                    }
                })
                .tint(Color.primary.opacity(0.8))
                .disabled(!seekInteractionEnabled || mediaManager.seekStatus.isPending)
                .accessibilityLabel(L10n.mediaPlaybackProgress)
                .accessibilityValue("\(mediaManager.formatTime(displayedElapsedTime)) / \(mediaManager.formatTime(duration))")
                .accessibilityIdentifier("mediaWidgetSeekSlider")
                .expandedPanelDebugFrame(id: "mediaWidgetSeekSlider")
                .onExitCommand { cancelSeekInteraction(preservingGesture: true) }
            } else {
                ProgressView(value: elapsedTime, total: duration)
                    .progressViewStyle(.linear)
                    .tint(Color.primary.opacity(0.8))
                    .help(L10n.mediaSeekUnavailable)
                    .accessibilityLabel(L10n.mediaPlaybackProgress)
                    .accessibilityValue("\(mediaManager.formatTime(elapsedTime)) / \(mediaManager.formatTime(duration))")
            }
            HStack {
                Text(mediaManager.formatTime(displayedElapsedTime))
                Spacer(minLength: 8)
                Text(mediaManager.formatTime(duration))
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Color.primary.opacity(0.6))
            if mediaManager.seekStatus.isPending {
                Text(L10n.mediaSeekPending).font(.caption2).foregroundStyle(.secondary)
            } else if case .failed(let failure) = mediaManager.seekStatus {
                Text(L10n.mediaSeekFailure(failure))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mediaWidgetSeekFailure")
            }
        }
        .expandedPanelDebugFrame(id: "mediaWidgetProgress")
    }

    private func cancelSeekInteraction(preservingGesture: Bool = false) {
        if preservingGesture { seekInteraction.invalidate() }
        else { seekInteraction.cancel() }
        if isDetail { mediaManager.cancelSeek() }
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
                Text(L10n.lyricsStatus(mediaManager.lyricsManager.status))
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

    private var lyricsDetailsButton: some View {
        Button { showsLyricsDetails = true } label: {
            Label(L10n.lyricsDetails, systemImage: "text.quote")
                .font(.system(size: 11))
                .frame(minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(L10n.lyricsDetails)
        .accessibilityLabel(L10n.lyricsDetails)
        .accessibilityIdentifier("mediaWidgetLyricsDetails")
        .expandedPanelDebugFrame(id: "mediaWidgetLyricsDetails")
        .popover(isPresented: $showsLyricsDetails) {
            LyricsDetailsView(mediaManager: mediaManager, onClose: { showsLyricsDetails = false })
        }
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

private struct MediaSeekInteractionEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

private struct MediaAmbientAnimationEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 截图宿主和不可见卡片保持静态，只有实际展开的媒体才刷新氛围动画。
    var mediaAmbientAnimationEnabled: Bool {
        get { self[MediaAmbientAnimationEnabledKey.self] }
        set { self[MediaAmbientAnimationEnabledKey.self] = newValue }
    }

    var mediaSeekInteractionEnabled: Bool {
        get { self[MediaSeekInteractionEnabledKey.self] }
        set { self[MediaSeekInteractionEnabledKey.self] = newValue }
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

/// 极窄卡片将控制垂直排列，保持37pt点击面积且不撑出卡片。
private struct MediaPlaybackControlsLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let horizontal = (proposal.width ?? 111) >= 111
        return CGSize(width: horizontal ? 111 : 37, height: horizontal ? 37 : 111)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let horizontal = bounds.width >= 111
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: bounds.minX + (horizontal ? CGFloat(index) * 37 : 0),
                y: bounds.minY + (horizontal ? 0 : CGFloat(index) * 37)),
                proposal: ProposedViewSize(width: 37, height: 37))
        }
    }
}

#if !XNOOK_DISABLE_PREVIEWS
#Preview {
    MediaWidgetView(mediaManager: MediaManager())
        .background(Color.black)
}
#endif
