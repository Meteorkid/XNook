import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import XNook

final class ArtworkDownloadTests: XCTestCase {
    private let url = URL(string: "https://i.scdn.co/image/test-cover")!

    func testValidImageBecomesDecodableStaticThumbnail() async throws {
        let original = try ArtworkTestImage.data(width: 2048, height: 8)
        let result = await ArtworkDownload.data(from: url) { request in
            XCTAssertEqual(request.url, self.url)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "image/*")
            return (original, self.response())
        }
        let data = try XCTUnwrap(result)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        XCTAssertEqual(image.width, ArtworkDownload.thumbnailSize)
        XCTAssertLessThanOrEqual(image.height, ArtworkDownload.thumbnailSize)
    }

    func testInvalidURLsNeverStartDownload() async {
        for value in ["http://i.scdn.co/image/a", "file:///tmp/cover.png", "data:image/png;base64,AA==", "https:///", "https://user:secret@example.com/a"] {
            let result = await ArtworkDownload.data(from: URL(string: value)!) { _ in
                XCTFail("An unsupported artwork URL must not start a download")
                return (Data(), self.response())
            }
            XCTAssertNil(result, value)
        }
    }

    func testFailedStatusNonHTTPResponseAndRedirectDowngradeAreRejected() async throws {
        let image = try ArtworkTestImage.data()
        let responses: [URLResponse] = [
            response(status: 404), response(status: 500), response(status: 302),
            response(url: URL(string: "http://example.com/cover.png")!),
            URLResponse(url: url, mimeType: "image/png", expectedContentLength: image.count, textEncodingName: nil),
        ]
        for response in responses {
            let result = await ArtworkDownload.data(from: url) { _ in (image, response) }
            XCTAssertNil(result)
        }
    }

    func testDeclaredAndActualOversizedResponsesAreRejected() async throws {
        let image = try ArtworkTestImage.data()
        let declared = response(headers: ["Content-Length": String(ArtworkDownload.maximumResponseBytes + 1)])
        let oversizedHeader = await ArtworkDownload.data(from: url) { _ in (image, declared) }
        XCTAssertNil(oversizedHeader)
        let oversizedBody = await ArtworkDownload.data(from: url) { _ in
            (Data(repeating: 0, count: ArtworkDownload.maximumResponseBytes + 1), self.response())
        }
        XCTAssertNil(oversizedBody)
    }

    func testNonImageTruncatedImageAnimationAndOversizedDimensionsAreRejected() async throws {
        let png = try ArtworkTestImage.data()
        let animation = try ArtworkTestImage.data(format: UTType.gif.identifier as CFString, frames: 2)
        let animationSource = try XCTUnwrap(CGImageSourceCreateWithData(animation as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(animationSource), 2, "The animation fixture must contain distinct frames")
        let invalidImages: [(String, Data)] = [
            ("HTML", Data("<html>not an image</html>".utf8)), ("empty", Data()), ("truncated PNG", Data(png.prefix(32))),
            ("oversized dimensions", try ArtworkTestImage.data(width: 8193, height: 1)),
            ("animated GIF", animation),
        ]
        for (name, data) in invalidImages {
            let result = await ArtworkDownload.data(from: url) { _ in (data, self.response()) }
            XCTAssertNil(result, name)
        }
    }

    func testDownloadFailureAndCancelledResponseReturnNoArtwork() async throws {
        let failed = await ArtworkDownload.data(from: url) { _ in throw URLError(.timedOut) }
        XCTAssertNil(failed)
        let image = try ArtworkTestImage.data()
        let started = expectation(description: "Download started")
        let gate = ArtworkDownloadGate()
        let task = Task {
            await ArtworkDownload.data(from: url) { _ in
                started.fulfill()
                await gate.wait()
                return (image, self.response())
            }
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        await gate.release()
        let cancelled = await task.value
        XCTAssertNil(cancelled)
    }

    private func response(
        status: Int = 200,
        url: URL? = nil,
        headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        HTTPURLResponse(url: url ?? self.url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}

enum ArtworkTestImage {
    static func data(
        width: Int = 2,
        height: Int = 2,
        format: CFString = UTType.png.identifier as CFString,
        frames: Int = 1
    ) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, format, frames, nil))
        for frame in 0..<frames {
            // ImageIO 会合并完全相同的 GIF 帧，动画夹具必须有像素变化。
            context.setFillColor(CGColor(red: CGFloat(frame + 1) / CGFloat(frames + 1), green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = try XCTUnwrap(context.makeImage())
            CGImageDestinationAddImage(destination, image, nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private actor ArtworkDownloadGate {
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
