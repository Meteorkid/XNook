import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import XNook

@MainActor
final class ClaudeCompletionIntegrationTests: XCTestCase {
    func testHookScriptReachesNativeReceiverAndActivityCoordinator() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        let result = try await fixture.run(executable: ClaudeHookConfiguration.preferredPython,
            arguments: [Self.script.path, "--socket", fixture.socket.path],
            input: Data(#"{"hook_event_name":"Stop","session_id":"synthetic","prompt_id":"one","last_assistant_message":"must stay private"}"#.utf8),
            logName: "sender", timeout: 5)
        XCTAssertEqual(result, 0)
        await fixture.waitUntil { fixture.presented.count == 1 }
        XCTAssertEqual(fixture.received.count, 1)
        XCTAssertEqual(fixture.presented.first?.title, L10n.claudeResponseEnded)
        XCTAssertEqual(fixture.coordinator.current?.kind, .completion)
        XCTAssertEqual(fixture.coordinator.current?.action, PanelActivityEvent.Action.none)
        XCTAssertFalse(try Data(contentsOf: fixture.directory.appendingPathComponent("sender.stdout")).contains(Data("must stay private".utf8)))
    }

    func testClaudeSettingsRenderOffAndReadyInBothLanguagesAndAppearances() async throws {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else { throw XCTSkip("需要隔离 Claude 接入界面渲染") }
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let suite = "XNook.ClaudePreview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        SettingsDefaults.register(on: defaults)
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            defaults.removePersistentDomain(forName: suite)
            UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
        }
        let output = Self.evidence.appendingPathComponent("ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let configuration = try XCTUnwrap(ClaudeHookConfiguration.json(script: Self.script, python: ClaudeHookConfiguration.preferredPython))
        for enabled in [false, true] {
            if enabled { try await fixture.start() }
            defaults.set(enabled, forKey: "claudeCompletionEnabled")
            for language in ["zh", "en"] {
                var arguments = original
                arguments["appLanguage"] = language
                UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
                for scheme in [ColorScheme.dark, .light] {
                    let search = SettingsSearchState()
                    search.selectPane(.integration)
                    let permissions = SettingsPermissions(readCalendar: { .notDetermined }, readLoginItems: { .notRegistered })
                    let theme = ThemeManager(defaults: defaults)
                    defer { theme.stopObservingSystemAppearance() }
                    let updates = UpdateManager(fetchReleaseData: { XCTFail("预览不得联网检查更新"); throw URLError(.unsupportedURL) })
                    let content = SettingsView(search: search, permissions: permissions, claudeReceiver: fixture.receiver,
                        claudeConfiguration: configuration).environment(theme).environment(updates).defaultAppStorage(defaults)
                    try Self.render(content, size: NSSize(width: 560, height: 550), scheme: scheme,
                        output: output.appendingPathComponent("settings-\(enabled ? "ready" : "off")-\(language)-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
        XCTAssertTrue(fixture.received.isEmpty)
    }

    func testRealClaudeStopHookReachesNoticeWhenExplicitlyEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["XNOOK_CLAUDE_SMOKE"] == "1" else {
            throw XCTSkip("真实 Claude 烟雾需显式开启，日常测试不调用模型")
        }
        let executable = URL(fileURLWithPath: try XCTUnwrap(environment["XNOOK_CLAUDE_EXECUTABLE"]))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        let configuration = try XCTUnwrap(ClaudeHookConfiguration.json(script: Self.script, python: ClaudeHookConfiguration.preferredPython))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(configuration.utf8)) as? [String: Any])
        var hooks = try XCTUnwrap(root["hooks"] as? [String: [[String: Any]]])
        var group = try XCTUnwrap(hooks["Stop"]?.first)
        var command = try XCTUnwrap((group["hooks"] as? [[String: Any]])?.first)
        // socket 位于本测试生成的 ASCII/UUID 路径，配置仅供这次临时会话使用。
        command["command"] = try XCTUnwrap(command["command"] as? String) + " --socket '" + fixture.socket.path + "'"
        group["hooks"] = [command]
        hooks["Stop"] = [group]
        root["hooks"] = hooks
        let settings = fixture.directory.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: settings)
        var arguments = [
            "-p", "Reply with exactly XNOOK_CLAUDE_STOP_SMOKE_OK. Do not use tools.",
            "--settings", settings.path, "--setting-sources", "", "--tools", "",
            "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--disable-slash-commands",
            "--no-chrome", "--no-session-persistence", "--max-turns", "1", "--output-format", "stream-json",
            "--verbose", "--include-hook-events"
        ]
        if let model = environment["XNOOK_CLAUDE_MODEL"], !model.isEmpty { arguments += ["--model", model] }
        let exit = try await fixture.run(executable: executable, arguments: arguments, input: nil, logName: "claude", timeout: 90)
        await fixture.waitUntil { !fixture.presented.isEmpty }
        let stdout = try Data(contentsOf: fixture.directory.appendingPathComponent("claude.stdout"))
        let messages = String(decoding: stdout, as: UTF8.self).split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
        let completed = messages.contains { $0["type"] as? String == "result" && $0["is_error"] as? Bool == false
            && ($0["result"] as? String)?.contains("XNOOK_CLAUDE_STOP_SMOKE_OK") == true }
        let output = Self.evidence.appendingPathComponent("real-client")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // 原始 CLI 输出只留在忽略的本机证据目录，报告只写计数与布尔值。
        try stdout.write(to: output.appendingPathComponent("claude.stdout"))
        try Data(contentsOf: fixture.directory.appendingPathComponent("claude.stderr")).write(to: output.appendingPathComponent("claude.stderr"))
        var result: [String: Any] = ["cliExit": exit, "normalResult": completed,
            "nativeReceived": fixture.received.count, "coordinatorPresented": fixture.presented.count,
            "realAppWindow": false, "installedAppTouched": false, "clientHookConfigWritten": false]
        result["requestedModel"] = environment["XNOOK_CLAUDE_MODEL"] ?? "client-default"
        if let notice = fixture.presented.first {
            try Self.render(PanelActivitySummaryView(event: notice, onDismiss: {}, onAction: {}),
                size: NSSize(width: 500, height: 40), scheme: .dark, output: output.appendingPathComponent("notice.png"))
            result["offscreenNoticeRendered"] = true
        }
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("result.json"))
        XCTAssertEqual(exit, 0)
        XCTAssertTrue(completed, "应正常完成受控的单轮文本请求")
        XCTAssertEqual(fixture.received.count, 1)
        XCTAssertEqual(fixture.presented.count, 1)
    }

    private static var script: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/claude-stop-hook.py")
    }
    private static var evidence: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/mac-claude-events-evidence")
    }

    private static func render<Content: View>(_ content: Content, size: NSSize, scheme: ColorScheme, output: URL) throws {
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertFalse(window.isVisible)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output, options: .atomic)
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let socket: URL
        var received: [PanelActivityEvent] = []
        var presented: [PanelActivityEvent] = []
        lazy var coordinator = PanelActivityCoordinator(isPresentationAllowed: { true },
            onPresent: { [weak self] in self?.presented.append($0) })
        lazy var receiver = ClaudeCompletionReceiver(socketURL: socket) { [weak self] event in
            guard let self else { return }
            received.append(event)
            coordinator.enqueue(PanelActivityEvent(source: event.source, id: event.id, title: L10n.claudeResponseEnded,
                kind: event.kind, createdAt: event.createdAt, expiresAt: event.expiresAt))
        }

        init() throws {
            directory = URL(fileURLWithPath: "/tmp/xnook-claude-\(UUID().uuidString.prefix(8))", isDirectory: true)
            socket = directory.appendingPathComponent("receiver/claude.sock")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("work"), withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        func start() async throws {
            receiver.setEnabled(true)
            await waitUntil { receiver.state != .starting }
            XCTAssertEqual(receiver.state, .listening, receiver.lastError ?? "")
        }
        func waitUntil(_ predicate: () -> Bool) async {
            let deadline = Date().addingTimeInterval(2)
            while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        }
        func run(executable: URL, arguments: [String], input: Data?, logName: String, timeout: TimeInterval) async throws -> Int32 {
            let process = Process(), stdin = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = directory.appendingPathComponent("work")
            let stdout = directory.appendingPathComponent(logName + ".stdout")
            let stderr = directory.appendingPathComponent(logName + ".stderr")
            FileManager.default.createFile(atPath: stdout.path, contents: nil)
            FileManager.default.createFile(atPath: stderr.path, contents: nil)
            let out = try FileHandle(forWritingTo: stdout), err = try FileHandle(forWritingTo: stderr)
            defer { try? out.close(); try? err.close() }
            process.standardOutput = out
            process.standardError = err
            process.standardInput = stdin
            try process.run()
            defer { if process.isRunning { process.terminate() } }
            if let input { stdin.fileHandleForWriting.write(input) }
            try stdin.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning {
                process.terminate()
                let limit = Date().addingTimeInterval(2)
                while process.isRunning, Date() < limit { try await Task.sleep(for: .milliseconds(50)) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                while process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
                XCTFail("受控子进程超时")
            }
            return process.terminationStatus
        }
        func cleanup() {
            receiver.shutdown()
            coordinator.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
