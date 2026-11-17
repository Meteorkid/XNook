import XCTest
@testable import XNook

final class ClaudeHookConfigurationTests: XCTestCase {
    func testConfigurationContainsOnlyShortSynchronousStopHook() throws {
        let json = try XCTUnwrap(ClaudeHookConfiguration.json(script: URL(fileURLWithPath: "/Applications/X Nook.app/Contents/Resources/claude-stop-hook.py"),
            python: URL(fileURLWithPath: "/opt/homebrew/bin/python3.12")))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["hooks"])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(Set(hooks.keys), ["Stop"])
        let group = try XCTUnwrap(hooks["Stop"]?.first)
        let command = try XCTUnwrap((group["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(command.keys), ["type", "command", "timeout"])
        XCTAssertEqual(command["timeout"] as? Int, 3)
        XCTAssertEqual(command["type"] as? String, "command")
        XCTAssertNil(command["async"])
        XCTAssertFalse(SettingsDefaults.bool(for: "claudeCompletionEnabled", fallback: true))
    }

    func testQuotedApplicationPathSurvivesShellWithoutExpansion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("XNook Hook \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("hook's $(printf expanded).py")
        try Data("import json,sys\nprint(json.dumps(sys.argv[0]))\n".utf8).write(to: script)
        let json = try XCTUnwrap(ClaudeHookConfiguration.json(script: script, python: ClaudeHookConfiguration.preferredPython))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(value["hooks"] as? [String: [[String: Any]]])
        let command = try XCTUnwrap((hooks["Stop"]?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: bytes), script.path)
    }

    func testConfigurationRejectsNonFileScriptAndInterpreter() {
        let local = URL(fileURLWithPath: "/tmp/hook.py")
        let remote = URL(string: "https://example.com/hook.py")!
        XCTAssertNil(ClaudeHookConfiguration.json(script: remote, python: local))
        XCTAssertNil(ClaudeHookConfiguration.json(script: local, python: remote))
    }
}
