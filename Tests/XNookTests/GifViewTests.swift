import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import XNook

@MainActor
final class GifViewTests: XCTestCase {
    func testSetupShowsFirstFrameWithoutStartingRefresh() throws {
        let fixture = Fixture()
        fixture.coordinator.setupAnimation(gifData: try makeGIF(), imageView: fixture.imageView)

        XCTAssertNotNil(fixture.imageView.image)
        XCTAssertTrue(fixture.drivers.isEmpty)
    }

    func testRepeatedResumeDoesNotResetFrameClock() throws {
        let fixture = try playingFixture()
        let firstFrame = fixture.imageView.image
        fixture.now = 0.08
        fixture.coordinator.resumeAnimation()
        fixture.now = 0.11
        fixture.drivers[0].fire()

        XCTAssertEqual(fixture.drivers.count, 1)
        XCTAssertEqual(fixture.drivers[0].resumeCount, 1)
        XCTAssertFalse(fixture.imageView.image === firstFrame)
    }

    func testPauseStopsRefreshAndIgnoresPendingTick() throws {
        let fixture = try playingFixture()
        let firstFrame = fixture.imageView.image
        fixture.coordinator.pauseAnimation()
        fixture.now = 10
        fixture.drivers[0].fire()

        XCTAssertEqual(fixture.drivers[0].pauseCount, 1)
        XCTAssertTrue(fixture.imageView.image === firstFrame)
    }

    func testResumeAfterPauseStartsNewFrameInterval() throws {
        let fixture = try playingFixture()
        let firstFrame = fixture.imageView.image
        fixture.coordinator.pauseAnimation()
        fixture.now = 10
        fixture.coordinator.resumeAnimation()
        fixture.now = 10.01
        fixture.drivers[0].fire()
        XCTAssertTrue(fixture.imageView.image === firstFrame)

        fixture.now = 10.11
        fixture.drivers[0].fire()
        XCTAssertFalse(fixture.imageView.image === firstFrame)
        XCTAssertEqual(fixture.drivers[0].resumeCount, 2)
    }

    func testDismantleInvalidatesAndCannotRestart() throws {
        let fixture = try playingFixture()
        let firstFrame = fixture.imageView.image
        GifView.dismantleNSView(fixture.imageView, coordinator: fixture.coordinator)
        fixture.coordinator.resumeAnimation()
        fixture.coordinator.setupAnimation(gifData: try makeGIF(), imageView: fixture.imageView)
        fixture.now = 10
        fixture.drivers[0].fire()

        XCTAssertTrue(fixture.drivers[0].isInvalidated)
        XCTAssertEqual(fixture.drivers.count, 1)
        XCTAssertNil(fixture.coordinator.currentGifData)
        XCTAssertTrue(fixture.imageView.image === firstFrame)
    }

    func testCoordinatorIsReleasedWhileDisplayDriverStillExists() throws {
        var driver: FakeDisplayLink?
        var coordinator: GifView.Coordinator? = GifView.Coordinator(
            displayLinkFactory: { _, callback in
                let link = FakeDisplayLink(callback: callback)
                driver = link
                return link
            }
        )
        let imageView = NSImageView()
        coordinator?.setupAnimation(gifData: try makeGIF(), imageView: imageView)
        coordinator?.resumeAnimation()
        weak var weakCoordinator = coordinator
        coordinator = nil

        XCTAssertNil(weakCoordinator)
        XCTAssertEqual(driver?.isInvalidated, true)
        driver?.fire()
    }

    func testReplacingPlayingGIFResetsFrameAndRejectsOldCallback() throws {
        let fixture = try playingFixture(frameCount: 3)
        fixture.now = 0.11
        fixture.drivers[0].fire()
        fixture.now = 0.22
        fixture.drivers[0].fire()
        fixture.coordinator.setupAnimation(gifData: try makeGIF(), imageView: fixture.imageView)
        let replacementFirstFrame = fixture.imageView.image

        XCTAssertTrue(fixture.drivers[0].isInvalidated)
        XCTAssertEqual(fixture.drivers.count, 2)
        fixture.now = 0.33
        fixture.drivers[0].fire()
        XCTAssertTrue(fixture.imageView.image === replacementFirstFrame)

        fixture.drivers[1].fire()
        XCTAssertFalse(fixture.imageView.image === replacementFirstFrame)
    }

    func testReplacingPausedGIFDoesNotStartUntilResumed() throws {
        let fixture = try playingFixture()
        fixture.coordinator.pauseAnimation()
        fixture.coordinator.setupAnimation(gifData: try makeGIF(frameCount: 3), imageView: fixture.imageView)

        XCTAssertTrue(fixture.drivers[0].isInvalidated)
        XCTAssertEqual(fixture.drivers.count, 1)
        fixture.coordinator.resumeAnimation()
        XCTAssertEqual(fixture.drivers.count, 2)
    }

    func testReplacingAnimationWithStillOrInvalidDataClearsAnimationState() throws {
        for replacement in [try makeGIF(frameCount: 1), Data([0, 1, 2])] {
            let fixture = try playingFixture()
            fixture.coordinator.setupAnimation(gifData: replacement, imageView: fixture.imageView)
            let replacementImage = fixture.imageView.image
            fixture.coordinator.resumeAnimation()
            fixture.now = 10
            fixture.drivers[0].fire()

            XCTAssertTrue(fixture.drivers[0].isInvalidated)
            XCTAssertEqual(fixture.drivers.count, 1)
            XCTAssertTrue(fixture.imageView.image === replacementImage)
        }
    }

    func testDirectDataCannotBypassResourceBudgetsOrFallBackToNSImage() throws {
        for data in [makeBudgetGIF(frameCount: 2_001), makeBudgetGIF(width: 2_049),
                     makeBudgetGIF(width: 2_048, height: 2_048, frameCount: 17), Data(count: GifResource.maximumEncodedBytes + 1)] {
            let fixture = try playingFixture()
            fixture.coordinator.setupAnimation(gifData: data, imageView: fixture.imageView)
            fixture.coordinator.resumeAnimation()
            fixture.now = 10
            fixture.drivers[0].fire()
            XCTAssertNil(fixture.imageView.image)
            XCTAssertTrue(fixture.drivers[0].isInvalidated)
            XCTAssertEqual(fixture.drivers.count, 1)
        }
    }

    func testSingleTransparentGIFShowsWithoutAnimation() {
        let fixture = Fixture()
        fixture.coordinator.setupAnimation(gifData: makeBudgetGIF(), imageView: fixture.imageView)
        fixture.coordinator.resumeAnimation()
        XCTAssertNotNil(fixture.imageView.image)
        XCTAssertTrue(fixture.drivers.isEmpty)
    }

    func testInvalidReplacementClearsDisplayedImageAndCannotRestartOldDriver() throws {
        let fixture = try playingFixture()
        fixture.coordinator.setupAnimation(gifData: Data("GIF89a truncated".utf8), imageView: fixture.imageView)
        fixture.coordinator.resumeAnimation()
        fixture.now = 10
        fixture.drivers[0].fire()

        XCTAssertNil(fixture.imageView.image)
        XCTAssertTrue(fixture.drivers[0].isInvalidated)
        XCTAssertEqual(fixture.drivers.count, 1)
    }

    func testNonGIFDataIsNotDecodedThroughStillImageFallback() throws {
        let gifSource = try XCTUnwrap(CGImageSourceCreateWithData(try makeGIF() as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(gifSource, 0, nil))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let fixture = Fixture()
        fixture.coordinator.setupAnimation(gifData: data as Data, imageView: fixture.imageView)

        XCTAssertNil(fixture.imageView.image)
        XCTAssertTrue(fixture.drivers.isEmpty)
    }

    private func playingFixture(frameCount: Int = 2) throws -> Fixture {
        let fixture = Fixture()
        fixture.coordinator.setupAnimation(gifData: try makeGIF(frameCount: frameCount), imageView: fixture.imageView)
        fixture.coordinator.resumeAnimation()
        return fixture
    }

    private func makeGIF(frameCount: Int = 2) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frameCount, nil))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for index in 0..<frameCount {
            context.setFillColor(CGColor(red: CGFloat(index % 2), green: CGFloat((index + 1) % 2), blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private final class Fixture {
    let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    var now: TimeInterval = 0
    var drivers: [FakeDisplayLink] = []
    lazy var coordinator = GifView.Coordinator(
        displayLinkFactory: { [unowned self] _, callback in
            let driver = FakeDisplayLink(callback: callback)
            drivers.append(driver)
            return driver
        },
        clock: { [unowned self] in now }
    )
}

private final class FakeDisplayLink: GifDisplayLinkDriving {
    private let callback: () -> Void
    private(set) var resumeCount = 0
    private(set) var pauseCount = 0
    private(set) var isInvalidated = false

    init(callback: @escaping () -> Void) { self.callback = callback }
    func resume() { resumeCount += 1 }
    func pause() { pauseCount += 1 }
    func invalidate() { isInvalidated = true }
    // 即使停止后也能送达一次回调，模拟已排队但尚未处理的刷新。
    func fire() { callback() }
}
