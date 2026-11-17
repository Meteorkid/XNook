import AppKit
import XCTest
@testable import XNook

@MainActor
final class IslandAttentionReceiverTests: XCTestCase {
    func testQueuedPlainShowBeforeAttentionDoesNotStartPreparation() throws {
        try withReceiver { delegate, window, counters in
            let oldURL = try XCTUnwrap(IslandAttentionEpoch.adding(IslandAttentionEpoch.capture(), to: showURL))
            XCTAssertTrue(IslandAttentionEpoch.advance())
            delegate.application(NSApp, open: [oldURL])
            XCTAssertNil(window.handoffState.pendingPreparation)
            XCTAssertEqual(counters.fronts, 0)
            XCTAssertFalse(window.isSwitchingApps)
        }
    }

    func testPreparationStartedBeforeAttentionCannotPresentLater() throws {
        try withReceiver { delegate, window, counters in
            let oldURL = try XCTUnwrap(IslandAttentionEpoch.adding(IslandAttentionEpoch.capture(), to: showURL))
            delegate.application(NSApp, open: [oldURL])
            let generation = try XCTUnwrap(window.handoffState.pendingPreparation)
            XCTAssertTrue(IslandAttentionEpoch.advance())
            XCTAssertTrue(window.completeInboundHandoffPreparation(generation: generation))
            XCTAssertEqual(counters.fronts, 0)
            XCTAssertEqual(counters.outs, 1)
            XCTAssertTrue(window.isHiddenByIslandSwitch)
            XCTAssertFalse(window.isSwitchingApps)
        }
    }

    func testNewManualSwitchAfterAttentionCanPresent() throws {
        try withReceiver { delegate, window, counters in
            XCTAssertTrue(IslandAttentionEpoch.advance())
            let url = try XCTUnwrap(IslandAttentionEpoch.adding(IslandAttentionEpoch.capture(), to: showURL))
            delegate.application(NSApp, open: [url])
            let generation = try XCTUnwrap(window.handoffState.pendingPreparation)
            XCTAssertTrue(window.completeInboundHandoffPreparation(generation: generation))
            XCTAssertEqual(counters.fronts, 1)
            XCTAssertFalse(window.isHiddenByIslandSwitch)
        }
    }

    func testLegacyPreparationStillRespectsAttentionArrivingAfterAdmission() throws {
        try withReceiver { delegate, window, counters in
            delegate.application(NSApp, open: [showURL])
            let generation = try XCTUnwrap(window.handoffState.pendingPreparation)
            XCTAssertTrue(IslandAttentionEpoch.advance())
            XCTAssertTrue(window.completeInboundHandoffPreparation(generation: generation))
            XCTAssertEqual(counters.fronts, 0)
            XCTAssertTrue(window.isHiddenByIslandSwitch)
        }
    }

    private var showURL: URL { URL(string: "xnook://xnook/show")! }

    private final class Counters {
        var fronts = 0
        var outs = 0
    }

    private func withReceiver(_ body: (AppDelegate, NotchWindow, Counters) throws -> Void) throws {
        _ = NSApplication.shared
        let suite = "XNookTests.AttentionReceiver.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let previousDefaults = IslandIntegrationSettings.sharedDefaults
        IslandIntegrationSettings.sharedDefaults = defaults
        defer {
            IslandIntegrationSettings.sharedDefaults = previousDefaults
            defaults.removePersistentDomain(forName: suite)
        }
        let counters = Counters()
        let window = NotchWindow(defaults: defaults, markVisible: {}, onExplicitShow: {},
            handoffEnvironment: .init(reduceMotion: { true }, orderFront: { _ in counters.fronts += 1 },
                                      orderOut: { _ in counters.outs += 1 }))
        NSWorkspace.shared.notificationCenter.removeObserver(window)
        defer { window.close() }
        let delegate = AppDelegate()
        delegate.notchWindow = window
        try body(delegate, window, counters)
    }
}
