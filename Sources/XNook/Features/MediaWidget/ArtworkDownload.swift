import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Spotify 封面只保留受限静态缩略图，网络读取与播放器快照完全独立。
enum ArtworkDownload {
    typealias LoadRequest = (URLRequest) async throws -> (Data, URLResponse)
    static let maximumResponseBytes = 4 * 1024 * 1024
    static let maximumPixelCount = 16_777_216
    static let thumbnailSize = 512

    private final class HTTPSRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(request.url.map(ArtworkDownload.isAllowedURL) == true ? request : nil)
        }
    }

    static func isAllowedURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty
            && url.user == nil && url.password == nil
    }

    private static func isAllowedResponse(_ response: URLResponse) -> Bool {
        guard let response = response as? HTTPURLResponse,
              let url = response.url, isAllowedURL(url),
              (200...299).contains(response.statusCode) else { return false }
        return response.expectedContentLength <= Int64(maximumResponseBytes)
    }

    static func loadBoundedResponse(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, isAllowedURL(url) else { throw URLError(.badURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        // 持续有字节到达也不能无限占用下载任务。
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request, delegate: HTTPSRedirectDelegate())
        guard isAllowedResponse(response) else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumResponseBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return (data, response)
    }

    static func data(from url: URL, load: LoadRequest = loadBoundedResponse) async -> Data? {
        guard isAllowedURL(url), !Task.isCancelled else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await load(request)
            guard !Task.isCancelled, isAllowedResponse(response),
                  !data.isEmpty, data.count <= maximumResponseBytes else { return nil }
            return staticThumbnail(from: data)
        } catch {
            // 无封面与短暂网络失败共用调用方的 30 秒退避。
            return nil
        }
    }

    static func staticThumbnail(from data: Data) -> Data? {
        guard !data.isEmpty, data.count <= maximumResponseBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= maximumPixelCount else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
