import SwiftUI

/// 实时字幕的权限与运行状态行。
///
/// 字幕「没有出现」有两个完全不同的原因：捕获侧没拿到屏幕录制权限，或识别侧没拿到语音识别权限。
/// 两者都是 TCC 授权，用户无法在应用内自行修复，因此这里必须直接给出结论与跳转入口，
/// 而不是让用户对着一个没反应的开关猜。
struct LiveCaptionStatusRow: View {

    @State private var manager = CaptionManager.shared
    @State private var summary: String = ""
    @State private var refreshToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(manager.isRunning ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 6, height: 6)
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if manager.isRunning {
                    Text("\(L10n.captionChainLength) \(manager.chainLength)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text("\(L10n.captionCertificates) \(manager.establishedCertificates)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    if let level = manager.level {
                        Text("\(L10n.captionLevel) L\(level.rawValue)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                Button(L10n.refreshStatus) { refreshToken += 1 }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }

            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .failed(let reason) = manager.state {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button(L10n.captionOpenScreenRecording) {
                    SystemPrivacySettings.openScreenRecording()
                }
                Button(L10n.captionOpenSpeechRecognition) {
                    SystemPrivacySettings.openSpeechRecognition()
                }
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
        .padding(.vertical, 8)
        .task(id: refreshToken) {
            summary = await CaptionManager.permissionSummary()
        }
    }

    private var statusText: String {
        switch manager.state {
        case .idle: L10n.captionIdle
        case .starting: L10n.captionStarting
        case .running: L10n.captionRunning
        case .failed: L10n.captionIdle
        }
    }
}
