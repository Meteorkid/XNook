import AppKit
import SwiftUI

/// 让「拖进系统设置」真正只剩一步。
///
/// 系统设置一打开就会盖住主窗口，用户要么先挪窗、要么找不到拖拽源。
/// 这里在系统设置窗口旁边浮起一个小面板（非激活、置顶、跟随所有桌面），
/// 里面就是可拖拽的应用图标；拖到右侧的授权列表即可完成添加——
/// 和把 app 拖进「应用程序」文件夹是同一种操作。
@MainActor
final class PermissionDragAssistant {

    static let shared = PermissionDragAssistant()

    private var panel: NSPanel?
    private var pendingTask: Task<Void, Never>?

    /// 打开系统设置的指定分页，稍等它出窗口，再把拖拽面板贴到它左边。
    func begin(for pane: SystemPrivacySettings.Pane) {
        SystemPrivacySettings.open(pane)
        pendingTask?.cancel()
        let target = pane.listTitle
        pendingTask = Task { [weak self] in
            // 系统设置冷启动可能要一两秒，多试几次再定位；找不到就放到屏幕右上角。
            for attempt in 0..<6 {
                try? await Task.sleep(for: .milliseconds(attempt == 0 ? 500 : 350))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if let frame = Self.systemSettingsFrame() {
                    self.show(near: frame, target: target)
                    return
                }
            }
            self?.show(near: nil, target: target)
        }
    }

    func close() {
        pendingTask?.cancel()
        pendingTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func show(near settingsFrame: CGRect?, target: String) {
        let host = NSHostingView(rootView: PermissionDragChip(
            target: target,
            onDragEnded: { [weak self] in self?.close() },
            onClose: { [weak self] in self?.close() }
        ))
        host.layoutSubtreeIfNeeded()
        // 让面板贴着内容走，避免底部拖出一大块空白。
        let fitted = host.fittingSize
        let size = CGSize(width: 132, height: max(140, min(220, fitted.height)))
        let frame = CGRect(origin: Self.origin(near: settingsFrame, size: size), size: size)

        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.panel = panel
        }
        // 每次重建内容：提示语随目标分页变化，面板尺寸也跟着贴合。
        panel.contentView = host
        panel.setContentSize(size)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    // MARK: - 定位

    /// 系统设置主窗口的位置（CGWindowList 是左上原点，这里换算成 Cocoa 的左下原点）。
    static func systemSettingsFrame() -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let names: Set<String> = ["System Settings", "系统设置"]
        var best: CGRect?
        for window in windows {
            guard let owner = window[kCGWindowOwnerName as String] as? String, names.contains(owner),
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 420, rect.height >= 320 else { continue }
            if best == nil || rect.width * rect.height > best!.width * best!.height { best = rect }
        }
        guard let rect = best else { return nil }

        // 主屏坐标系：CG 的 y 向下，Cocoa 的 y 向上。
        let primaryHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func origin(near settingsFrame: CGRect?, size: CGSize) -> CGPoint {
        let screen = (settingsFrame.flatMap { frame in
            NSScreen.screens.first { $0.frame.intersects(frame) }
        } ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        guard let settingsFrame else {
            return CGPoint(x: screen.maxX - size.width - 24, y: screen.maxY - size.height - 120)
        }
        // 贴在系统设置左侧、顶部对齐；屏幕放不下时退到屏幕边缘。
        let x = max(screen.minX + 12, settingsFrame.minX - size.width - 12)
        let y = min(max(screen.minY + 12, settingsFrame.maxY - size.height - 28),
                    screen.maxY - size.height - 12)
        return CGPoint(x: x, y: y)
    }
}
