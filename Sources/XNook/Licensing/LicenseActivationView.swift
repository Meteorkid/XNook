import SwiftUI
import XNookLicenseCore

/// 授权面板内容。被两个地方复用：
/// 1. 设置窗口中的「授权」页
/// 2. 试用到期时的独立激活窗口
///
/// 抽成独立视图而非各写一份，避免两处状态展示不一致。
struct LicenseActivationView: View {

    /// 紧凑模式：用于独立的到期激活窗口，边距更小、字号更醒目。
    var isCompact: Bool = false

    @State private var license = LicenseManager.shared
    @State private var input: String = ""
    @State private var message: String?
    @State private var isError = false
    @State private var isWorking = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 16 : 20) {
            statusSection
            inputSection
            if let message {
                messageBanner(message)
            }
            actionsSection
        }
        .onAppear {
            license.refresh()
            inputFocused = true
        }
    }

    // MARK: - 状态区

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.licenseStatus)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 10) {
                statusIndicator
                VStack(alignment: .leading, spacing: 3) {
                    Text(license.statusSummary)
                        .font(.system(size: isCompact ? 14 : 13, weight: .medium))
                    if case .trial(let days) = license.state {
                        Text(L10n.licenseTrialHint)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        // 剩余天数进度条：让"还剩多少"可感知，而不只是一个数字
                        trialProgressBar(remaining: days)
                    }
                    if case .expired = license.state {
                        Text(L10n.licenseExpiredHint)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.quaternary.opacity(0.5), lineWidth: 0.5)
            )
        }
    }

    /// 状态指示点：已激活绿、试用黄、到期红、未配置灰
    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .padding(.top, 5)
    }

    private var statusColor: Color {
        switch license.state {
        case .licensed:     return .green
        case .trial:        return .orange
        case .expired:      return .red
        case .unconfigured: return .gray
        }
    }

    /// 试用剩余进度条
    private func trialProgressBar(remaining: Int) -> some View {
        let fraction = max(0, min(1, Double(remaining) / Double(TrialAnchor.trialDays)))
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(fraction > 0.3 ? Color.orange : Color.red)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 4)
        .padding(.top, 2)
    }

    // MARK: - 输入区

    @ViewBuilder
    private var inputSection: some View {
        // 已激活时不再展示输入框，避免用户误以为需要重复激活
        if !license.state.isLicensed {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.licenseEnterCode)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)

                TextEditor(text: $input)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: isCompact ? 76 : 64)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.quaternary.opacity(0.6), lineWidth: 0.5)
                    )
                    .focused($inputFocused)
                    .disabled(isWorking)

                Text(L10n.licensePasteHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 消息横幅

    private func messageBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(isError ? .red : .green)
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((isError ? Color.red : Color.green).opacity(0.08))
        )
    }

    // MARK: - 操作区

    @ViewBuilder
    private var actionsSection: some View {
        HStack(spacing: 10) {
            if !license.state.isLicensed {
                Button {
                    Task { await performActivation() }
                } label: {
                    HStack(spacing: 6) {
                        if isWorking {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                        }
                        Text(isWorking ? L10n.licenseActivating : L10n.licenseActivate)
                    }
                    .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || trimmedInput.isEmpty)

                Button(L10n.licensePasteFromClipboard) {
                    if let clipboard = NSPasteboard.general.string(forType: .string) {
                        input = clipboard
                        message = nil
                    }
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            // 已激活用户提供解除入口——用于换机或排障
            if license.state.isLicensed {
                Button(L10n.licenseDeactivate) {
                    license.deactivate()
                    message = L10n.licenseDeactivated
                    isError = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var trimmedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 激活动作

    private func performActivation() async {
        isWorking = true
        message = nil

        let outcome = await license.activate(input: trimmedInput)
        isWorking = false

        switch outcome {
        case .success(let serial, let flags):
            isError = false
            let suffix = flags.contains(.earlySupporter)
                ? LicenseError.text("（早期支持者）", " (Early Supporter)")
                : ""
            message = LicenseError.text(
                "激活成功\(suffix)。感谢支持，编号 \(String(format: "XN-%06u", serial))。",
                "Activated\(suffix). Thank you for your support — ID \(String(format: "XN-%06u", serial))."
            )
            input = ""
            // 通知外部（如到期锁屏窗口）可以关闭
            NotificationCenter.default.post(name: .xnookLicenseActivated, object: nil)

        case .failure(let reason):
            isError = true
            message = reason
        }
    }
}
