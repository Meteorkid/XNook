import AppKit
import XCTest
@testable import XNook

@MainActor
final class GlobalPanelShortcutRecorderTests: XCTestCase {
    func testWindowAndApplicationDeactivationEndRecordingWithoutSwallowingNextHotKey() throws {
        try requireRendering()
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSApplication.didResignActiveNotification] {
            let fixture = try Fixture()
            defer { fixture.close() }
            fixture.beginRecording()
            settle()
            XCTAssertTrue(fixture.controller.isRecording)
            XCTAssertTrue(fixture.window.firstResponder === fixture.recorder)
            fixture.notifications.post(name: name,
                object: name == NSApplication.didResignActiveNotification ? nil : fixture.window)
            XCTAssertFalse(fixture.controller.isRecording)
            fixture.backend.press(1)
            XCTAssertEqual(fixture.invocations, 1, "窗口失焦后的原快捷键不能被残留录制状态吞掉")
            XCTAssertEqual(fixture.backend.registered, [1: GlobalPanelShortcutTests.first])
            XCTAssertFalse(fixture.window.isKeyWindow)
            XCTAssertFalse(fixture.window.isVisible)
        }
    }

    func testDeferredFocusRequestCancelsWhenWindowIsNoLongerKey() throws {
        try requireRendering()
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.beginRecording()
        fixture.simulatedKeyWindow = false
        settle()
        XCTAssertFalse(fixture.controller.isRecording)
        XCTAssertFalse(fixture.window.firstResponder === fixture.recorder)
        fixture.backend.press(1)
        XCTAssertEqual(fixture.invocations, 1)
        XCTAssertFalse(fixture.window.isKeyWindow)
    }

    func testMovingRecorderRebindsWindowNotificationsAndDiscardsOldFocusRequest() throws {
        try requireRendering()
        let fixture = try Fixture()
        defer { fixture.close() }
        let replacement = Self.makeWindow()
        defer { replacement.contentView = nil; replacement.close() }
        fixture.beginRecording()
        fixture.window.contentView = nil
        XCTAssertFalse(fixture.controller.isRecording)
        replacement.contentView = fixture.recorder
        fixture.beginRecording()
        settle()
        XCTAssertTrue(replacement.firstResponder === fixture.recorder)
        XCTAssertFalse(fixture.window.firstResponder === fixture.recorder)
        fixture.notifications.post(name: NSWindow.didResignKeyNotification, object: fixture.window)
        XCTAssertTrue(fixture.controller.isRecording, "旧窗口的 observer 应已移除")
        fixture.notifications.post(name: NSWindow.didResignKeyNotification, object: replacement)
        XCTAssertFalse(fixture.controller.isRecording)
        fixture.backend.press(1)
        XCTAssertEqual(fixture.invocations, 1)
        XCTAssertFalse(replacement.isVisible)
        XCTAssertFalse(replacement.isKeyWindow)
    }

    private func requireRendering() throws {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("使用 XNOOK_RENDER_UI=1 运行隔离录制窗口生命周期测试")
        }
        _ = NSApplication.shared
    }

    private func settle() {
        for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.025)) }
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @MainActor
    private final class Fixture {
        let suite = "XNook.ShortcutRecorderLifecycle.\(UUID().uuidString)"
        let defaults: UserDefaults
        let backend = TestGlobalPanelShortcutBackend()
        let notifications = NotificationCenter()
        let recorder = PanelShortcutRecorder.RecordingView()
        let window = GlobalPanelShortcutRecorderTests.makeWindow()
        var simulatedKeyWindow = true
        var invocations = 0
        lazy var controller = GlobalPanelShortcutController(defaults: defaults, backend: backend) { [weak self] in
            self?.invocations += 1
        }

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            controller.activate()
            XCTAssertTrue(controller.apply(GlobalPanelShortcutTests.first))
            recorder.onCancel = { [weak self] in self?.controller.endRecording() }
            recorder.configure(notifications: notifications, windowIsKey: { [weak self] _ in self?.simulatedKeyWindow ?? false })
            window.contentView = recorder
        }

        func beginRecording() { controller.beginRecording(); recorder.setRecording(true) }
        func close() { controller.shutdown(); window.contentView = nil; window.close(); defaults.removePersistentDomain(forName: suite) }
    }
}
