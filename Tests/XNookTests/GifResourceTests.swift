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
        if let helperPath = ProcessInfo.processInfo.environment["XNOOK_BOOKMARK_HELPER"] {
            try assertSignedBookmarkRegression(helperPath: helperPath)
            return
        }

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bookmark.gif")
        let valid = makeBudgetGIF()
        try valid.write(to: url)

        // 直接验证当前宿主的实际行为；不要把任意创建失败当成权限不足而跳过。
        let bookmark: Data
        do {
            bookmark = try url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
        } catch {
            XCTFail("书签创建失败：\(error)。可用 scripts/test-signed-bookmarks.sh --filter GifResourceTests 验证独立签名宿主。")
            return
        }

        XCTAssertEqual(try GifResource.selectedData(selectedName: nil, appSupport: nil, bookmarkData: bookmark), valid)
        try makeBudgetGIF(frameCount: 501).write(to: url)
        assertRejection(.frameCount) {
            try GifResource.selectedData(selectedName: nil, appSupport: nil, bookmarkData: bookmark)
        }
    }

    private func assertSignedBookmarkRegression(helperPath: String) throws {
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            XCTFail("XNOOK_BOOKMARK_HELPER 不是可执行文件：\(helperPath)")
            return
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let created = try runBookmarkHelper(helperPath, command: "create", directory: directory)
        XCTAssertGreaterThan(try XCTUnwrap(created["bookmarkBytes"] as? Int), 0)
        let creatorPID = try XCTUnwrap(created["pid"] as? Int)
        let resolved = try runBookmarkHelper(helperPath, command: "resolve", directory: directory)
        XCTAssertEqual(resolved["creatorPID"] as? Int, creatorPID)
        XCTAssertNotEqual(resolved["pid"] as? Int, creatorPID)
        XCTAssertEqual(resolved["validDataMatches"] as? Bool, true)
        XCTAssertEqual(resolved["bookmarkUnchanged"] as? Bool, true)
        XCTAssertEqual(resolved["rejections"] as? [String],
                       ["invalidData", "frameCount", "encodedSize", "dimensions", "totalPixels"])
    }

    private func runBookmarkHelper(_ path: String, command: String, directory: URL) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [command, directory.path]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let diagnostics = "\(command): \(String(decoding: data, as: UTF8.self)) \(stderr)"
        XCTAssertEqual(process.terminationReason, .exit, diagnostics)
        XCTAssertEqual(process.terminationStatus, 0, diagnostics)
        let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], diagnostics)
        XCTAssertEqual(result["ok"] as? Bool, true, diagnostics)
        XCTAssertEqual(result["command"] as? String, command)
        XCTAssertGreaterThan(try XCTUnwrap(result["pid"] as? Int), 0)
        XCTAssertEqual(result["entitlement"] as? Bool, true)
        XCTAssertEqual(result["hardenedRuntime"] as? Bool, true)
        print("Signed bookmark regression: \(String(decoding: data, as: UTF8.self))")
        return result
    }

    func testFileReaderRejectsFIFOWithoutWaitingForAWriter() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("pipe.gif")
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)
        let finished = expectation(description: "FIFO is rejected immediately")
        DispatchQueue.global().async {
            do {
                _ = try GifResource(contentsOf: fifo)
                XCTFail("FIFO must not be accepted as a GIF file")
            } catch {
                XCTAssertEqual(error as? GifResource.ValidationError, .fileType)
            }
            finished.fulfill()
        }
        let result = XCTWaiter.wait(for: [finished], timeout: 0.5)
        if result != .completed {
            // 回归时解开阻塞的 open，避免测试自身遗留一个永久等待的线程。
            let writer = open(fifo.path, O_RDWR | O_NONBLOCK)
            if writer >= 0 { close(writer) }
        }
        XCTAssertEqual(result, .completed)
    }

    func testFileReaderAcceptsRegularFileAndItsSymbolicLink() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("regular.gif")
        let symlink = directory.appendingPathComponent("link.gif")
        let data = makeBudgetGIF()
        try data.write(to: file)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
        XCTAssertEqual(try GifResource(contentsOf: file).data, data)
        XCTAssertEqual(try GifResource(contentsOf: symlink).data, data)
    }

    func testFileReaderRejectsDirectoryAndDeviceBeforeReading() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for url in [directory, URL(fileURLWithPath: "/dev/null")] {
            assertRejection(.fileType) { try GifResource(contentsOf: url) }
        }
    }

    func testInjectedLegacyBookmarkReadsThroughTheSameBudget() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bookmark.gif")
        let valid = makeBudgetGIF()
        try valid.write(to: url)
        let bookmark = Data("isolated bookmark".utf8)
        let read = {
            try GifResource.selectedData(selectedName: nil, appSupport: nil, bookmarkData: bookmark,
                                         resolveBookmark: { _ in url }, startAccessing: { _ in true }, stopAccessing: { _ in })
        }
        XCTAssertEqual(try read(), valid)
        try makeBudgetGIF(frameCount: 501).write(to: url)
        assertRejection(.frameCount) { try read() }
    }

    func testBadLegacyCopyFallsBackToBookmarkAndBalancesAccess() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appendingPathComponent("XNook/custom.gif")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: legacy)
        let bookmarkURL = directory.appendingPathComponent("bookmark.gif")
        let valid = makeBudgetGIF()
        try valid.write(to: bookmarkURL)
        var accesses: [String] = []
        let read = {
            try GifResource.selectedData(selectedName: nil, appSupport: directory, bookmarkData: Data([1]),
                resolveBookmark: { _ in accesses.append("resolve"); return bookmarkURL },
                startAccessing: { _ in accesses.append("start"); return true },
                stopAccessing: { _ in accesses.append("stop") })
        }
        XCTAssertEqual(try read(), valid)
        XCTAssertEqual(accesses, ["resolve", "start", "stop"])
        accesses = []
        try makeBudgetGIF(frameCount: 501).write(to: bookmarkURL)
        assertRejection(.frameCount) { try read() }
        XCTAssertEqual(accesses, ["resolve", "start", "stop"])
    }

    func testExplicitSelectionFailureAndEmptySelectionNeverUseBookmark() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gifs = directory.appendingPathComponent("XNook/gifs")
        try FileManager.default.createDirectory(at: gifs, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: gifs.appendingPathComponent("selected.gif"))
        var resolved = false
        let read: (String) throws -> Data? = { name in
            try GifResource.selectedData(selectedName: name, appSupport: directory, bookmarkData: Data([1]),
                resolveBookmark: { _ in resolved = true; throw CocoaError(.fileReadUnknown) })
        }
        XCTAssertThrowsError(try read("selected.gif"))
        XCTAssertThrowsError(try read("missing.gif"))
        XCTAssertNil(try read(""))
        XCTAssertFalse(resolved)
    }

    func testBookmarkResolutionAndAccessFailuresDoNotLeakAccess() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var stopped = false
        XCTAssertThrowsError(try GifResource.selectedData(selectedName: nil, appSupport: nil, bookmarkData: Data([1]),
            resolveBookmark: { _ in throw CocoaError(.fileReadCorruptFile) },
            startAccessing: { _ in XCTFail("Resolution failed"); return true },
            stopAccessing: { _ in stopped = true }))
        XCTAssertThrowsError(try GifResource.selectedData(selectedName: nil, appSupport: nil, bookmarkData: Data([1]),
            resolveBookmark: { _ in directory }, startAccessing: { _ in false },
            stopAccessing: { _ in stopped = true }))
        XCTAssertFalse(stopped)
    }

    func testValidLegacyCopyTakesPrecedenceOverBookmark() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appendingPathComponent("XNook/custom.gif")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let valid = makeBudgetGIF()
        try valid.write(to: legacy)
        XCTAssertEqual(try GifResource.selectedData(selectedName: nil, appSupport: directory, bookmarkData: Data([1]),
            resolveBookmark: { _ in XCTFail("Valid legacy copy should be used first"); return legacy }), valid)
    }

    func testEveryStoredSourceAndThumbnailUseTheResourceBudget() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gifs = directory.appendingPathComponent("XNook/gifs")
        try FileManager.default.createDirectory(at: gifs, withIntermediateDirectories: true)
        let selected = gifs.appendingPathComponent("selected.gif")
        let legacy = directory.appendingPathComponent("XNook/custom.gif")
        for invalid in [makeBudgetGIF(frameCount: 501), makeBudgetGIF(width: 2_049),
                        makeBudgetGIF(width: 2_048, height: 2_048, frameCount: 17),
                        Data(count: GifResource.maximumEncodedBytes + 1)] {
            try invalid.write(to: selected)
            try invalid.write(to: legacy)
            XCTAssertThrowsError(try GifResource(contentsOf: selected).thumbnail())
            XCTAssertThrowsError(try GifResource.selectedData(selectedName: "selected.gif", appSupport: directory, bookmarkData: nil))
            XCTAssertThrowsError(try GifResource.selectedData(selectedName: nil, appSupport: directory, bookmarkData: nil))
            XCTAssertThrowsError(try GifResource.selectedData(selectedName: nil, appSupport: nil, bookmarkData: Data([1]),
                resolveBookmark: { _ in selected }, startAccessing: { _ in true }, stopAccessing: { _ in }))
        }
    }

    func testStoredFileRemovalOnlyUpdatesStateAfterSuccessOrMissingFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("selected.gif")
        let original = makeBudgetGIF()
        try original.write(to: url)
        var names = ["selected.gif", "other.gif"]
        var selectedName = "selected.gif"
        let update = { names.removeAll { $0 == "selected.gif" }; selectedName = "" }
        XCTAssertThrowsError(try GifResource.removeStoredFile(at: url, removeItem: { _ in
            throw CocoaError(.fileWriteNoPermission)
        }, didRemove: update))
        XCTAssertEqual(names, ["selected.gif", "other.gif"])
        XCTAssertEqual(selectedName, "selected.gif")
        XCTAssertEqual(try Data(contentsOf: url), original)
        try GifResource.removeStoredFile(at: url, didRemove: update)
        XCTAssertEqual(names, ["other.gif"])
        XCTAssertEqual(selectedName, "")
        var missingDidUpdate = false
        try GifResource.removeStoredFile(at: url, didRemove: { missingDidUpdate = true })
        XCTAssertTrue(missingDidUpdate)
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
