import XCTest
@testable import XNook

@MainActor
final class MediaTimeFormattingTests: XCTestCase {
    func testInvalidPlayerTimesProduceUnknownTimeWithoutIntegerConversion() {
        let manager = MediaManager(startMonitoring: false)
        for time in [Double.nan, .infinity, -.infinity, -1, .greatestFiniteMagnitude, Double(Int.max)] {
            XCTAssertEqual(manager.formatTime(time), "--:--")
        }
    }

    func testLargeRepresentableTimesDoNotTruncateMinutesToThirtyTwoBits() {
        let manager = MediaManager(startMonitoring: false)
        let time = 128_849_018_940.0
        XCTAssertEqual(manager.formatTime(time), "2147483649:00")
    }
}
