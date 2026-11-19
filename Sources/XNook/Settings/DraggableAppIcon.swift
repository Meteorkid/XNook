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

class AppIconDragView: NSView, NSDraggingSource {

    var bundleURL: URL = Bundle.main.bundleURL {
        didSet { needsDisplay = true }
    }

    /// 拖拽会话结束时回调一次，参数表示目标是否接受了这个拖拽。
    var onDragEnded: (() -> Void)?

    private var mouseDownEvent: NSEvent?
    private var hasStartedDrag = false

    override var isFlipped: Bool { false }

    /// 透明视图的 `mouseDownCanMoveWindow` 默认是 `true`（`isOpaque == false` 即如此）。
    /// 不覆盖的话，按下拖拽会被 AppKit 解释成「移动窗口」，事件根本到不了
    /// `mouseDragged`——用户看到的就是整块浮窗跟着鼠标走，而不是图标被拖出去。
    override var mouseDownCanMoveWindow: Bool { false }

    /// 预览/测试宿主里 `Bundle.main` 不是 .app，用系统给的应用图标兜底，避免画出一个文件夹。
    var displayIcon: NSImage {
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

    /// 拖拽时贴在手下的图片。默认就是图标本身；整行拖拽板会缩小它，避免拖出一个巨大的行。
    var dragPreview: NSImage { displayIcon }
    /// 拖拽图片在图中的位置。默认铺满整个视图。
    var draggingFrame: NSRect { bounds }

    override func mouseDragged(with event: NSEvent) {
        guard !hasStartedDrag, let down = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard (dx * dx + dy * dy).squareRoot() > 3 else { return }
        hasStartedDrag = true

        let item = NSDraggingItem(pasteboardWriter: bundleURL as NSURL)
        item.setDraggingFrame(draggingFrame, contents: dragPreview)
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


/// 整行拖拽板：自己什么都不画，可视样式完全交给 SwiftUI。
///
/// 为什么不用 SwiftUI 的 `.onDrag`：那需要先按住再移动，且拖拽图片是整行的快照。
/// 这里复用 `AppIconDragView` 的拖拽状态机，只把「画什么」和「拖什么」换掉，
/// 于是「按住任意位置直接拖走」的手感和主图标完全一致。
final class AppDragHandleView: AppIconDragView {

    override func draw(_ dirtyRect: NSRect) {
        // 透明：背景与文字由 SwiftUI 负责。
    }

    override var dragPreview: NSImage {
        let side = draggingFrame.width
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            self.displayIcon.draw(in: rect)
            return true
        }
        return image
    }

    override var draggingFrame: NSRect {
        let side: CGFloat = 48
        return NSRect(
            x: bounds.midX - side / 2,
            y: bounds.midY - side / 2,
            width: side,
            height: side
        )
    }
}

/// 整行可拖拽的 SwiftUI 封装。
struct AppDragHandle: NSViewRepresentable {
    var bundleURL: URL = Bundle.main.bundleURL
    var onDragEnded: (() -> Void)? = nil

    func makeNSView(context: Context) -> AppDragHandleView {
        let view = AppDragHandleView(frame: .zero)
        view.bundleURL = bundleURL
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: AppDragHandleView, context: Context) {
        nsView.bundleURL = bundleURL
        nsView.onDragEnded = onDragEnded
    }

    /// 撑满被覆盖的那一行，别依赖 SwiftUI 的默认提议尺寸。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AppDragHandleView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
}
