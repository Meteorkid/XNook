import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Darwin
@testable import XNook

final class GifResourceTests: XCTestCase {
    func testRejectsDirectoryAndNamedPipeBeforeReading() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try GifResource(contentsOf: directory))
        let pipe = directory.appendingPathComponent("input.gif")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        XCTAssertThrowsError(try GifResource(contentsOf: pipe))
    }
    func testAcceptsGIF87aGIF89aAndTransparentStill() throws {
        for version in ["GIF87a", "GIF89a"] {
            let resource = try GifResource(data: makeBudgetGIF(version: version))
            XCTAssertEqual(resource.frameCount, 1)
            let image = try resource.thumbnail()
            XCTAssertEqual(image.width, 1)
            XCTAssertEqual(image.height, 1)
        }
    }

    func testRejectsNonGIFEmptyAndTruncatedInput() {
        for data in [Data(), Data("not a GIF".utf8), Data(makeBudgetGIF().prefix(20))] {
            XCTAssertThrowsError(try GifResource(data: data))
        }
    }

    func testAcceptsCommentsApplicationExtensionAndLocalPalette() throws {
        var extended = makeBudgetGIF()
        extended.insert(contentsOf: [0x21, 0xfe, 3, 65, 66, 67, 0] +
                        [0x21, 0xff, 11] + Array("NETSCAPE2.0".utf8) + [3, 1, 0, 0, 0], at: 19)
        XCTAssertNotNil(try GifResource(data: extended).thumbnail())

        var local = Array(makeBudgetGIF())
        local[10] = 0
        local.removeSubrange(13..<19)
        local[30] = 0x80
        local.insert(contentsOf: [0, 0, 0, 255, 255, 255], at: 31)
        XCTAssertNotNil(try GifResource(data: Data(local)).thumbnail())
    }

    func testRejectsTruncatedBlocksMissingTrailerAndOversizedFrameOffsets() {
        var oversizedBlock = makeBudgetGIF()
        oversizedBlock[21] = 255
        var oversizedOffset = makeBudgetGIF()
        oversizedOffset[28] = 0
        oversizedOffset[29] = 8
        for data in [oversizedBlock, Data(makeBudgetGIF().dropLast()), oversizedOffset] {
            XCTAssertThrowsError(try GifResource(data: data))
        }
    }

    func testEncodedSizeAtAndAboveLimitForDataAndFile() throws {
        var data = makeBudgetGIF()
        data.append(Data(count: GifResource.maximumEncodedBytes - data.count))
        XCTAssertNoThrow(try GifResource(data: data))
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("limit.gif")
        try data.write(to: url)
        XCTAssertNoThrow(try GifResource(contentsOf: url))
        data.append(0)
        assertRejection(.encodedSize) { try GifResource(data: data) }
        try data.write(to: url)
        assertRejection(.encodedSize) { try GifResource(contentsOf: url) }
    }

    func testReaderBoundsEachReadAndRejectsGrowthAfterInitialChunks() throws {
        var requestedCounts: [Int] = []
        var remaining = GifResource.maximumEncodedBytes + 1
        assertRejection(.encodedSize) {
            try GifResource.readBoundedData { requested in
                requestedCounts.append(requested)
                let count = min(requested, remaining)
                remaining -= count
                return Data(count: count)
            }
        }
        XCTAssertEqual(requestedCounts.last, 1)
        XCTAssertTrue(requestedCounts.allSatisfy { $0 <= 64 * 1_024 })
        XCTAssertEqual(remaining, 0)

        var chunks = [Data([1]), Data([2, 3]), Data()]
        XCTAssertEqual(try GifResource.readBoundedData { _ in chunks.removeFirst() }, Data([1, 2, 3]))
    }

    func testDimensionLimitsAndZeroCanvas() throws {
        XCTAssertNoThrow(try GifResource(data: makeEncodedGIF(width: 2_048, height: 2_048)))
        for dimensions in [(2_049, 1), (1, 2_049), (0, 1), (1, 0)] {
            assertRejection(.dimensions) {
                try GifResource(data: makeBudgetGIF(width: dimensions.0, height: dimensions.1))
            }
        }
        XCTAssertThrowsError(try GifResource.validateBudget(width: .max, height: .max, frameCount: .max))
    }

    func testFrameCountAtAndAboveLimitIncludingOriginalTrigger() throws {
        XCTAssertEqual(try GifResource(data: makeBudgetGIF(frameCount: 500)).frameCount, 500)
        for count in [501, 2_001] {
            assertRejection(.frameCount) { try GifResource(data: makeBudgetGIF(frameCount: count)) }
        }
    }

    func testTotalPixelBudgetAtAndAboveLimit() throws {
        XCTAssertNoThrow(try GifResource(data: makeEncodedGIF(width: 2_048, height: 2_048, frameCount: 16)))
        assertRejection(.totalPixels) {
            try GifResource(data: makeBudgetGIF(width: 2_048, height: 2_048, frameCount: 17))
        }
    }

    func testLocalFrameDimensionsCannotBypassCanvasLimit() {
        var data = makeBudgetGIF()
        // 逻辑画布仍为 1x1，只把帧图像描述符的宽度改为 2049。
        data[32] = 1
        data[33] = 8
        XCTAssertThrowsError(try GifResource(data: data))
    }

    func testThumbnailUsesBoundedPixelDimensions() throws {
        let resource = try GifResource(data: makeEncodedGIF(width: 256, height: 128))
        let thumbnail = try resource.thumbnail(maximumPixelSize: 50)
        XCTAssertEqual(thumbnail.width, 50)
        XCTAssertEqual(thumbnail.height, 25)
        XCTAssertThrowsError(try resource.thumbnail(maximumPixelSize: 0))
    }

    func testSelectedCopyAndLegacyFileAreValidatedWithoutFallback() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gifs = directory.appendingPathComponent("XNook/gifs")
        try FileManager.default.createDirectory(at: gifs, withIntermediateDirectories: true)
        let valid = makeBudgetGIF()
        let invalid = makeBudgetGIF(frameCount: 501)
        let selected = gifs.appendingPathComponent("selected.gif")
        let legacy = directory.appendingPathComponent("XNook/custom.gif")
        try valid.write(to: selected)
        try valid.write(to: legacy)
        XCTAssertEqual(try GifResource.selectedData(selectedName: "selected.gif", appSupport: directory, bookmarkData: nil), valid)
        XCTAssertEqual(try GifResource.selectedData(selectedName: nil, appSupport: directory, bookmarkData: nil), valid)
        try invalid.write(to: selected)
        assertRejection(.frameCount) {
            try GifResource.selectedData(selectedName: "selected.gif", appSupport: directory, bookmarkData: nil)
        }
        try invalid.write(to: legacy)
        assertRejection(.frameCount) {
            try GifResource.selectedData(selectedName: nil, appSupport: directory, bookmarkData: nil)
        }
        XCTAssertNil(try GifResource.selectedData(selectedName: "", appSupport: directory, bookmarkData: nil))
        XCTAssertThrowsError(try GifResource.selectedData(selectedName: "missing.gif", appSupport: directory, bookmarkData: nil))
    }

    func testLegacyBookmarkReadsThroughTheSameBudget() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bookmark.gif")
        let valid = makeBudgetGIF()
        try valid.write(to: url)
        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        XCTAssertEqual(try GifResource.selectedData(selectedName: nil, appSupport: nil, bookmarkData: bookmark), valid)
        try makeBudgetGIF(frameCount: 501).write(to: url)
        assertRejection(.frameCount) {
            try GifResource.selectedData(selectedName: nil, appSupport: nil, bookmarkData: bookmark)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeEncodedGIF(width: Int, height: Int, frameCount: Int = 1) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frameCount, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        for _ in 0..<frameCount { CGImageDestinationAddImage(destination, image, nil) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func assertRejection<T>(_ expected: GifResource.ValidationError, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> T) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? GifResource.ValidationError, expected, file: file, line: line)
        }
    }
}

/// 小型合法 LZW 数据，可只验证大画布/多帧元数据而无需实际分配大图。
func makeBudgetGIF(version: String = "GIF89a", width: Int = 1, height: Int = 1, frameCount: Int = 1) -> Data {
    var data = Data(version.utf8)
    data.append(contentsOf: [UInt8(width & 0xff), UInt8(width >> 8), UInt8(height & 0xff), UInt8(height >> 8), 0x80, 0, 0])
    data.append(contentsOf: [0, 0, 0, 255, 255, 255])
    for _ in 0..<frameCount {
        if version == "GIF89a" { data.append(contentsOf: [0x21, 0xf9, 4, 1, 10, 0, 0, 0]) }
        data.append(contentsOf: [0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 1, 0])
    }
    data.append(0x3b)
    return data
}
