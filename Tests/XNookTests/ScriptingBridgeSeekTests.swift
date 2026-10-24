import AppKit
import Carbon
import XCTest
@testable import XNook

final class ScriptingBridgeSeekTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_000)

    @MainActor
    func testInstalledMusicSeekScriptCompilesWithoutExecuting() throws {
        let dictionary = "/System/Applications/Music.app/Contents/Resources/com.apple.Music.sdef"
        guard FileManager.default.fileExists(atPath: dictionary) else {
            throw XCTSkip("没有安装 Music 脚本词典，不能验证生产定位脚本的术语语法")
        }
        let script = try XCTUnwrap(NSAppleScript(source: ScriptingBridgeHelper.seekScript(for: .music)))
        var error: NSDictionary?
        // 仅编译固定 handler；不调用 execute，也不构造或发送播放器命令。
        XCTAssertTrue(script.compileAndReturnError(&error), "Music seek script did not compile: \(String(describing: error))")
        XCTAssertTrue(script.isCompiled)
    }

    func testBothPlayersWriteOnceAndRequireSameSourcePositionReadback() async throws {
        for app in [ScriptingBridgeHelper.SupportedApp.music, .spotify] {
            let context = try seekContext(app: app)
            var writes = 0
            var reads = 0
            let result = await ScriptingBridgeHelper.seek(to: 75, context: context,
                isRunning: { $0 == app }, executeHandler: { script, source, arguments in
                    writes += 1
                    XCTAssertEqual(source, app)
                    XCTAssertEqual(script, ScriptingBridgeHelper.seekScript(for: app))
                    XCTAssertEqual(arguments.seconds, 75)
                    XCTAssertEqual(arguments.identity, context.identity)
                    return NSAppleEventDescriptor(boolean: true)
                }, execute: { _, source in
                    reads += 1
                    XCTAssertEqual(source, app)
                    return self.snapshot(app: app, position: 75)
                }, sleep: { _ in XCTFail("The first matching readback needs no retry") }, now: { self.date })
            guard case .confirmed(let value) = result else { return XCTFail("Expected confirmed readback") }
            XCTAssertEqual(value.position, 75)
            XCTAssertEqual(value.duration, 180)
            XCTAssertEqual(value.identity.source, app)
            XCTAssertEqual(writes, 1)
            XCTAssertEqual(reads, 1)
        }
    }

    func testSuccessfulScriptWithoutPositionChangeIsNotConfirmation() async throws {
        var writes = 0
        var reads = 0
        let result = await ScriptingBridgeHelper.seek(to: 75, context: try seekContext(),
            isRunning: { _ in true }, executeHandler: { _, _, _ in
                writes += 1
                return NSAppleEventDescriptor(boolean: true)
            }, execute: { _, _ in reads += 1; return self.snapshot(position: 12) },
            sleep: { _ in }, now: { self.date })
        assertFailure(result, .unconfirmed)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(reads, 2)
    }

    func testDelayedReadbackRetriesReadWithoutRepeatingWrite() async throws {
        var writes = 0
        var reads = 0
        let result = await ScriptingBridgeHelper.seek(to: 75, context: try seekContext(),
            isRunning: { _ in true }, executeHandler: { _, _, _ in
                writes += 1
                return NSAppleEventDescriptor(boolean: true)
            }, execute: { _, _ in reads += 1; return self.snapshot(position: reads == 1 ? 12 : 75) },
            sleep: { _ in }, now: { self.date })
        guard case .confirmed = result else { return XCTFail("Expected delayed confirmation") }
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(reads, 2)
    }

    func testWrongTrackAndMissingReadbackNeverConfirm() async throws {
        for response in [snapshot(position: 75, id: "another-track"), NSAppleEventDescriptor.null()] {
            let result = await ScriptingBridgeHelper.seek(to: 75, context: try seekContext(),
                isRunning: { _ in true }, executeHandler: { _, _, _ in NSAppleEventDescriptor(boolean: true) },
                execute: { _, _ in response }, sleep: { _ in }, now: { self.date })
            if response.descriptorType == typeAEList { assertFailure(result, .trackChanged) }
            else { assertFailure(result, .unconfirmed) }
        }
    }

    func testRejectedIdentityAndScriptErrorNeverProceedToReadback() async throws {
        for reply in [NSAppleEventDescriptor(boolean: false), NSAppleEventDescriptor.null()] {
            let result = await ScriptingBridgeHelper.seek(to: 75, context: try seekContext(),
                isRunning: { _ in true }, executeHandler: { _, _, _ in reply },
                execute: { _, _ in XCTFail("Rejected command must not be confirmed"); return nil })
            assertFailure(result, reply.descriptorType == typeBoolean ? .trackChanged : .commandFailed)
        }
    }

    func testInvalidTargetAndClosedPlayerNeverExecuteScript() async throws {
        for target in [Double.nan, .infinity, -1] {
            let result = await ScriptingBridgeHelper.seek(to: target, context: try seekContext(),
                isRunning: { _ in true }, executeHandler: { _, _, _ in XCTFail("Invalid target"); return nil },
                execute: { _, _ in XCTFail("Invalid target"); return nil })
            assertFailure(result, .unavailable)
        }
        let closed = await ScriptingBridgeHelper.seek(to: 75, context: try seekContext(),
            isRunning: { _ in false }, executeHandler: { _, _, _ in XCTFail("Must not launch player"); return nil },
            execute: { _, _ in XCTFail("Must not launch player"); return nil })
        assertFailure(closed, .unavailable)
    }

    func testParametersAreDescriptorsAndScriptCacheKeyDoesNotContainTrackTextOrPosition() throws {
        let text = "track\"\nset player position to 999"
        let identity = try XCTUnwrap(MediaTrackIdentity(info: ["source": "Music", "trackID": text,
            "title": text, "artist": text, "album": text]))
        let event = ScriptingBridgeHelper.seekEvent(seconds: 77.25, identity: identity)
        let arguments = try XCTUnwrap(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
        XCTAssertEqual(arguments.numberOfItems, 5)
        XCTAssertEqual(arguments.atIndex(1)?.descriptorType, typeIEEE64BitFloatingPoint)
        XCTAssertEqual(arguments.atIndex(1)?.doubleValue, 77.25)
        for index in 2...5 { XCTAssertEqual(arguments.atIndex(index)?.stringValue, text) }
        let script = ScriptingBridgeHelper.seekScript(for: .music)
        XCTAssertFalse(script.contains(text))
        XCTAssertFalse(script.contains("77.25"))
        XCTAssertTrue(script.contains("with timeout of 2 seconds"))
        XCTAssertTrue(script.contains("persistent ID"))
        XCTAssertTrue(ScriptingBridgeHelper.seekScript(for: .spotify).contains(" / 1000"))
    }

    func testSnapshotKeepsLegacyRepliesAndOnlyNewRepliesEnableTrackIdentity() throws {
        let descriptor = snapshot(position: 12)
        XCTAssertNotNil(ScriptingBridgeHelper.parseSnapshot(descriptor, from: .music)?["trackID"])
        descriptor.remove(at: 7)
        let legacy = try XCTUnwrap(ScriptingBridgeHelper.parseSnapshot(descriptor, from: .music))
        XCTAssertEqual(legacy["playerPosition"] as? Double, 12)
        XCTAssertNil(legacy["trackID"])
        XCTAssertNil(MediaTrackIdentity(info: legacy))
    }

    private func seekContext(app: ScriptingBridgeHelper.SupportedApp = .music) throws -> MediaSeekContext {
        let info = try XCTUnwrap(ScriptingBridgeHelper.parseSnapshot(snapshot(app: app, position: 12), from: app, sampledAt: date))
        return MediaSeekContext(identity: try XCTUnwrap(MediaTrackIdentity(info: info)), generation: 1, duration: 180)
    }

    private func snapshot(app: ScriptingBridgeHelper.SupportedApp = .music, position: Double, id: String = "track-id") -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        let values = [NSAppleEventDescriptor(string: "Song"), NSAppleEventDescriptor(string: "Artist"),
            NSAppleEventDescriptor(string: "Album"), NSAppleEventDescriptor(double: app == .spotify ? 180_000 : 180),
            NSAppleEventDescriptor(double: 0), NSAppleEventDescriptor(double: position), NSAppleEventDescriptor(string: id)]
        for (index, value) in values.enumerated() { list.insert(value, at: index + 1) }
        return list
    }

    private func assertFailure(_ result: MediaSeekResult, _ failure: MediaSeekFailure, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failed(let actual) = result else { return XCTFail("Unexpected confirmation", file: file, line: line) }
        XCTAssertEqual(actual, failure, file: file, line: line)
    }
}
