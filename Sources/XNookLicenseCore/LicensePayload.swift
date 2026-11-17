import Foundation

/// 邀请码中的授权标志位。
public struct LicenseFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// 永久授权（当前唯一的授权类型，预留其他类型）
    public static let perpetual = LicenseFlags(rawValue: 1 << 0)
    /// 早期支持者标记（用于后续发放额外权益）
    public static let earlySupporter = LicenseFlags(rawValue: 1 << 1)
    /// 人工赠码（用于区分销售码与运营赠码，便于统计）
    public static let complimentary = LicenseFlags(rawValue: 1 << 2)

    /// 人类可读的标志描述（用于后台与发码工具展示）
    public var labels: [String] {
        var result: [String] = []
        if contains(.perpetual) { result.append("perpetual") }
        if contains(.earlySupporter) { result.append("early-supporter") }
        if contains(.complimentary) { result.append("complimentary") }
        return result
    }
}

/// 邀请码载荷——被签名保护的实际数据部分。
///
/// 字节布局（共 6 字节，大端序）：
///
/// | 偏移 | 长度 | 含义 |
/// |---|---|---|
/// | 0 | 1 | 格式版本，当前为 1 |
/// | 1–4 | 4 | 序列号（UInt32），发码时单调递增，可支撑约 42.9 亿个码 |
/// | 5 | 1 | 标志位（`LicenseFlags`） |
public struct LicensePayload: Equatable, Hashable, Sendable {

    /// 当前支持的格式版本
    public static let currentVersion: UInt8 = 1
    /// 载荷固定字节数
    public static let byteCount = 6

    public var version: UInt8
    public var serial: UInt32
    public var flags: LicenseFlags

    public init(version: UInt8 = LicensePayload.currentVersion,
                serial: UInt32,
                flags: LicenseFlags = [.perpetual]) {
        self.version = version
        self.serial = serial
        self.flags = flags
    }

    /// 序列化为 6 字节
    public var bytes: [UInt8] {
        [
            version,
            UInt8((serial >> 24) & 0xFF),
            UInt8((serial >> 16) & 0xFF),
            UInt8((serial >> 8) & 0xFF),
            UInt8(serial & 0xFF),
            flags.rawValue,
        ]
    }

    /// 从 6 字节反序列化
    /// - Throws: `LicenseError.payloadCorrupted` 当字节数不符。
    public init(bytes: [UInt8]) throws {
        guard bytes.count == LicensePayload.byteCount else {
            throw LicenseError.payloadCorrupted
        }
        self.version = bytes[0]
        self.serial = (UInt32(bytes[1]) << 24)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 8)
            | UInt32(bytes[4])
        self.flags = LicenseFlags(rawValue: bytes[5])
    }

    /// 面向客服与后台的短标识，例如 `XN-000042`
    public var shortIdentifier: String {
        String(format: "XN-%06u", serial)
    }
}
