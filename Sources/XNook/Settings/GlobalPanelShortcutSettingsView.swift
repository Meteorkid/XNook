import AppKit
import SwiftUI

struct GlobalPanelShortcutSettingsView: View {
    let controller: GlobalPanelShortcutController
    var recordingNotifications: NotificationCenter = .default
    var recordingWindowIsKey: (NSWindow) -> Bool = { $0.isKeyWindow }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.globalPanelShortcut).font(.system(size: 13, weight: .medium))
                    Text(controller.activeShortcut != nil ? L10n.shortcutActive : L10n.shortcutInactive)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(controller.isRecording ? L10n.shortcutRecording
                     : (controller.activeShortcut ?? controller.configuredShortcut)?.displayTitle ?? L10n.shortcutNotSet)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(controller.isRecording ? Color.accentColor : .clear, lineWidth: 1))
                    .accessibilityIdentifier("settingsShortcutValue")
            }
            Text(L10n.globalPanelShortcutHelp)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(controller.isRecording ? L10n.shortcutCancelRecording : L10n.shortcutRecord) {
                    if controller.isRecording { controller.endRecording() }
                    else { controller.beginRecording() }
                }
                .accessibilityIdentifier("settingsShortcutRecord")
                Button(L10n.shortcutClear) { _ = controller.clear() }
                    .disabled(!controller.canClear)
                    .accessibilityIdentifier("settingsShortcutClear")
            }
            .controlSize(.small)
            if let failure = controller.failure {
                Text(L10n.shortcutFailure(failure))
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settingsShortcutFailure")
            }
        }
        .padding(.vertical, 8)
        .background(PanelShortcutRecorder(controller: controller, notifications: recordingNotifications,
            windowIsKey: recordingWindowIsKey))
        .onDisappear { controller.endRecording() }
    }
}

/// 只有本窗口的录制控件成为第一响应者后才接收输入，不安装全局键盘监听器。
struct PanelShortcutRecorder: NSViewRepresentable {
    let controller: GlobalPanelShortcutController
    let notifications: NotificationCenter
    let windowIsKey: (NSWindow) -> Bool

    func makeNSView(context: Context) -> RecordingView { RecordingView() }

    func updateNSView(_ view: RecordingView, context: Context) {
        view.onCancel = { controller.endRecording() }
        view.onInvalid = { controller.rejectRecordedInput() }
        view.onCapture = { shortcut in
            controller.endRecording()
            _ = controller.apply(shortcut)
        }
        view.configure(notifications: notifications, windowIsKey: windowIsKey)
        view.setRecording(controller.isRecording)
    }

    final class RecordingView: NSView {
        var onCancel: (() -> Void)?
        var onInvalid: (() -> Void)?
        var onCapture: ((GlobalPanelShortcut) -> Void)?
        private var isRecording = false
        private var notifications: NotificationCenter = .default
        private var windowIsKey: (NSWindow) -> Bool = { $0.isKeyWindow }
        private weak var observedWindow: NSWindow?
        private var observers: [NSObjectProtocol] = []
        override var acceptsFirstResponder: Bool { isRecording }

        func configure(notifications: NotificationCenter, windowIsKey: @escaping (NSWindow) -> Bool) {
            self.windowIsKey = windowIsKey
            guard self.notifications !== notifications else { return }
            removeObservers()
            self.notifications = notifications
            observeCurrentWindow()
        }

        func setRecording(_ enabled: Bool) {
            if !enabled {
                isRecording = false
                if window?.firstResponder === self { window?.makeFirstResponder(nil) }
                return
            }
            guard !isRecording else { return }
            isRecording = enabled
            requestFocus()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if observedWindow != nil && observedWindow !== window { cancelRecording() }
            removeObservers()
            observeCurrentWindow()
            if isRecording { requestFocus() }
        }

        private func observeCurrentWindow() {
            guard let window else { return }
            observedWindow = window
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                observers.append(notifications.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window, self.observedWindow === window else { return }
                        self.cancelRecording()
                    }
                })
            }
            observers.append(notifications.addObserver(forName: NSApplication.didResignActiveNotification,
                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelRecording() }
            })
        }

        private func removeObservers() {
            for observer in observers { notifications.removeObserver(observer) }
            observers.removeAll()
            observedWindow = nil
        }

        private func cancelRecording() {
            guard isRecording else { return }
            isRecording = false
            onCancel?()
        }

        private func requestFocus() {
            guard let expectedWindow = window else { return }
            DispatchQueue.main.async { [weak self, weak expectedWindow] in
                guard let self, self.isRecording, let expectedWindow,
                      self.window === expectedWindow, self.observedWindow === expectedWindow else { return }
                guard self.windowIsKey(expectedWindow) else { self.cancelRecording(); return }
                expectedWindow.makeFirstResponder(self)
            }
        }

        override func resignFirstResponder() -> Bool {
            cancelRecording()
            return super.resignFirstResponder()
        }

        override func keyDown(with event: NSEvent) {
            if !capture(event) { super.keyDown(with: event) }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            return capture(event)
        }

        private func capture(_ event: NSEvent) -> Bool {
            guard isRecording else { return false }
            if event.keyCode == 53 { onCancel?(); return true }
            guard !event.isARepeat else { return true }
            if let shortcut = GlobalPanelShortcut.captured(from: event) { onCapture?(shortcut) }
            else { onInvalid?() }
            return true
        }

        deinit {
            for observer in observers { notifications.removeObserver(observer) }
        }
    }
}
