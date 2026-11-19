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
                    // 系统设置可能是被别的窗口盖着打开的；先提到最前，
                    // 否则拖拽板会孤零零浮在一个不相干的窗口上，看着像跑偏了。
                    Self.activateSystemSettings()
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
        // 先量高度：宽度固定、方向只影响箭头，所以先按一个方向试排，拿到尺寸再决定摆哪儿。
        let probe = NSHostingView(rootView: PermissionDragChip(
            target: target,
            direction: .right,
            onDragEnded: {},
            onClose: {}
        ))
        probe.layoutSubtreeIfNeeded()
        let size = CGSize(width: 340, height: max(96, ceil(probe.fittingSize.height)))
        let (origin, direction) = Self.placement(near: settingsFrame, size: size)

        let host = NSHostingView(rootView: PermissionDragChip(
            target: target,
            direction: direction,
            onDragEnded: { [weak self] in self?.close() },
            onClose: { [weak self] in self?.close() }
        ))
        host.layoutSubtreeIfNeeded()
        let frame = CGRect(origin: origin, size: size)

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
            // 面板位置由 placement 自动决定。开启「拖动背景移动窗口」会让
            // 落在条目之外的按下变成移动整块卡片，正是用户看到的「拖着整个浮窗在动」。
            panel.isMovableByWindowBackground = false
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.panel = panel
        }
        // 每次重建内容：提示语与箭头方向随位置变化。
        panel.contentView = host
        panel.setContentSize(size)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    // MARK: - 定位

    private static func activateSystemSettings() {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.systempreferences")
            .first?
            .activate()
    }

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

    /// 决定面板摆在哪一侧，以及箭头该指哪边。
    ///
    /// 优先级：左侧（不挡系统设置，也不挡列表）→ 右侧 → 下方 → 贴左边缘兜底。
    /// 箭头方向必须和实际位置一致，否则「往哪拖」这件事又变回猜。
    static func placement(
        near settingsFrame: CGRect?,
        size: CGSize
    ) -> (CGPoint, PermissionDragChip.ArrowDirection) {
        let screen = (settingsFrame.flatMap { frame in
            NSScreen.screens.first { $0.frame.intersects(frame) }
        } ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let gap: CGFloat = 12
        guard let settingsFrame else {
            return (CGPoint(x: screen.maxX - size.width - 24, y: screen.maxY - size.height - 120), .right)
        }

        // 与系统设置顶部对齐，但不越出屏幕。
        let alignedY = min(
            max(screen.minY + gap, settingsFrame.maxY - size.height - 28),
            screen.maxY - size.height - gap
        )

        if settingsFrame.minX - size.width - gap >= screen.minX + gap {
            return (CGPoint(x: settingsFrame.minX - size.width - gap, y: alignedY), .right)
        }
        if settingsFrame.maxX + size.width + gap <= screen.maxX - gap {
            return (CGPoint(x: settingsFrame.maxX + gap, y: alignedY), .left)
        }
        if settingsFrame.minY - size.height - gap >= screen.minY + gap {
            return (CGPoint(x: max(screen.minX + gap, settingsFrame.minX), y: settingsFrame.minY - size.height - gap), .up)
        }
        // 空间实在不够：贴左边缘，允许压住系统设置边缘，但箭头仍然指向列表。
        return (CGPoint(x: max(screen.minX + gap, settingsFrame.minX - size.width - gap), y: alignedY), .right)
    }
}