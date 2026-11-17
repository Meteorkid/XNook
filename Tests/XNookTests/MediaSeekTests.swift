import AppKit
import SwiftUI
import XCTest
@testable import XNook

@MainActor
final class MediaSeekTests: XCTestCase {
    func testDragPreviewDoesNotChangePlaybackAndReleaseCommitsOnce() async throws {
        let fixture = MediaSeekFixture()
        try await fixture.load()
        var interaction = MediaSeekInteraction()
        interaction.begin(context: fixture.media.seekContext, elapsedTime: fixture.media.elapsedTime)
        for target in [20.0, 50, 75] { interaction.update(to: target, currentContext: fixture.media.seekContext) }
        XCTAssertEqual(interaction.previewTime, 75)
        XCTAssertEqual(fixture.media.elapsedTime, 12)
        XCTAssertEqual(fixture.media.currentLyricLine, "Early")
        XCTAssertTrue(fixture.seeks.isEmpty)
        let request = try XCTUnwrap(interaction.finish(currentContext: fixture.media.seekContext))
        let task = try XCTUnwrap(fixture.media.seek(to: request.seconds, context: request.context))
        XCTAssertNil(interaction.finish(currentContext: fixture.media.seekContext))
        await task.value
        XCTAssertEqual(fixture.seeks, [75])
        XCTAssertEqual(fixture.media.elapsedTime, 75)
        XCTAssertEqual(fixture.media.currentLyricLine, "Late")
        XCTAssertFalse(fixture.media.isPlaying, "Paused seek must not issue play or pause")
        XCTAssertTrue(fixture.commands.isEmpty)
        XCTAssertEqual(fixture.cacheReads, 1)
        XCTAssertEqual(fixture.lyricRequests, 0)
    }

    func testConfirmedSeekKeepsGlobalLyricsOffsetAndArtwork() async throws {
        let fixture = MediaSeekFixture()
        try await fixture.load()
        fixture.lyrics.lyricsOffset = 5
        let artwork = Data([1, 2, 3])
        fixture.media.currentArtworkData = artwork
        let task = try XCTUnwrap(fixture.media.seek(to: 62, context: try XCTUnwrap(fixture.media.seekContext)))
        await task.value
        XCTAssertEqual(fixture.media.elapsedTime, 62)
        XCTAssertEqual(fixture.lyrics.lyricsOffset, 5)
        XCTAssertEqual(fixture.media.currentLyricLine, "Early")
        XCTAssertEqual(fixture.media.currentArtworkData, artwork)
        XCTAssertEqual(fixture.cacheReads, 1)
        XCTAssertEqual(fixture.lyricRequests, 0)
    }

    func testMissingIdentityUnknownDurationAndInvalidTargetCannotSeek() async throws {
        let fixture = MediaSeekFixture()
        fixture.snapshot.removeValue(forKey: "trackID")
        try await fixture.load()
        XCTAssertNil(fixture.media.seekContext)
        fixture.snapshot["trackID"] = "track-a"
        fixture.snapshot["duration"] = 0.0
        await fixture.media.refreshNowPlayingInfo()
        XCTAssertNil(fixture.media.seekContext)
        fixture.snapshot["duration"] = 180.0
        await fixture.media.refreshNowPlayingInfo()
        let context = try XCTUnwrap(fixture.media.seekContext)
        for seconds in [Double.nan, .infinity, -1] {
            XCTAssertNil(fixture.media.seek(to: seconds, context: context))
        }
        XCTAssertTrue(fixture.seeks.isEmpty)
    }

    func testTargetsAreClampedToDuration() async throws {
        let fixture = MediaSeekFixture()
        try await fixture.load()
        let task = try XCTUnwrap(fixture.media.seek(to: 999, context: try XCTUnwrap(fixture.media.seekContext)))
        await task.value
        XCTAssertEqual(fixture.seeks, [180])
        XCTAssertEqual(fixture.media.elapsedTime, 180)
    }

    func testFailedAndUnconfirmedResultsNeverWritePreviewIntoProgress() async throws {
        for failure in [MediaSeekFailure.commandFailed, .unconfirmed] {
            let fixture = MediaSeekFixture()
            try await fixture.load()
            fixture.resolveSeek = { _, _ in .failed(failure) }
            let task = try XCTUnwrap(fixture.media.seek(to: 75, context: try XCTUnwrap(fixture.media.seekContext)))
            XCTAssertEqual(fixture.media.seekStatus, .pending(75))
            XCTAssertEqual(fixture.media.elapsedTime, 12)
            await task.value
            XCTAssertEqual(fixture.media.seekStatus, .failed(failure))
            XCTAssertEqual(fixture.media.elapsedTime, 12)
            XCTAssertEqual(fixture.media.currentLyricLine, "Early")
        }
    }

    func testMalformedConfirmationIsNotTrustedByManager() async throws {
        let fixture = MediaSeekFixture()
        try await fixture.load()
        fixture.resolveSeek = { [unowned fixture] _, _ in .confirmed(fixture.confirmation(position: 20)) }
        let task = try XCTUnwrap(fixture.media.seek(to: 75, context: try XCTUnwrap(fixture.media.seekContext)))
        await task.value
        XCTAssertEqual(fixture.media.seekStatus, .failed(.unconfirmed))
        XCTAssertEqual(fixture.media.elapsedTime, 12)
    }

    func testCancelledDragAndChangedTrackContextNeverCommit() async throws {
        let fixture = MediaSeekFixture()
        try await fixture.load()
        var interaction = MediaSeekInteraction()
        interaction.begin(context: fixture.media.seekContext, elapsedTime: 12)
        interaction.update(to: 75, currentContext: fixture.media.seekContext)
        interaction.cancel()
        XCTAssertNil(interaction.finish(currentContext: fixture.media.seekContext))
        interaction.begin(context: fixture.media.seekContext, elapsedTime: 12)
        fixture.snapshot["trackID"] = "track-b"
        await fixture.media.refreshNowPlayingInfo()
        interaction.invalidate()
        XCTAssertTrue(interaction.isEditing)
        interaction.update(to: 80, currentContext: fixture.media.seekContext)
        XCTAssertNil(interaction.previewTime)
        XCTAssertNil(interaction.finish(currentContext: fixture.media.seekContext))
        XCTAssertTrue(fixture.seeks.isEmpty)
    }

    func testPauseAndHideInvalidatePendingConfirmation() async throws {
        for pause in [true, false] {
            let fixture = MediaSeekFixture()
            try await fixture.load()
            let started = expectation(description: "Seek started")
            let gate = MediaSeekGate()
            fixture.resolveSeek = { [unowned fixture] _, _ in
                started.fulfill()
                await gate.wait()
                return .confirmed(fixture.confirmation(position: 75, rate: 1))
            }
            let task = try XCTUnwrap(fixture.media.seek(to: 75, context: try XCTUnwrap(fixture.media.seekContext)))
            await fulfillment(of: [started], timeout: 1)
            if pause { fixture.media.pause() } else { fixture.media.cancelSeek() }
            await gate.release()
            await task.value
            XCTAssertEqual(fixture.media.seekStatus, .idle)
            XCTAssertEqual(fixture.media.elapsedTime, 12)
            XCTAssertFalse(fixture.media.isPlaying)
            XCTAssertEqual(fixture.commands, pause ? [.pause] : [])
        }
    }

    func testEscapeOrTemporaryHideInvalidatesDragUntilReleaseAndNextGestureWorks() async throws {
        let fixture = MediaSeekFixture()
        try await fixture.load()
        var interaction = MediaSeekInteraction()
        interaction.begin(context: fixture.media.seekContext, elapsedTime: 12)
        interaction.update(to: 75, currentContext: fixture.media.seekContext)

        // Escape 或暂时隐藏后鼠标尚未松开，Binding 不能把后续移动视为新手势。
        interaction.invalidate()
        fixture.media.cancelSeek()
        XCTAssertTrue(interaction.isEditing)
        interaction.update(to: 85, currentContext: fixture.media.seekContext)
        XCTAssertNil(interaction.previewTime)
        XCTAssertNil(interaction.finish(currentContext: fixture.media.seekContext))
        XCTAssertFalse(interaction.isEditing)
        XCTAssertTrue(fixture.seeks.isEmpty)
        XCTAssertEqual(fixture.media.elapsedTime, 12)

        interaction.begin(context: fixture.media.seekContext, elapsedTime: 12)
        interaction.update(to: 60, currentContext: fixture.media.seekContext)
        let request = try XCTUnwrap(interaction.finish(currentContext: fixture.media.seekContext))
        let task = try XCTUnwrap(fixture.media.seek(to: request.seconds, context: request.context))
        await task.value
        XCTAssertEqual(fixture.seeks, [60])
        XCTAssertEqual(fixture.media.elapsedTime, 60)
    }

    func testSameNamedDifferentTrackAndDifferentSourceRejectPendingResult() async throws {
        for changesSource in [false, true] {
            let fixture = MediaSeekFixture()
            try await fixture.load()
            let original = fixture.confirmation(position: 75)
            let started = expectation(description: "Seek started")
            let gate = MediaSeekGate()
            fixture.resolveSeek = { _, _ in started.fulfill(); await gate.wait(); return .confirmed(original) }
            let task = try XCTUnwrap(fixture.media.seek(to: 75, context: try XCTUnwrap(fixture.media.seekContext)))
            await fulfillment(of: [started], timeout: 1)
            if changesSource { fixture.snapshot["source"] = "Spotify" }
            else { fixture.snapshot["trackID"] = "track-b" }
            fixture.snapshot["playerPosition"] = 3.0
            await fixture.media.refreshNowPlayingInfo()
            await gate.release()
            await task.value
            XCTAssertEqual(fixture.media.elapsedTime, 3)
            XCTAssertEqual(fixture.media.seekStatus, .idle)
        }
    }

    func testLateQueriesFromBeforeAndDuringSeekCannotOverwriteConfirmation() async throws {
        for queryStartsDuringSeek in [false, true] {
            let fixture = MediaSeekFixture()
            try await fixture.load()
            let queryStarted = expectation(description: "Query started")
            let seekStarted = expectation(description: "Seek started")
            let queryGate = MediaSeekGate()
            let seekGate = MediaSeekGate()
            let oldSnapshot = fixture.snapshot
            fixture.loadInfo = { queryStarted.fulfill(); await queryGate.wait(); return oldSnapshot }
            fixture.resolveSeek = { [unowned fixture] _, _ in
                seekStarted.fulfill()
                await seekGate.wait()
                return .confirmed(fixture.confirmation(position: 75))
            }
            let context = try XCTUnwrap(fixture.media.seekContext)
            let query: Task<Void, Never>
            let seek: Task<Void, Never>
            if queryStartsDuringSeek {
                seek = try XCTUnwrap(fixture.media.seek(to: 75, context: context))
                await fulfillment(of: [seekStarted], timeout: 1)
                query = Task { await fixture.media.refreshNowPlayingInfo() }
                await fulfillment(of: [queryStarted], timeout: 1)
            } else {
                query = Task { await fixture.media.refreshNowPlayingInfo() }
                await fulfillment(of: [queryStarted], timeout: 1)
                seek = try XCTUnwrap(fixture.media.seek(to: 75, context: context))
                await fulfillment(of: [seekStarted], timeout: 1)
            }
            await seekGate.release()
            await seek.value
            await queryGate.release()
            await query.value
            XCTAssertEqual(fixture.media.elapsedTime, 75)
            XCTAssertEqual(fixture.media.currentLyricLine, "Late")
        }
    }

    func testDuplicateCommitAndOldContextDoNotDispatchAgain() async throws {
        let fixture = MediaSeekFixture()
        try await fixture.load()
        let context = try XCTUnwrap(fixture.media.seekContext)
        let task = try XCTUnwrap(fixture.media.seek(to: 75, context: context))
        XCTAssertNil(fixture.media.seek(to: 80, context: context))
        await task.value
        XCTAssertNil(fixture.media.seek(to: 80, context: context))
        XCTAssertEqual(fixture.seeks, [75])
        XCTAssertEqual(fixture.media.elapsedTime, 75)
    }
}

@MainActor
final class MediaSeekViewTests: XCTestCase {
    func testNativeSliderActionCommitsExactlyOneSeek() async throws {
        try await probeSliderAction(useAccessibilityIncrement: false)
    }

    func testAccessibilitySliderIncrementCommitsExactlyOneSeek() async throws {
        try await probeSliderAction(useAccessibilityIncrement: true)
    }

    private func probeSliderAction(useAccessibilityIncrement: Bool) async throws {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else { throw XCTSkip("需要隔离媒体交互宿主") }
        _ = NSApplication.shared
        let fixture = MediaSeekFixture()
        try await fixture.load()
        let state = MediaSeekViewState()
        let host = NSHostingView(rootView: MediaSeekPreview(media: fixture.media, defaults: fixture.defaults, state: state))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 420, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        settle(host)
        XCTAssertNotNil(state.frames["mediaWidgetSeekSlider"])

        let method: String
        if useAccessibilityIncrement {
            guard let slider = accessibilityElements(in: host).first(where: {
                $0.accessibilityRole() == .slider && $0.accessibilityIdentifier() == "mediaWidgetSeekSlider"
            }) ?? accessibilityElements(in: host).first(where: { $0.accessibilityRole() == .slider }) else {
                throw XCTSkip("离屏生产视图未暴露辅助功能滑块入口，不能据此声称 AX 定位通过")
            }
            XCTAssertTrue(slider.isAccessibilityEnabled())
            guard slider.accessibilityPerformIncrement() else {
                throw XCTSkip("离屏滑块未提供辅助功能增量动作，不能据此声称 AX 定位通过")
            }
            method = "host-accessibilityPerformIncrement"
        } else {
            guard let slider = nativeControl(NSSlider.self, in: host) else {
                throw XCTSkip("离屏生产视图未暴露 NSSlider，不能据此声称原生定位交互通过")
            }
            XCTAssertTrue(slider.isEnabled)
            XCTAssertGreaterThan(slider.maxValue, slider.minValue)
            slider.doubleValue = slider.minValue + (75 / fixture.media.duration) * (slider.maxValue - slider.minValue)
            XCTAssertTrue(slider.sendAction(slider.action, to: slider.target), "原生滑块动作应进入生产绑定")
            method = "NSSlider.doubleValue+sendAction"
        }

        for _ in 0..<200 {
            if !fixture.seeks.isEmpty && !fixture.media.seekStatus.isPending { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        settle(host)
        print("Media seek control probe: \(method), dispatched=\(fixture.seeks.count), elapsed=\(fixture.media.elapsedTime)")
        XCTAssertEqual(fixture.seeks.count, 1, "独立原生/AX动作必须提交一次定位，不能只更新预览")
        if let target = fixture.seeks.first {
            XCTAssertGreaterThan(target, 12)
            XCTAssertLessThanOrEqual(target, fixture.media.duration)
            if !useAccessibilityIncrement { XCTAssertEqual(target, 75, accuracy: 0.01) }
            XCTAssertEqual(fixture.media.elapsedTime, target, accuracy: 0.01)
        }
        XCTAssertTrue(fixture.commands.isEmpty)
        XCTAssertFalse(window.isVisible)
    }

    func testEnvironmentHideCancelsProductionViewPendingSeek() async throws {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else { throw XCTSkip("需要隔离媒体交互宿主") }
        _ = NSApplication.shared
        let fixture = MediaSeekFixture()
        try await fixture.load()
        let state = MediaSeekViewState()
        let host = NSHostingView(rootView: MediaSeekPreview(media: fixture.media, defaults: fixture.defaults, state: state))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 420, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        settle(host)
        XCTAssertNotNil(state.frames["mediaWidgetSeekSlider"])
        let gate = MediaSeekGate()
        let started = expectation(description: "Seek started")
        fixture.resolveSeek = { [unowned fixture] _, _ in started.fulfill(); await gate.wait(); return .confirmed(fixture.confirmation(position: 75)) }
        let task = try XCTUnwrap(fixture.media.seek(to: 75, context: try XCTUnwrap(fixture.media.seekContext)))
        await fulfillment(of: [started], timeout: 1)
        state.enabled = false
        settle(host)
        XCTAssertEqual(fixture.media.seekStatus, .idle)
        await gate.release()
        await task.value
        XCTAssertEqual(fixture.media.elapsedTime, 12)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(fixture.commands.isEmpty)
    }

    private func settle(_ view: NSView) {
        for _ in 0..<4 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    }

    private func nativeControl<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let control = view as? T { return control }
        return view.subviews.lazy.compactMap { self.nativeControl(type, in: $0) }.first
    }

    private func accessibilityElements(in view: NSView) -> [NSAccessibilityProtocol] {
        var result: [NSAccessibilityProtocol] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: AnyObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted,
                  let element = object as? NSAccessibilityProtocol else { return }
            result.append(element)
            for child in element.accessibilityChildren() ?? [] { visit(child as AnyObject) }
        }
        visit(view)
        return result
    }
}

@MainActor
private final class MediaSeekViewState: ObservableObject {
    @Published var enabled = true
    var frames: [String: CGRect] = [:]
}

@MainActor
private struct MediaSeekPreview: View {
    let media: MediaManager
    let defaults: UserDefaults
    @ObservedObject var state: MediaSeekViewState
    var body: some View {
        MediaWidgetView(mediaManager: media, isDetail: true)
            .frame(width: 420).fixedSize(horizontal: false, vertical: true)
            .frame(width: 420, height: 400, alignment: .top)
            .defaultAppStorage(defaults)
            .environment(\.mediaSeekInteractionEnabled, state.enabled)
            .environment(\.reportsExpandedPanelDebugGeometry, true)
            .coordinateSpace(name: "expandedPanelDebugGeometry")
            .onPreferenceChange(ExpandedPanelDebugGeometryKey.self) { state.frames = $0 }
    }
}

@MainActor
private final class MediaSeekFixture {
    let suite = "XNook.MediaSeek.\(UUID().uuidString)"
    let defaults: UserDefaults
    var date = Date(timeIntervalSince1970: 1_000)
    var snapshot: [String: Any]
    var seeks: [Double] = []
    var commands: [MediaRemoteCommand] = []
    var cacheReads = 0
    var lyricRequests = 0
    var loadInfo: (@MainActor () async -> [String: Any])?
    var resolveSeek: (@MainActor (Double, MediaSeekContext) async -> MediaSeekResult)?

    lazy var lyrics = LyricsManager(defaults: defaults, loadRequest: { [unowned self] _ in
        lyricRequests += 1
        throw URLError(.unsupportedURL)
    }, readCache: { [unowned self] _, _, _ in
        cacheReads += 1
        return LyricsCache.Entry(type: .synced, payload: "[00:00.00]Early\n[01:00.00]Late", fetchedAt: date, key: "test")
    }, writeCache: { _, _, _, _, _, _ in XCTFail("Seek must not write lyrics cache") })

    lazy var media = MediaManager(startMonitoring: false, defaults: defaults, lyricsManager: lyrics,
        infoProvider: { [unowned self] in await loadInfo?() ?? snapshot }, artworkProvider: { _ in nil },
        clock: { [unowned self] in date }, commandSender: { [unowned self] in commands.append($0) },
        seekProvider: { [unowned self] target, context in
            seeks.append(target)
            if let resolveSeek { return await resolveSeek(target, context) }
            return .confirmed(confirmation(position: target))
        })

    init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "showLyrics")
        snapshot = ["source": "Music", "trackID": "track-a", "title": "Song", "artist": "Artist", "album": "Album",
            "duration": 180.0, "playbackRate": 0.0, "playerPosition": 12.0,
            "positionTimestamp": Date(timeIntervalSince1970: 1_000)]
    }

    func load() async throws {
        await media.refreshNowPlayingInfo()
        for _ in 0..<200 {
            if !lyrics.isFetching { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(lyrics.isFetching)
    }

    func confirmation(position: Double, rate: Double = 0) -> MediaSeekConfirmation {
        var info = snapshot
        info["playerPosition"] = position
        info["playbackRate"] = rate
        info["positionTimestamp"] = date
        return MediaSeekConfirmation(info: info)!
    }

    deinit { defaults.removePersistentDomain(forName: suite) }
}

private actor MediaSeekGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
