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

    func testFactoryContentUsesOwnerWhenSharedDelegateIsNotAssignedYet() throws {
        try verifyFactoryContentRetainsOwner(sharedPointsElsewhere: false)
    }

    func testFactoryContentUsesOwnerWhenSharedDelegatePointsElsewhere() throws {
        try verifyFactoryContentRetainsOwner(sharedPointsElsewhere: true)
    }

    private func verifyFactoryContentRetainsOwner(sharedPointsElsewhere: Bool) throws {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("使用 XNOOK_RENDER_UI=1 验证生产设置工厂的运行时实例绑定")
        }
        _ = NSApplication.shared
        let originalShared = AppDelegate.shared
        let ownerSuite = "XNookTests.SettingsFactory.Owner.\(UUID().uuidString)"
        let foreignSuite = "XNookTests.SettingsFactory.Foreign.\(UUID().uuidString)"
        let ownerDefaults = try XCTUnwrap(UserDefaults(suiteName: ownerSuite))
        let foreignDefaults = try XCTUnwrap(UserDefaults(suiteName: foreignSuite))
        SettingsDefaults.register(on: ownerDefaults)
        SettingsDefaults.register(on: foreignDefaults)
        ownerDefaults.set(true, forKey: "reduceMotion")
        let owner = AppDelegate()
        let foreign = AppDelegate()
        let ownerBackend = TestGlobalPanelShortcutBackend()
        let foreignBackend = TestGlobalPanelShortcutBackend()
        let ownerShortcut = GlobalPanelShortcutController(defaults: ownerDefaults, backend: ownerBackend)
        let foreignShortcut = GlobalPanelShortcutController(defaults: foreignDefaults, backend: foreignBackend)
        owner.globalPanelShortcut = ownerShortcut
        foreign.globalPanelShortcut = foreignShortcut
        // 接收器构造不打开 socket；本测试不启用 Claude 接入。
        owner.claudeCompletionReceiver = ClaudeCompletionReceiver(deliver: { _ in XCTFail("设置工厂测试不应接收事件") })
        foreign.claudeCompletionReceiver = ClaudeCompletionReceiver(deliver: { _ in XCTFail("设置工厂测试不应接收事件") })
        AppDelegate.shared = sharedPointsElsewhere ? foreign : nil
        defer {
            AppDelegate.shared = originalShared
            ownerShortcut.shutdown()
            foreignShortcut.shutdown()
            owner.claudeCompletionReceiver.shutdown()
            foreign.claudeCompletionReceiver.shutdown()
            owner.themeManager.stopObservingSystemAppearance()
            foreign.themeManager.stopObservingSystemAppearance()
            ownerDefaults.removePersistentDomain(forName: ownerSuite)
            foreignDefaults.removePersistentDomain(forName: foreignSuite)
        }

        let scene = SettingsFactoryLifecycleWindow(contentRect: NSRect(x: -10000, y: -10000, width: 560, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        scene.isReleasedWhenClosed = false
        // 必须经生产 factory 构造并安装原宿主，不能直接构造 SettingsView 或事后替换 rootView。
        let host = NSHostingView(rootView: owner.makeSettingsContent().defaultAppStorage(ownerDefaults))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 700)
        scene.contentView = host
        defer { scene.contentView = nil; scene.close() }
        settleFactoryHost(host)
        XCTAssertFalse(ownerShortcut.isActivated)
        XCTAssertTrue(ownerBackend.operations.isEmpty)

        // 模拟 Settings scene 先构造，而 AppDelegate 后完成单实例初始化。
        ownerShortcut.activate()
        XCTAssertTrue(ownerShortcut.apply(GlobalPanelShortcutTests.first))
        settleFactoryHost(host)
        XCTAssertTrue(scene.contentView === host)
        XCTAssertEqual(ownerBackend.operations, [.register(1)])
        XCTAssertFalse(foreignShortcut.isActivated)

        // 读取当前宿主的公开语义，不检查私有 @State 或视图内部存储。
        if let value = factoryAccessibilityElements(in: host).first(where: {
            $0.accessibilityIdentifier() == "settingsShortcutValue"
        }) {
            let texts = [value.accessibilityValue() as? String, value.accessibilityLabel()].compactMap { $0 }
            XCTAssertTrue(texts.contains(GlobalPanelShortcutTests.first.displayTitle),
                "工厂原宿主应观察所属 delegate 后续激活的快捷键")
        }
        let pressedButton = try exerciseFactoryShortcutControl(in: host)
        settleFactoryHost(host)
        if pressedButton {
            XCTAssertTrue(ownerShortcut.isRecording, "原宿主的录制按钮必须操作所属 delegate 的同一控制器")
        } else {
            XCTAssertEqual(ownerShortcut.activeShortcut, GlobalPanelShortcutTests.second,
                "原宿主录制控件的生产回调必须更新所属 delegate；不能捕获未激活的 fallback 或其他 delegate")
            XCTAssertEqual(ownerShortcut.configuredShortcut, GlobalPanelShortcutTests.second)
            XCTAssertEqual(ownerBackend.operations, [.register(1), .register(2), .unregister(1)])
        }
        XCTAssertFalse(foreignShortcut.isRecording)
        XCTAssertNil(foreignShortcut.activeShortcut)
        XCTAssertNil(ownerShortcut.failure)
        XCTAssertTrue(foreignBackend.operations.isEmpty)
        XCTAssertFalse(scene.isVisible, "隔离宿主不得显示真实窗口")
        ownerShortcut.endRecording()
    }

    private func settleFactoryHost(_ host: NSView) {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
    }

    private func exerciseFactoryShortcutControl(in host: NSView) throws -> Bool {
        func findRecorder(in view: NSView) -> PanelShortcutRecorder.RecordingView? {
            if let recorder = view as? PanelShortcutRecorder.RecordingView { return recorder }
            return view.subviews.lazy.compactMap { findRecorder(in: $0) }.first
        }
        let recorder = try XCTUnwrap(findRecorder(in: host), "生产设置工厂应包含真实的原生录制控件")
        recorder.scrollToVisible(recorder.bounds)
        settleFactoryHost(host)
        func findButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton,
               button.accessibilityIdentifier() == "settingsShortcutRecord"
                || button.title == L10n.shortcutRecord || button.accessibilityLabel() == L10n.shortcutRecord {
                return button
            }
            return view.subviews.lazy.compactMap { findButton(in: $0) }.first
        }
        if let button = findButton(in: host) {
            button.scrollToVisible(button.bounds)
            settleFactoryHost(host)
            button.performClick(nil)
            return true
        }
        if let element = factoryAccessibilityElements(in: host).first(where: {
            $0.accessibilityIdentifier() == "settingsShortcutRecord"
                || ($0.accessibilityRole() == .button && $0.accessibilityLabel() == L10n.shortcutRecord)
        }), element.accessibilityPerformPress() {
            return true
        }
        // 离屏 SwiftUI 可能不提供虚拟 Button AX；直接向原宿主的真实录制控件交付输入。
        // 这里仅调用被测 NSView 的处理方法，不经过 NSApp.sendEvent、CGEvent 或系统事件队列。
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.control, .shift], timestamp: 0, windowNumber: 0, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        recorder.setRecording(true)
        recorder.keyDown(with: event)
        recorder.setRecording(false)
        return false
    }

    private func factoryAccessibilityElements(in host: NSView) -> [NSAccessibilityProtocol] {
        var visited = Set<ObjectIdentifier>()
        func collect(_ value: Any) -> [NSAccessibilityProtocol] {
            guard let element = value as? NSAccessibilityProtocol,
                  visited.insert(ObjectIdentifier(element as AnyObject)).inserted else { return [] }
            return [element] + (element.accessibilityChildren() ?? []).flatMap(collect)
        }
        func collectViews(_ view: NSView) -> [NSAccessibilityProtocol] {
            collect(view) + view.subviews.flatMap(collectViews)
        }
        return collectViews(host)
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

/// 只让录制控件的焦点校验通过，不调用 makeKey/makeKeyAndOrderFront 或显示窗口。
@MainActor
private final class SettingsFactoryLifecycleWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
