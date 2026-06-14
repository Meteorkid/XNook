import SwiftUI

/// 媒体播放 Widget 视图
struct MediaWidgetView: View {
    @ObservedObject var mediaManager: MediaManager

    var body: some View {
        VStack(spacing: 12) {
            // 专辑封面
            if let artwork = mediaManager.currentArtwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                    .cornerRadius(8)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 80, height: 80)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary)
                    )
            }

            // 歌曲信息
            VStack(spacing: 4) {
                Text(mediaManager.currentTitle.isEmpty ? "No Track" : mediaManager.currentTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(.primary)

                Text(mediaManager.currentArtist.isEmpty ? "Unknown Artist" : mediaManager.currentArtist)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .foregroundColor(.secondary)
            }

            // 控制按钮
            HStack(spacing: 20) {
                Button(action: {
                    mediaManager.previousTrack()
                }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)

                Button(action: {
                    if mediaManager.isPlaying {
                        mediaManager.pause()
                    } else {
                        mediaManager.play()
                    }
                }) {
                    Image(systemName: mediaManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)

                Button(action: {
                    mediaManager.nextTrack()
                }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
            }
            .foregroundColor(.primary)

            // 音量滑块
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Slider(value: $mediaManager.volume, in: 0...1)
                    .controlSize(.small)

                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(width: 200)
    }
}

// MARK: - Preview

#Preview {
    MediaWidgetView(mediaManager: MediaManager())
        .background(Color.black)
}
