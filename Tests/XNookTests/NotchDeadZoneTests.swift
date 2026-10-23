import XCTest
@testable import XNook

final class NotchDeadZoneTests: XCTestCase {

    func testNoneHasNoPresence() {
        XCTAssertFalse(NotchDeadZone.none.isPresent)
        XCTAssertEqual(NotchDeadZone.none.width, 0)
        XCTAssertEqual(NotchDeadZone.none.height, 0)
    }

    /// 无屏幕时应安全退回 none，不能崩。
    func testResolveWithoutScreenReturnsNone() {
        XCTAssertEqual(NotchDeadZone.resolve(for: nil as NSScreen?), .none)
    }

    /// 当前测试环境通常无物理刘海，推导结果应为 none；若有刘海则宽度必须为正。
    func testResolveForCurrentMainScreenIsConsistent() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("无可用屏幕")
        }
        let zone = NotchDeadZone.resolve(for: screen)
        if zone.isPresent {
            XCTAssertGreaterThan(zone.width, 0)
            XCTAssertGreaterThan(zone.height, 0)
            // 刘海横向比纵向宽
            XCTAssertGreaterThan(zone.width, zone.height)
        } else {
            XCTAssertEqual(zone.width, 0)
        }
    }

    func testResolveForNilWindowReturnsNone() {
        XCTAssertEqual(NotchDeadZone.resolve(for: nil as NSWindow?), .none)
    }

    /// 宽度按高度等比推导，便于在没有实机刘海时验证公式。
    func testWidthFollowsHeightRatio() {
        let height: CGFloat = 32
        XCTAssertEqual(height * NotchDeadZone.widthPerHeight, 200, accuracy: 0.001)
    }
}
