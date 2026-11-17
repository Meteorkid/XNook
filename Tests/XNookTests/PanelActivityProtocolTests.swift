import Foundation
import XCTest
@testable import XNook

final class PanelActivityProtocolTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testSuccessAndFailureMapToLocalKindsWithoutActions() throws {
        for (result, kind) in [("success", PanelActivityEvent.Kind.completion), ("failure", .failure)] {
            let event = try decode(["result": result])
            XCTAssertEqual(event.source, "local-agent")
            XCTAssertEqual(event.id, "run-123")
            XCTAssertEqual(event.title, "任务已完成")
            XCTAssertEqual(event.kind, kind)
            XCTAssertEqual(event.createdAt, now)
            XCTAssertEqual(event.expiresAt, now.addingTimeInterval(60))
            XCTAssertEqual(event.action, .none)
        }
    }

    func testWhitespaceIsTrimmedAndFractionalISO8601DatesAreAccepted() throws {
        let event = try decode([
            "source": " local-agent\n", "id": " run-123 ", "title": "\n任务已完成 ",
            "createdAt": "2023-11-14T22:13:20.000Z"
        ])
        XCTAssertEqual(event.source, "local-agent")
        XCTAssertEqual(event.id, "run-123")
        XCTAssertEqual(event.title, "任务已完成")
        XCTAssertEqual(event.createdAt, now)
    }

    func testUnknownVersionSourceAndResultAreRejected() {
        let overrides: [[String: Any]] = [
            ["version": 2], ["version": "1"], ["source": "untrusted"],
            ["result": "running"], ["result": "Success"]
        ]
        for override in overrides {
            XCTAssertThrowsError(try decode(override))
        }
    }

    func testExternalActionsCommandsAndUnknownFieldsAreRejected() {
        let overrides: [[String: Any]] = [
            ["action": "openCalendar"], ["action": NSNull()],
            ["command": "open -a Calendar"], ["url": "xnook://show"],
            ["action": ["type": "shell", "command": "anything"]]
        ]
        for override in overrides {
            XCTAssertThrowsError(try decode(override))
        }
    }

    func testBlankAndOverlongStringsAreRejected() {
        let overrides: [[String: Any]] = [
            ["source": " "], ["id": "\n"], ["title": "\t "],
            ["source": String(repeating: "s", count: 65)],
            ["id": String(repeating: "i", count: 129)],
            ["title": String(repeating: "字", count: 161)]
        ]
        for override in overrides {
            XCTAssertThrowsError(try decode(override))
        }
        XCTAssertNoThrow(try decode(["id": String(repeating: "i", count: 128), "title": String(repeating: "字", count: 160)]))
    }

    func testExpiredAndFutureDatesUseExactBoundaries() {
        XCTAssertThrowsError(try decode(["createdAt": timestamp(now.addingTimeInterval(-60))]))
        XCTAssertNoThrow(try decode(["createdAt": timestamp(now.addingTimeInterval(-59))]))
        XCTAssertNoThrow(try decode(["createdAt": timestamp(now.addingTimeInterval(5))]))
        XCTAssertThrowsError(try decode(["createdAt": timestamp(now.addingTimeInterval(6))]))
        for value in ["not-a-date", "", "2023-99-99T99:99:99Z"] {
            XCTAssertThrowsError(try decode(["createdAt": value]))
        }
    }

    func testOversizedInputIsRejectedBeforeJSONDecoding() throws {
        let valid = try payload()
        let atLimit = valid + Data(repeating: 0x20, count: 64 * 1_024 - valid.count)
        XCTAssertNoThrow(try PanelActivityEnvelope.decode(atLimit, allowedSources: ["local-agent"], now: now))
        XCTAssertThrowsError(try PanelActivityEnvelope.decode(atLimit + Data([0x20]), allowedSources: ["local-agent"], now: now)) {
            XCTAssertEqual($0 as? PanelActivityEnvelope.DecodeError, .tooLarge)
        }
    }

    func testMalformedMissingAndWrongTypedFieldsAreRejected() throws {
        for data in [Data(), Data("not json".utf8), Data("[]".utf8), Data("{}".utf8)] {
            XCTAssertThrowsError(try PanelActivityEnvelope.decode(data, allowedSources: ["local-agent"], now: now))
        }
        for key in ["version", "source", "id", "title", "result", "createdAt"] {
            XCTAssertThrowsError(try decode([key: NSNull()]))
        }
        XCTAssertThrowsError(try decode(["title": 123]))
        XCTAssertThrowsError(try PanelActivityEnvelope.decode(payload(), allowedSources: [], now: now))
    }

    private func decode(_ overrides: [String: Any] = [:]) throws -> PanelActivityEvent {
        try PanelActivityEnvelope.decode(payload(overrides), allowedSources: ["local-agent"], now: now)
    }

    private func payload(_ overrides: [String: Any] = [:]) throws -> Data {
        var values: [String: Any] = [
            "version": 1, "source": "local-agent", "id": "run-123", "title": "任务已完成",
            "result": "success", "createdAt": timestamp(now)
        ]
        values.merge(overrides) { _, replacement in replacement }
        return try JSONSerialization.data(withJSONObject: values)
    }

    private func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
