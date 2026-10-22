import AppKit
import XCTest
@testable import XNook

@MainActor
final class NotchWindowInteractionTests: XCTestCase {
    func testExpandedPanelForwardsDraggingInsteadOfMovingWindow() throws {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("与隔离 UI 验证一起运行，不要求普通单元测试连接 WindowServer")
        }
        _ = NSApplication.shared
        var pointer = NSPoint(x: 100, y: 100)
        let window = NotchWindow(pointerLocation: { pointer })
        defer { window.close() }
        let frame = window.frame
        window.islandState = .expanded
        window.sendEvent(try mouseEvent(.leftMouseDown, window: window))
        pointer.x += 60
        window.sendEvent(try mouseEvent(.leftMouseDragged, window: window))
        XCTAssertFalse(window.isDragging)
        XCTAssertEqual(window.frame, frame)
        window.sendEvent(try mouseEvent(.leftMouseUp, window: window))

        window.islandState = .collapsed
        window.sendEvent(try mouseEvent(.leftMouseDown, window: window))
        pointer.x += 60
        window.sendEvent(try mouseEvent(.leftMouseDragged, window: window))
        XCTAssertTrue(window.isDragging, "收起药丸仍支持拖动")
        window.sendEvent(try mouseEvent(.leftMouseUp, window: window))
        XCTAssertFalse(window.isDragging)
    }

    private func mouseEvent(_ type: NSEvent.EventType, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 20, y: 20),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
    }
}
