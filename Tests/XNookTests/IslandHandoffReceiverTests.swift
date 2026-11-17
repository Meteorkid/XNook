import AppKit
import XCTest
@testable import XNook

@MainActor
final class IslandHandoffReceiverTests: XCTestCase {
    func testHideRequestWithoutVisiblePeerKeepsSourceWindow() {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let fixture = makeWindow()
        let window = fixture.window
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        delegate.notchWindow = window
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let switcher = AppSwitcher(environment: .init(
            applicationURL: { _ in nil }, open: { _, _, _ in },
            isVisible: { _ in false }, isFrontmost: { _ in false },
            setSwitching: { _ in }, hideSource: {}, restoreSource: {},
            schedule: { _, _ in {} }
        ))
        delegate.hideIslandForSwitch(using: switcher)
        XCTAssertTrue(window.isVisible, "目标尚未显示时不能隐藏当前岛")
        XCTAssertFalse(window.isHiddenByIslandSwitch)
    }
    func testOldInboundTimerCannotClearNewOutboundSwitchProtection() {
        let delegate = AppDelegate()
        let fixture = makeWindow()
        let window = fixture.window
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        defer { window.orderOut(nil) }
        let switcher = AppSwitcher(environment: .init(
            applicationURL: { _ in URL(fileURLWithPath: "/Applications/X Island.app") },
            open: { _, _, _ in }, isVisible: { _ in false }, isFrontmost: { _ in false },
            setSwitching: { window.isSwitchingApps = $0 }, hideSource: {}, restoreSource: {},
            schedule: { _, _ in {} }
        ))
        switcher.switchToIsland(named: "xisland")
        delegate.clearSwitchingProtection(window: window, using: switcher)
        XCTAssertTrue(window.isSwitchingApps)
        switcher.cancelSwitch()
        delegate.clearSwitchingProtection(window: window, using: switcher)
        XCTAssertFalse(window.isSwitchingApps)
    }

    func testDirectionalPendingURLReplaysAfterWindowAssignmentAndKeepsIdentity() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let motion = IslandSwitchMotion(direction: .right, reduceMotion: true)
        let url = try XCTUnwrap(motion.adding(to: URL(string: "xnook://xnook/show")!))
        delegate.application(NSApp, open: [url])
        let fixture = makeWindow()
        defer { fixture.window.close(); fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        delegate.notchWindow = fixture.window
        delegate.application(NSApp, open: [url])
        XCTAssertEqual(fixture.window.inboundSwitchMotion, motion)
        XCTAssertFalse(fixture.window.isVisible)
        fixture.window.installHandoffPreparationHandler { [weak window = fixture.window] generation in
            _ = window?.completeInboundHandoffPreparation(generation: generation)
        }
        XCTAssertTrue(fixture.window.isVisible)
        let generation = fixture.window.handoffState.generation
        delegate.application(NSApp, open: [url])
        XCTAssertEqual(fixture.window.handoffState.generation, generation)
        XCTAssertFalse(fixture.window.isSwitchingApps)
    }

    private func makeWindow() -> (window: NotchWindow, defaults: UserDefaults, suite: String) {
        let suite = "XNookTests.HandoffReceiver.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "hideInFullscreen")
        let window = NotchWindow(defaults: defaults, markVisible: {}, onExplicitShow: {})
        NSWorkspace.shared.notificationCenter.removeObserver(window)
        return (window, defaults, suite)
    }

}
