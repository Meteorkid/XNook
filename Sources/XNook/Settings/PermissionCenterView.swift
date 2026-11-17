import SwiftUI

/// 权限总览。把所有 TCC 授权收在一页：状态、为什么需要、怎么授权、授权后要不要重启。
///
/// 这里刻意不做「一键全部授权」——macOS 不允许应用代用户点系统设置。
/// 能做的是把路径缩到最短：一个按钮跳到正确分页，一个可拖拽的图标直接落进列表。
struct PermissionCenterView: View {

    var highlightedID: String?

    @State private var center = PermissionCenter.shared
    @State private var pendingReset: PermissionKind?
    @State private var resetMessage: String?

    private var rows: [PermissionKind] { PermissionKind.allCases }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            overview
            dragHelper
            listCard
            troubleshooting
        }
        .task { await center.refresh() }
        .confirmationDialog(
            L10n.localized(zh: "重置这项授权记录？", en: "Reset this permission record?"),
            isPresented: Binding(get: { pendingReset != nil }, set: { if !$0 { pendingReset = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.localized(zh: "重置", en: "Reset"), role: .destructive) {
                if let kind = pendingReset, center.resetAuthorization(for: kind) {
                    resetMessage = L10n.localized(
                        zh: "已重置。下次使用该功能时系统会重新询问。",
                        en: "Reset. macOS will ask again next time the feature is used."
                    )
                }
                pendingReset = nil
            }
            Button(L10n.localized(zh: "取消", en: "Cancel"), role: .cancel) { pendingReset = nil }
        } message: {
            Text(L10n.localized(
                zh: "会清除 X Nook 在这一项下的系统授权记录（tccutil reset），之后需要重新允许一次。用于修复「开关是打开的但应用仍报未授权」。",
                en: "Clears X Nook's record for this service (tccutil reset). You will need to allow it again. Use it when the switch is on but the app still reports no access."
            ))
        }
    }

    // MARK: - 总览

    private var overview: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: center.hasAnyIssue ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                .font(.system(size: 22))
                .foregroundStyle(center.hasAnyIssue ? Color.orange : Color.green)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(summaryTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(summaryDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Button(center.isRefreshing
                       ? L10n.localized(zh: "检测中…", en: "Checking…")
                       : L10n.settingsRefreshPermissions) {
                    Task { await center.refresh() }
                }
                .controlSize(.small)
                .disabled(center.isRefreshing)

                Button(L10n.openPrivacySecurityButton) { SystemPrivacySettings.openPrivacySecurity() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.quaternary.opacity(0.5), lineWidth: 0.5)
        )
    }

    private var summaryTitle: String {
        if center.lastRefresh == .distantPast {
            return L10n.localized(zh: "正在读取权限状态…", en: "Reading permission status…")
        }
        if !center.hasAnyIssue {
            return L10n.localized(zh: "全部权限已就绪", en: "All permissions are ready")
        }
        return L10n.localized(
            zh: "\(center.grantedCount) 项已授权 · \(center.issueCount) 项待处理",
            en: "\(center.grantedCount) granted · \(center.issueCount) needs attention"
        )
    }

    private var summaryDetail: String {
        if center.status(for: .screenRecording) == .needsRestart {
            return L10n.localized(
                zh: "屏幕录制已授权，但需要重启 X Nook 才会生效。",
                en: "Screen recording is granted, but X Nook must restart for it to take effect."
            )
        }
        return L10n.localized(
            zh: "macOS 不允许应用代替你点系统设置，所以这里给出直达入口：点「打开」跳转，或把应用图标直接拖进列表。",
            en: "macOS does not let apps toggle System Settings for you. Use Open, or drag the app icon straight into the list."
        )
    }

    // MARK: - 拖拽授权

    private var dragHelper: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.tertiary)
                    .frame(width: 68, height: 68)
                DraggableAppIcon(side: 52)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.localized(zh: "按住图标拖进系统设置", en: "Drag the icon into System Settings"))
                    .font(.system(size: 13, weight: .semibold))
                Text(L10n.localized(
                    zh: "把它拖到「屏幕与系统音频录制」列表里就等于添加 X Nook，松开后打开开关即可。两个窗口可以左右并排摆。",
                    en: "Drop it into the Screen & System Audio Recording list to add X Nook, then switch it on. You can place the two windows side by side."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Button(L10n.localized(zh: "打开设置", en: "Open Settings")) {
                    SystemPrivacySettings.open(.screenRecording)
                }
                .controlSize(.small)
                Text(L10n.localized(zh: "拖不动时改用按钮", en: "Use the button if dragging fails"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5)
        )
    }

    // MARK: - 清单

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element) { index, kind in
                if index > 0 { Divider().overlay(.quaternary.opacity(0.4)) }
                PermissionRowView(
                    kind: kind,
                    status: center.status(for: kind),
                    highlighted: highlightedID == "permission-" + kind.rawValue,
                    canRequest: center.canRequest(kind),
                    canReset: center.canReset(kind),
                    onOpen: { SystemPrivacySettings.open(kind.pane) },
                    onRequest: { Task { await center.requestAccess(for: kind) } },
                    onRestart: { PermissionCenter.relaunch() },
                    onReset: { pendingReset = kind }
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.quaternary.opacity(0.5), lineWidth: 0.5)
        )
    }

    // MARK: - 排障

    private var troubleshooting: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.localized(zh: "已授权却仍显示未授权？", en: "Granted but still shown as not granted?"))
                .font(.system(size: 12, weight: .semibold))
            Text(L10n.localized(
                zh: "系统设置里的开关是按「应用签名身份」记的。X Nook 每次重新构建，签名身份都会变，旧授权就挂在了旧身份上——开关看着是开的，实际对这个应用无效。",
                en: "macOS records each switch against the app's code signature. Every rebuild of X Nook changes that signature, so the old grant belongs to the old identity: the switch looks on, but it no longer applies."
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 3) {
                stepText("1", L10n.localized(zh: "在该分页把 X Nook 的开关关掉，再重新打开", en: "Turn the X Nook switch off, then on again in that pane"))
                stepText("2", L10n.localized(zh: "退出并重新打开 X Nook（屏幕录制必须重启才生效）", en: "Quit and reopen X Nook (screen recording needs a restart)"))
                stepText("3", L10n.localized(zh: "仍然不行，就用「重置记录」让系统重新询问一次", en: "Still failing? Reset the record so macOS asks again"))
            }

            if let resetMessage {
                Text(resetMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button(L10n.localized(zh: "重启 X Nook", en: "Restart X Nook")) { PermissionCenter.relaunch() }
                    .controlSize(.small)
                Button(L10n.localized(zh: "重置屏幕录制授权记录", en: "Reset screen recording record")) {
                    pendingReset = .screenRecording
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
    }

    private func stepText(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(index + ".")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 待续三
}

/// 单行权限：状态徽标 + 用途 + 直达入口。
private struct PermissionRowView: View {
    let kind: PermissionKind
    let status: PermissionStatus
    let highlighted: Bool
    let canRequest: Bool
    let canReset: Bool
    let onOpen: () -> Void
    let onRequest: () -> Void
    let onRestart: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.symbol)
                .font(.system(size: 13))
                .foregroundStyle(status == .allowed ? Color.green : Color.secondary)
                .frame(width: 18, height: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(kind.title).font(.system(size: 13, weight: .medium))
                    statusBadge
                    Spacer(minLength: 0)
                }

                Text(kind.purpose)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if status == .needsRestart {
                    HStack(spacing: 6) {
                        Text(L10n.localized(zh: "已授权，重启后生效", en: "Granted, takes effect after restart"))
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Button(L10n.localized(zh: "立即重启", en: "Restart now")) { onRestart() }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }

                actions
            }
        }
        .padding(.vertical, 9)
        .settingsSearchTarget(id: rowID, highlightedID: highlighted ? rowID : nil)
    }

    private var rowID: String { "permission-" + kind.rawValue }

    private var statusBadge: some View {
        Text(status.title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(badgeColor.opacity(0.12)))
    }

    private var badgeColor: Color {
        switch status {
        case .allowed: .green
        case .needsRestart, .denied, .notRequested, .writeOnly: .orange
        default: .secondary
        }
    }

    @ViewBuilder
    private var actions: some View {
        if status == .notInstalled {
            Text(L10n.localized(zh: "未安装，无需处理", en: "Not installed, nothing to do"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        } else if status == .notRunning {
            Text(L10n.localized(zh: "打开播放器后再刷新即可检测", en: "Open the player, then refresh"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 12) {
                if canRequest {
                    Button(L10n.localized(zh: "请求授权", en: "Request")) { onRequest() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .fontWeight(.medium)
                }
                Button(L10n.localized(zh: "打开系统设置", en: "Open Settings")) { onOpen() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                if canReset {
                    Button(L10n.localized(zh: "重置记录", en: "Reset record")) { onReset() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if kind.acceptsDrop {
                    Text(L10n.localized(zh: "可拖拽图标添加", en: "Drag the icon to add"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
