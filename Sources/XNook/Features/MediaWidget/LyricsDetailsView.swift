import SwiftUI

/// 歌词状态与全局校正留在详情，不增加经典面板高度。
struct LyricsDetailsView: View {
    var mediaManager: MediaManager
    let onClose: () -> Void

    private var lyrics: LyricsManager { mediaManager.lyricsManager }
    private var offset: Binding<Double> {
        Binding(get: { lyrics.lyricsOffset }, set: { lyrics.lyricsOffset = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.lyricsDetails).font(.headline)
                Spacer()
                Button(L10n.lyricsDetailsClose, action: onClose).controlSize(.small)
            }
            Text(mediaManager.currentTitle.isEmpty ? L10n.noTrack : mediaManager.currentTitle)
                .font(.subheadline).lineLimit(2)
            HStack(spacing: 6) {
                if lyrics.isFetching { ProgressView().controlSize(.small) }
                Text(L10n.lyricsStatus(lyrics.status))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !mediaManager.currentLyricLine.isEmpty || !lyrics.plainLyricPreview.isEmpty {
                Text(mediaManager.currentLyricLine.isEmpty ? lyrics.plainLyricPreview : mediaManager.currentLyricLine)
                    .font(.callout).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !mediaManager.currentTitle.isEmpty && lyrics.status != .disabled {
                // 只在打开详情和冷却到期这两个时点刷新，暂停播放也能恢复重试按钮。
                TimelineView(.explicit(retryRefreshDates)) { _ in
                    HStack {
                        Button(L10n.lyricsRetry) { lyrics.retryCurrentTrack() }
                            .disabled(!lyrics.canRetryCurrentTrack)
                        if !lyrics.canRetryCurrentTrack {
                            Text(L10n.lyricsRetryCoolingDown).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .controlSize(.small)
                }
                Text(L10n.lyricsRetryBypassesCache).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = lyrics.refreshNotice {
                Text(L10n.lyricsRefreshNotice(notice)).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text(L10n.lyricsOffset).font(.subheadline)
                Spacer()
                Text(String(format: "%+.1f s", lyrics.lyricsOffset))
                    .font(.system(.caption, design: .monospaced))
            }
            Slider(value: offset, in: -5...5, step: 0.1)
                .accessibilityLabel(L10n.lyricsOffset)
                .accessibilityValue(L10n.lyricsOffsetValue(lyrics.lyricsOffset))
            HStack {
                Button(L10n.lyricsEarlier) { lyrics.lyricsOffset -= 0.1 }
                    .disabled(lyrics.lyricsOffset <= -5)
                Button(L10n.lyricsLater) { lyrics.lyricsOffset += 0.1 }
                    .disabled(lyrics.lyricsOffset >= 5)
                Spacer()
                Button(L10n.lyricsResetOffset) { lyrics.lyricsOffset = 0 }
                    .disabled(lyrics.lyricsOffset == 0)
            }
            .controlSize(.small)
            Text(L10n.lyricsOffsetHelp)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 340)
    }

    private var retryRefreshDates: [Date] {
        let now = Date()
        guard let deadline = lyrics.retryAvailableAt, deadline > now else { return [now] }
        return [now, deadline.addingTimeInterval(0.05)]
    }
}
