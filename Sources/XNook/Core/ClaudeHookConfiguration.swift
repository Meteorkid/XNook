import Foundation

enum ClaudeHookConfiguration {
    static var preferredPython: URL {
        let paths = ["/opt/homebrew/bin/python3", "/opt/homebrew/bin/python3.14", "/opt/homebrew/bin/python3.13",
                     "/opt/homebrew/bin/python3.12", "/opt/homebrew/bin/python3.11", "/opt/homebrew/bin/python3.10"]
        return URL(fileURLWithPath: paths.first(where: FileManager.default.isExecutableFile(atPath:)) ?? "/usr/bin/python3")
    }

    static var bundledJSON: String? {
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("claude-stop-hook.py"),
              FileManager.default.isReadableFile(atPath: script.path) else { return nil }
        return json(script: script, python: preferredPython)
    }

    static func json(script: URL, python: URL) -> String? {
        guard script.isFileURL, python.isFileURL else { return nil }
        let command = shellQuote(python.path) + " " + shellQuote(script.path)
        let value: [String: Any] = ["hooks": ["Stop": [["hooks": [[
            "type": "command", "command": command, "timeout": 3
        ]]]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
