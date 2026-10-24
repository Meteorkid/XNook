import AppKit
import SwiftUI
import XCTest
@testable import XNook

@MainActor
final class SettingsWindowTests: XCTestCase {
    func testSceneRegistrationReplacesOnlyThePreviousSettingsWindow() {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let previous = makeWindow()
        let scene = makeWindow()
        let unrelated = makeWindow()
        defer { previous.close(); scene.close(); unrelated.close() }

        delegate.registerSettingsWindow(previous)
        delegate.registerSettingsWindow(scene)
        delegate.registerSettingsWindow(scene)

        XCTAssertTrue(delegate.settingsWindowForPresentation() === scene)
        XCTAssertEqual(previous.closeCount, 1)
        XCTAssertEqual(scene.closeCount, 0)
        XCTAssertEqual(unrelated.closeCount, 0)
    }

    func testClosedSettingsWindowRemainsCanonicalWithItsContent() {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let scene = makeWindow()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 500))
        scene.contentView = content
        delegate.registerSettingsWindow(scene)
        scene.close()

        let reused = delegate.settingsWindowForPresentation()
        XCTAssertTrue(reused === scene)
        XCTAssertTrue(reused.contentView === content)
        XCTAssertFalse(reused.isReleasedWhenClosed)
        XCTAssertFalse(reused.isVisible)
    }

    func testRegistrationConstrainsRestoredFramesAndPreservesWindowDelegate() {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let scene = makeWindow()
        let originalDelegate = SettingsWindowDelegate()
        scene.delegate = originalDelegate
        defer { scene.close() }

        for height: CGFloat in [200, 450, 900] {
            let restored = NSRect(x: 100, y: 100, width: 900, height: height)
            scene.setFrame(restored, display: false)
            delegate.registerSettingsWindow(scene)
            XCTAssertEqual(scene.frame.width, 560, accuracy: 1)
            XCTAssertEqual(scene.frame.height, min(max(height, 400), 700), accuracy: 1)
            XCTAssertEqual(scene.frame.maxY, restored.maxY, accuracy: 1)
        }
        XCTAssertTrue(scene.delegate === originalDelegate)
        XCTAssertEqual(scene.closeCount, 0)
    }

    func testWindowReaderRegistersOnAttachmentWithoutClearingOnDetach() {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let scene = makeWindow()
        let reader = SettingsWindowReader.WindowView { [weak delegate] window in
            delegate?.registerSettingsWindow(window)
        }
        defer { scene.close() }

        scene.contentView = reader
        XCTAssertTrue(delegate.settingsWindowForPresentation() === scene)
        scene.contentView = nil
        XCTAssertTrue(delegate.settingsWindowForPresentation() === scene)
        scene.contentView = reader
        XCTAssertTrue(delegate.settingsWindowForPresentation() === scene)
        XCTAssertEqual(scene.closeCount, 0)
    }

    func testSharedSettingsContentRendersInsideTheRegisteredWindow() throws {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("Set XNOOK_RENDER_UI=1 to render isolated settings content")
        }
        _ = NSApplication.shared
        let suite = "XNookTests.SettingsWindow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(800.0, forKey: "panelWidth")
        defaults.set(200.0, forKey: "panelBaseHeight")
        defer { defaults.removePersistentDomain(forName: suite) }
        let delegate = AppDelegate()
        let scene = makeWindow()
        let host = NSHostingView(rootView: delegate.makeSettingsContent()
            .defaultAppStorage(defaults)
            .background(SettingsWindowReader { [weak delegate] window in
                delegate?.registerSettingsWindow(window)
            }.frame(width: 0, height: 0)))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 550)
        scene.contentView = host
        defer { scene.contentView = nil; scene.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(delegate.settingsWindowForPresentation() === scene)
        XCTAssertEqual(host.fittingSize.width, 560, accuracy: 1)
        XCTAssertGreaterThanOrEqual(host.fittingSize.height, 400)
        XCTAssertFalse(scene.isVisible)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000)
        if let directory = ProcessInfo.processInfo.environment["XNOOK_UI_EVIDENCE_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try png.write(to: url.appendingPathComponent("settings-scene-content.png"))
        }
    }

    private func makeWindow() -> SettingsTestWindow {
        let window = SettingsTestWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 550),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }
}

@MainActor
private final class SettingsTestWindow: NSWindow {
    private(set) var closeCount = 0

    override func close() {
        closeCount += 1
        super.close()
    }
}

private final class SettingsWindowDelegate: NSObject, NSWindowDelegate {}
