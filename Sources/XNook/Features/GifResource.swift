import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 所有外部 GIF 在进入 ImageIO 解码前共用的资源边界。
struct GifResource {
    static let maximumEncodedBytes = 10 * 1_024 * 1_024
    static let maximumDimension = 2_048
    static let maximumFrameCount = 500
    static let maximumTotalPixels = 64 * 1_024 * 1_024
    static let loadFailureNotification = Notification.Name("GifLoadFailed")

    let data: Data
    let source: CGImageSource
    let frameCount: Int

    enum ValidationError: Error, LocalizedError {
        case invalidData
        case encodedSize
        case dimensions
        case frameCount
        case totalPixels

        var errorDescription: String? {
            switch self {
            case .invalidData: return L10n.gifInvalidData
            case .encodedSize: return L10n.gifEncodedSizeLimit
            case .dimensions: return L10n.gifDimensionLimit
            case .frameCount: return L10n.gifFrameCountLimit
            case .totalPixels: return L10n.gifTotalPixelsLimit
            }
        }
    }

    init(contentsOf url: URL) throws {
        let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard metadata.isRegularFile == true else { throw ValidationError.invalidData }
        if let size = metadata.fileSize, size > Self.maximumEncodedBytes { throw ValidationError.encodedSize }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try self.init(data: Self.readBoundedData { try handle.read(upToCount: $0) })
    }

    init(data: Data) throws {
        guard data.count <= Self.maximumEncodedBytes else { throw ValidationError.encodedSize }
        let header = Array(data.prefix(10))
        guard header.count == 10,
              header.prefix(6).elementsEqual("GIF87a".utf8) || header.prefix(6).elementsEqual("GIF89a".utf8)
        else { throw ValidationError.invalidData }

        let width = Int(header[6]) | Int(header[7]) << 8
        let height = Int(header[8]) | Int(header[9]) << 8
        // 先检查逻辑画布，防止帧元数据只描述局部更新区域。
        try Self.validateBudget(width: width, height: height, frameCount: 1)
        let declaredFrameCount = try Self.validateStructure(data: data, width: width, height: height)
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.gif.identifier,
              CGImageSourceGetStatus(source) == .statusComplete
        else { throw ValidationError.invalidData }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount == declaredFrameCount else { throw ValidationError.invalidData }
        try Self.validateBudget(width: width, height: height, frameCount: frameCount)
        var totalPixels = 0
        for index in 0..<frameCount {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
                  let frameWidth = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
                  let frameHeight = properties[kCGImagePropertyPixelHeight as String] as? NSNumber
            else { throw ValidationError.invalidData }
            try Self.validateBudget(width: frameWidth.intValue, height: frameHeight.intValue, frameCount: 1)
            let decodedWidth = max(width, frameWidth.intValue)
            let decodedHeight = max(height, frameHeight.intValue)
            try Self.validateBudget(width: decodedWidth, height: decodedHeight, frameCount: 1)
            // ImageIO 可能按完整画布合成每帧，而不是只解码 GIF 的局部矩形。
            let (pixels, overflow) = decodedWidth.multipliedReportingOverflow(by: decodedHeight)
            guard !overflow, pixels <= Self.maximumTotalPixels - totalPixels else {
                throw ValidationError.totalPixels
            }
            totalPixels += pixels
        }
        self.data = data
        self.source = source
        self.frameCount = frameCount
    }

    static func validateBudget(width: Int, height: Int, frameCount: Int) throws {
        guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension else {
            throw ValidationError.dimensions
        }
        guard frameCount > 0, frameCount <= maximumFrameCount else { throw ValidationError.frameCount }
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (total, totalOverflow) = pixels.multipliedReportingOverflow(by: frameCount)
        guard !pixelOverflow, !totalOverflow, total <= maximumTotalPixels else {
            throw ValidationError.totalPixels
        }
    }

    /// ImageIO 会归一化部分帧元数据；解码前同时检查原始图像描述符。
    private static func validateStructure(data: Data, width: Int, height: Int) throws -> Int {
        let bytes = Array(data)
        guard bytes.count >= 13 else { throw ValidationError.invalidData }
        var offset = 13
        var frameCount = 0
        var totalPixels = 0
        func word(at index: Int) -> Int { Int(bytes[index]) | Int(bytes[index + 1]) << 8 }
        func skipColorTable(_ packed: UInt8) throws {
            if packed & 0x80 != 0 { offset += 3 * (1 << (Int(packed & 7) + 1)) }
            guard offset <= bytes.count else { throw ValidationError.invalidData }
        }
        func skipBlocks() throws {
            while offset < bytes.count {
                let count = Int(bytes[offset])
                offset += 1
                guard count <= bytes.count - offset else { throw ValidationError.invalidData }
                offset += count
                if count == 0 { return }
            }
            throw ValidationError.invalidData
        }
        try skipColorTable(bytes[10])
        while offset < bytes.count {
            let marker = bytes[offset]
            offset += 1
            switch marker {
            case 0x21:
                guard offset < bytes.count else { throw ValidationError.invalidData }
                offset += 1 // 扩展标签后是有界的子数据块。
                try skipBlocks()
            case 0x2c:
                guard bytes.count - offset >= 9 else { throw ValidationError.invalidData }
                let left = word(at: offset)
                let top = word(at: offset + 2)
                let frameWidth = word(at: offset + 4)
                let frameHeight = word(at: offset + 6)
                let packed = bytes[offset + 8]
                offset += 9
                frameCount += 1
                guard frameCount <= maximumFrameCount else { throw ValidationError.frameCount }
                try validateBudget(width: frameWidth, height: frameHeight, frameCount: 1)
                let decodedWidth = max(width, left + frameWidth)
                let decodedHeight = max(height, top + frameHeight)
                try validateBudget(width: decodedWidth, height: decodedHeight, frameCount: 1)
                let (pixels, overflow) = decodedWidth.multipliedReportingOverflow(by: decodedHeight)
                guard !overflow, pixels <= maximumTotalPixels - totalPixels else { throw ValidationError.totalPixels }
                totalPixels += pixels
                try skipColorTable(packed)
                guard offset < bytes.count else { throw ValidationError.invalidData }
                offset += 1 // LZW 最小码长；压缩内容交由 ImageIO 解析。
                try skipBlocks()
            case 0x3b:
                guard frameCount > 0 else { throw ValidationError.frameCount }
                return frameCount
            default:
                throw ValidationError.invalidData
            }
        }
        throw ValidationError.invalidData
    }

    /// 不信任读取前的文件大小；始终最多读取预算加一个探测字节。
    static func readBoundedData(readChunk: (Int) throws -> Data?) throws -> Data {
        var data = Data()
        while let chunk = try readChunk(min(64 * 1_024, maximumEncodedBytes - data.count + 1)), !chunk.isEmpty {
            guard chunk.count <= maximumEncodedBytes - data.count else { throw ValidationError.encodedSize }
            data.append(chunk)
        }
        return data
    }

    func thumbnail(maximumPixelSize: Int = 100) throws -> CGImage {
        guard maximumPixelSize > 0, maximumPixelSize <= Self.maximumDimension,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary)
        else { throw ValidationError.invalidData }
        return image
    }

    static func selectedData(selectedName: String?, appSupport: URL?, bookmarkData: Data?) throws -> Data? {
        if let selectedName {
            guard !selectedName.isEmpty, let appSupport else { return nil }
            return try GifResource(contentsOf: appSupport.appendingPathComponent("XNook/gifs").appendingPathComponent(selectedName)).data
        }
        if let appSupport {
            let legacyURL = appSupport.appendingPathComponent("XNook/custom.gif")
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                return try GifResource(contentsOf: legacyURL).data
            }
        }
        guard let bookmarkData else { return nil }
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope,
                          relativeTo: nil, bookmarkDataIsStale: &isStale)
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard accessing else { throw CocoaError(.fileReadNoPermission) }
        return try GifResource(contentsOf: url).data
    }
}
