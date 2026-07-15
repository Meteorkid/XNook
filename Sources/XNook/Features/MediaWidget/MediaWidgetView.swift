import SwiftUI

/// 媒体播放 Widget 视图
struct MediaWidgetView: View {
    var mediaManager: MediaManager

    var body: some View {
        VStack(spacing: 8) {
            Spacer()

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

            // 控制按钮
            HStack(spacing: 16) {
                Button(action: { mediaManager.previousTrack() }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)

                Button(action: {
                    mediaManager.isPlaying ? mediaManager.pause() : mediaManager.play()
                }) {
                    Image(systemName: mediaManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)

                Button(action: { mediaManager.nextTrack() }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
            .foregroundColor(.primary)

            Spacer()
        }
    }

    @ViewBuilder
    private var artworkView: some View {
        if let artwork = mediaManager.currentArtwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
                .cornerRadius(8)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
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

#Preview {
    MediaWidgetView(mediaManager: MediaManager())
        .background(Color.black)
}
