import AppKit
import SwiftUI
import XCTest
@testable import XNook

@MainActor
final class TaskLinkEditorPreviewTests: XCTestCase {
    func testLinkEditingKeepsResourcePopoverOpenUntilFinished() {
        var presented = true
        var editingLink = true
        let presentation = FocusSessionView.guardedPresentationBinding(
            Binding(get: { presented }, set: { presented = $0 }),
            isEditing: { editingLink }
        )
        presentation.wrappedValue = false
        XCTAssertTrue(presented)
        editingLink = false
        presentation.wrappedValue = false
        XCTAssertFalse(presented)
    }

    func testEditorAndConflictRenderInBothLanguagesAndAppearances() throws {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("需要隔离任务链接编辑界面渲染")
        }
        _ = NSApplication.shared
        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/release-1.3.19-evidence/ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let link = try XCTUnwrap(LinkedTaskURL.make(urlString: "https://example.com/tasks/guide?section=resources", title: "任务说明 · Task resources"))
        var draft = TaskLinkEditDraft(link: link)
        draft.title = "新的任务说明 · Updated task resources"
        draft.address = "https://example.com/tasks/updated-guide?section=resources"
        for language in ["zh", "en"] {
            var arguments = originalArguments
            arguments["appLanguage"] = language
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            for scheme in [ColorScheme.light, .dark] {
                for state in ["ready", "conflict", "write-failed", "long-input"] {
                    var previewDraft = draft
                    if state == "long-input" {
                        previewDraft.title = String(repeating: "长标题", count: 40)
                        previewDraft.address = "https://example.com/" + String(repeating: "a", count: 4000)
                    }
                    let content = VStack(alignment: .leading, spacing: 12) {
                        TaskLinkEditorView(draft: .constant(previewDraft), writesBlocked: state == "write-failed",
                            onSave: { XCTFail("渲染不能保存") }, onCancel: { XCTFail("渲染不能取消") })
                        if state == "conflict" {
                            Text(L10n.flowWebLinkChanged).font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if state == "write-failed" {
                            Text(L10n.flowStorageWriteError).font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(L10n.flowWebLinkRule).font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(18)
                    .frame(width: 420, height: 240, alignment: .topLeading)
                    .background(IslandStyle.surface(for: scheme))
                    .environment(\.colorScheme, scheme)
                    let host = NSHostingView(rootView: content)
                    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 420, height: 240),
                        styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    window.contentView = host
                    defer { window.contentView = nil; window.close() }
                    for _ in 0..<3 {
                        host.layoutSubtreeIfNeeded()
                        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                    }
                    XCTAssertFalse(window.isVisible)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    XCTAssertGreaterThan(png.count, 1000)
                    let name = "editor-\(language)-\(scheme == .dark ? "dark" : "light")-\(state).png"
                    try png.write(to: output.appendingPathComponent(name), options: .atomic)
                }
            }
        }
    }
}
