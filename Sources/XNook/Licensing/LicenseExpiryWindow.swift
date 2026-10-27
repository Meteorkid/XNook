import AppKit
import SwiftUI

extension Notification.Name {
    /// 激活成功。用于让到期窗口自动关闭。
    static let xnookLicenseActivated = Notification.Name("xnookLicenseActivated")
    /// 请求打开设置窗口的授权页。
    static let xnookShowLicensePane = Notification.Name("xnookShowLicensePane")
    static let xnookLicenseLocked = Notification.Name("xnookLicenseLocked")
}

/// 试用到期时的独立激活窗口。
///
/// 为什么不是模态弹窗：模态弹窗会阻塞整个应用，用户在复制邀请码时
/// 无法切换窗口。这里用普通窗口，用户可以从邮件里复制后粘回来。
final class LicenseExpiryWindowController {

    static let shared = LicenseExpiryWindowController()

    private var window: NSWindow?
    private var activationObserver: NSObjectProtocol?

    private init() {}

    /// 显示激活窗口。重复调用只会把已有窗口前置。
    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = LicenseExpiryWindowView(onQuit: { NSApp.terminate(nil) })
        let hosting = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hosting)
        window.title = L10n.licenseExpiredWindowTitle
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        // 提高窗口层级，避免被其他应用遮挡
        window.level = .floating

        self.window = window

        // 激活成功后自动关闭窗口，无需用户手动关
        activationObserver = NotificationCenter.default.addObserver(
            forName: .xnookLicenseActivated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.close()
            }
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        window?.orderOut(nil)
        window = nil
    }
}

/// 到期窗口内容。
private struct LicenseExpiryWindowView: View {

    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.licenseExpiredWindowTitle)
                    .font(.system(size: 17, weight: .semibold))
                Text(L10n.licenseExpiredWindowSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LicenseActivationView(isCompact: true)

            Divider()

            HStack {
                Button(L10n.licensePurchase) {
                    NSWorkspace.shared.open(LicenseManager.purchaseURL)
                }
                .buttonStyle(.link)

                Spacer()

                Button(L10n.licenseQuit) {
                    onQuit()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
