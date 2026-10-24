import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import XNook

@MainActor
final class GlobalPanelShortcutSettingsPreviewTests: XCTestCase {
    func testShortcutStatesRenderInBothLanguagesAndAppearancesWithoutSystemRegistration() throws {
        try requireRendering()
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        for language in ["zh", "en"] {
            var arguments = original
            arguments["appLanguage"] = language
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            for scheme in [ColorScheme.light, .dark] {
                for state in ["unassigned", "active", "conflict", "restore-conflict"] {
                    let preview = try Preview(scheme: scheme, restoreConflict: state == "restore-conflict")
                    defer { preview.close() }
                    if state == "active" || state == "conflict" {
                        XCTAssertTrue(preview.controller.apply(GlobalPanelShortcutTests.first))
                    }
                    if state == "conflict" {
                        preview.backend.registrationFailure = .conflict
                        XCTAssertFalse(preview.controller.apply(GlobalPanelShortcutTests.second))
                    }
                    preview.settle()
                    XCTAssertFalse(preview.window.isVisible)
                    XCTAssertGreaterThan(preview.host.fittingSize.height, 100)
                    if state == "unassigned" { XCTAssertTrue(preview.backend.operations.isEmpty) }
                    if state == "conflict" {
                        XCTAssertEqual(preview.controller.activeShortcut, GlobalPanelShortcutTests.first)
                    }
                    if state == "restore-conflict" {
                        XCTAssertNil(preview.controller.activeShortcut)
                        XCTAssertEqual(preview.controller.configuredShortcut, GlobalPanelShortcutTests.first)
                    }
                    try preview.capture("global-shortcut-\(state)-\(language)-\(scheme == .dark ? "dark" : "light")")
                }
            }
        }
    }

    func testFocusedRecorderAppliesCombinationAndConflictKeepsPreviousValue() throws {
        try requireRendering()
        let preview = try Preview(scheme: .light)
        defer { preview.close() }
        preview.controller.beginRecording()
        preview.settle()
        let recorder = try XCTUnwrap(preview.window.firstResponder as? NSView)
        XCTAssertTrue(recorder.performKeyEquivalent(with: try key(code: 45, modifiers: [.command, .option], text: "n")))
        preview.settle()
        XCTAssertEqual(preview.controller.activeShortcut, GlobalPanelShortcutTests.first)
        XCTAssertFalse(preview.controller.isRecording)

        preview.backend.registrationFailure = .conflict
        preview.controller.beginRecording()
        preview.settle()
        let retryRecorder = try XCTUnwrap(preview.window.firstResponder as? NSView)
        XCTAssertTrue(retryRecorder.performKeyEquivalent(with: try key(code: 49, modifiers: [.control, .shift], text: " ")))
        preview.settle()
        XCTAssertEqual(preview.controller.failure, .conflict)
        XCTAssertEqual(preview.controller.activeShortcut, GlobalPanelShortcutTests.first)
        let stored = try XCTUnwrap(preview.defaults.data(forKey: GlobalPanelShortcut.storageKey))
        XCTAssertEqual(try JSONDecoder().decode(GlobalPanelShortcut.self, from: stored), GlobalPanelShortcutTests.first)

        preview.controller.beginRecording()
        preview.settle()
        let cancelRecorder = try XCTUnwrap(preview.window.firstResponder as? NSView)
        cancelRecorder.keyDown(with: try key(code: 53, modifiers: [], text: "\u{1B}"))
        preview.settle()
        XCTAssertFalse(preview.controller.isRecording)
        XCTAssertEqual(preview.controller.activeShortcut, GlobalPanelShortcutTests.first)
        XCTAssertFalse(preview.window.isVisible)
    }

    private func key(code: UInt16, modifiers: NSEvent.ModifierFlags, text: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code))
    }

    private func requireRendering() throws {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("使用 XNOOK_RENDER_UI=1 运行隔离快捷键设置宿主")
        }
        _ = NSApplication.shared
    }

    @MainActor
    private final class Preview {
        let suite = "XNook.GlobalPanelShortcutPreview.\(UUID().uuidString)"
        let defaults: UserDefaults
        let backend = TestGlobalPanelShortcutBackend()
        let controller: GlobalPanelShortcutController
        let host: NSView
        let window: NSWindow

        init(scheme: ColorScheme, restoreConflict: Bool = false) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            if restoreConflict {
                defaults.set(try JSONEncoder().encode(GlobalPanelShortcutTests.first), forKey: GlobalPanelShortcut.storageKey)
                backend.registrationFailure = .conflict
            }
            controller = GlobalPanelShortcutController(defaults: defaults, backend: backend)
            controller.activate()
            // 隔离宿主只模拟“所属窗口为 key”的判断，始终不把窗口显示或设为系统 key window。
            host = NSHostingView(rootView: GlobalPanelShortcutSettingsView(controller: controller,
                recordingNotifications: NotificationCenter(), recordingWindowIsKey: { _ in true })
                .padding(14).frame(width: 512, height: 250, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme).defaultAppStorage(defaults))
            host.frame = NSRect(x: 0, y: 0, width: 512, height: 250)
            window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 512, height: 250),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
        }

        func settle() {
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.025))
            }
        }

        func capture(_ name: String) throws {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 4_000)
            if let directory = ProcessInfo.processInfo.environment["XNOOK_UI_EVIDENCE_DIR"] {
                let output = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try data.write(to: output.appendingPathComponent(name + ".png"))
            }
        }

        func close() { controller.shutdown(); window.contentView = nil; window.close(); defaults.removePersistentDomain(forName: suite) }
    }
}
