import AppKit
import SwiftUI

/// 可拖拽的应用图标。
///
/// 拖出来的东西就是 `.app` 文件本身（`public.file-url`），因此可以直接落进
/// 系统设置的隐私列表完成「添加应用」，用户不必先去 Finder 里找一遍。
struct DraggableAppIcon: NSViewRepresentable {
    var bundleURL: URL = Bundle.main.bundleURL
    var side: CGFloat = 52
    /// 拖拽结束回调：浮动拖拽板靠它判断「已经放下」，自动收起来。
    var onDragEnded: (() -> Void)? = nil

    func makeNSView(context: Context) -> AppIconDragView {
        let view = AppIconDragView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.bundleURL = bundleURL
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: AppIconDragView, context: Context) {
        nsView.bundleURL = bundleURL
        nsView.onDragEnded = onDragEnded
        if nsView.frame.size != NSSize(width: side, height: side) {
            nsView.setFrameSize(NSSize(width: side, height: side))
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AppIconDragView, context: Context) -> CGSize? {
        CGSize(width: side, height: side)
    }
}

final class AppIconDragView: NSView, NSDraggingSource {

    var bundleURL: URL = Bundle.main.bundleURL {
        didSet { needsDisplay = true }
    }

    /// 拖拽会话结束时回调一次，参数表示目标是否接受了这个拖拽。
    var onDragEnded: (() -> Void)?

    private var mouseDownEvent: NSEvent?
    private var hasStartedDrag = false

    override var isFlipped: Bool { false }

    /// 预览/测试宿主里 `Bundle.main` 不是 .app，用系统给的应用图标兜底，避免画出一个文件夹。
    private var displayIcon: NSImage {
        let isApp = bundleURL.pathExtension == "app"
        return isApp ? NSWorkspace.shared.icon(forFile: bundleURL.path) : NSApp.applicationIconImage
    }

    override func draw(_ dirtyRect: NSRect) {
        displayIcon.draw(in: bounds)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    /// 浮动拖拽板是非激活面板：不做这个覆盖时，第一次按下只会去激活窗口，
    /// 用户会以为「拖不动」，得按第二次才行。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        hasStartedDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !hasStartedDrag, let down = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard (dx * dx + dy * dy).squareRoot() > 3 else { return }
        hasStartedDrag = true

        let item = NSDraggingItem(pasteboardWriter: bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: displayIcon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
        hasStartedDrag = false
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        hasStartedDrag = false
        // 只有真正被接收（落到系统设置列表里）才收起浮动面板；
        // 拖到空白处取消时保留，用户可以再试一次。
        if operation != [] { onDragEnded?() }
    }
}
