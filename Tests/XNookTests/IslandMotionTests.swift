import XCTest
@testable import XNook

final class IslandMotionTests: XCTestCase {

    func testTierBoundaries() {
        XCTAssertEqual(IslandMotion.tier(forScreenWidth: 1280), .compact)
        XCTAssertEqual(IslandMotion.tier(forScreenWidth: 1439), .compact)
        XCTAssertEqual(IslandMotion.tier(forScreenWidth: 1440), .regular)
        XCTAssertEqual(IslandMotion.tier(forScreenWidth: 1512), .regular)
        XCTAssertEqual(IslandMotion.tier(forScreenWidth: 1919), .regular)
        XCTAssertEqual(IslandMotion.tier(forScreenWidth: 1920), .large)
        XCTAssertEqual(IslandMotion.tier(forScreenWidth: 2560), .large)
    }

    /// 非有限或非正值不能崩溃，退回常规档。
    func testInvalidScreenWidthFallsBackToRegular() {
        XCTAssertEqual(IslandMotion.tier(forScreenWidth: 0), .regular)
        XCTAssertEqual(IslandMotion.tier(forScreenWidth: -100), .regular)
        XCTAssertEqual(IslandMotion.tier(forScreenWidth: .nan), .regular)
        XCTAssertEqual(IslandMotion.tier(forScreenWidth: .infinity), .regular)
    }

    /// 展开要保留回弹（阻尼明显低于临界），收起要几乎不过冲。
    func testExpandIsBouncierThanCollapseInEveryTier() {
        for tier in IslandMotion.Tier.allCases {
            let preset = IslandMotion.preset(for: tier)
            XCTAssertLessThan(
                preset.expand.dampingFraction, preset.collapse.dampingFraction,
                "\(tier) 档展开阻尼应低于收起阻尼"
            )
            XCTAssertLessThan(preset.expand.dampingFraction, 0.8, "\(tier) 档展开应保留可见回弹")
            XCTAssertGreaterThan(preset.collapse.dampingFraction, 0.9, "\(tier) 档收起应几乎不过冲")
        }
    }

    /// 响应时间随屏幕变大而变长：同样的时长在大屏上会显得急促。
    func testLargerScreenUsesLongerResponse() {
        XCTAssertLessThan(
            IslandMotion.compactPreset.expand.response,
            IslandMotion.regularPreset.expand.response
        )
        XCTAssertLessThan(
            IslandMotion.regularPreset.expand.response,
            IslandMotion.largePreset.expand.response
        )
    }

    /// 低阻尼尾部震荡更久，结算时长应比临界阻尼更长，否则看门狗会过早触发。
    func testSettleDurationGrowsWithLowerDamping() {
        let bouncy = IslandMotion.Spring(response: 0.4, dampingFraction: 0.55)
        let crisp = IslandMotion.Spring(response: 0.4, dampingFraction: 0.98)
        XCTAssertGreaterThan(
            IslandMotion.settleDuration(for: bouncy),
            IslandMotion.settleDuration(for: crisp)
        )
        XCTAssertGreaterThan(IslandMotion.settleDuration(for: bouncy), bouncy.response)
    }

    func testPresetForScreenWidthMatchesTierPreset() {
        XCTAssertEqual(
            IslandMotion.preset(forScreenWidth: 1512),
            IslandMotion.preset(for: .regular)
        )
        XCTAssertEqual(
            IslandMotion.preset(forScreenWidth: 2560),
            IslandMotion.preset(for: .large)
        )
    }
}
