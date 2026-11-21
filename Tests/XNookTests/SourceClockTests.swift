import XCTest
@testable import XNook

/// 时间轴是字幕的「现在」——它一旦外推错，调度推进、到期清理、画面切换会一起错。
///
/// 这里锁死暂停语义：冻结后无论真实时间过去多久，源时间都必须停在原地；
/// 恢复后按冻结**前**的速率继续（1.5× 播客不能变回 1×），且不递增代次，
/// 否则已灌入的歌词会被当成换源重灌，暂停一下歌词全部闪一遍。
final class SourceClockTests: XCTestCase {

    private func makeClock(at position: TimeInterval, rate: Double = 1) -> SourceClock {
        let clock = SourceClock()
        clock.align(sourceTime: position, rate: rate, signature: "song")
        return clock
    }

    // MARK: - 冻结

    /// 冻结后源时间与宿主时钟无关：往后推 30 秒也不能动。
    func testFrozenClockIgnoresHostClock() {
        let clock = makeClock(at: 12.5)
        clock.freeze()
        let frozen = clock.sourceNow()

        let host = SourceClock.hostNow()
        XCTAssertEqual(clock.sourceTime(atHost: host), frozen, accuracy: 1e-6)
        XCTAssertEqual(clock.sourceTime(atHost: host + 30), frozen, accuracy: 1e-6)
    }

    /// 用户实际看到的现象：暂停后真实时间照走，字幕却继续往下推。
    func testFrozenClockDoesNotAdvanceInRealTime() {
        let clock = makeClock(at: 5)
        clock.freeze()
        let frozen = clock.sourceNow()

        Thread.sleep(forTimeInterval: 0.2)

        XCTAssertEqual(clock.sourceNow(), frozen, accuracy: 1e-6)
    }

    /// 冻结基准是「此刻的值」，不是对齐时留下的旧锚点——否则暂停瞬间歌词会往回跳。
    func testFreezeTakesTheCurrentValueAsBaseline() {
        let clock = makeClock(at: 5)
        Thread.sleep(forTimeInterval: 0.1)

        clock.freeze()

        XCTAssertEqual(clock.sourceNow(), 5.1, accuracy: 0.02)
    }

    /// 暂停回调可能重复到达（播放状态、定时器、媒体信息各来一次），重复冻结不能把时间轴往前挪。
    func testRepeatedFreezeKeepsTheTimelineStill() {
        let clock = makeClock(at: 8)
        clock.freeze()
        let frozen = clock.sourceNow()

        Thread.sleep(forTimeInterval: 0.1)
        clock.freeze()

        XCTAssertEqual(clock.sourceNow(), frozen, accuracy: 1e-6)
    }

    // MARK: - 恢复

    /// 恢复后从播放器上报的位置继续。
    func testThawResumesFromReportedPosition() {
        let clock = makeClock(at: 5)
        clock.freeze()
        clock.thaw(at: 5)

        let host = SourceClock.hostNow()
        XCTAssertEqual(clock.sourceTime(atHost: host + 2), 7, accuracy: 1e-3)
    }

    /// 暂停期间拖了进度条：恢复要跳到新位置，而不是接着冻结处慢慢追。
    func testThawHonoursSeekWhilePaused() {
        let clock = makeClock(at: 5)
        clock.freeze()
        clock.thaw(at: 120)

        XCTAssertEqual(clock.sourceNow(), 120, accuracy: 1e-3)
    }

    /// 速率要还原：播客 1.5× 暂停再播放，恢复后还得是 1.5×，否则字幕会越拖越晚。
    func testThawKeepsPlaybackRate() {
        let clock = makeClock(at: 0, rate: 1.5)
        clock.freeze()
        clock.thaw(at: 30)

        let host = SourceClock.hostNow()
        XCTAssertEqual(clock.sourceTime(atHost: host + 2), 33, accuracy: 1e-3)
    }

    /// 冻结不递增代次：已灌入的歌词条目仍然有效，不该被当成换源清掉。
    func testFreezeDoesNotAdvanceGeneration() {
        let clock = makeClock(at: 10)
        let before = clock.generation

        clock.freeze()
        clock.thaw(at: 10)

        XCTAssertEqual(clock.generation, before)
    }

    /// 冻结期间播放位置没动，恢复后重新对齐不能被判成 seek——那会清空调度器，字幕闪一下。
    func testAlignmentAfterThawIsNotTreatedAsJump() {
        let clock = makeClock(at: 60)
        clock.freeze()

        Thread.sleep(forTimeInterval: 0.1)
        clock.thaw(at: 60)

        XCTAssertFalse(clock.align(sourceTime: 60.1, rate: 1, signature: "song"))
    }
}
