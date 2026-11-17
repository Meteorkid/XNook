import Foundation

/// 完整邀请码 = 载荷 + Ed25519 签名。
///
/// 设计约束（决定了为什么码很长）：
/// 本项目是 source-available，验证逻辑对所有人可见。
/// 因此**不能**使用对称密钥（HMAC/共享密钥）方案——读源码即可自行造码。
/// 只能采用非对称签名：发码方持私钥，App 仅内嵌公钥。
/// Ed25519 签名固定 64 字节，这是码长度的主要来源，无法压缩。
///
/// 字节布局：6 字节载荷 + 64 字节签名 = 70 字节。
/// 70 字节 × 8 = 560 位，Base32 后为 112 字符，恰好可分成 28 组 4 字符，
/// 无需补位即可整齐分组。
public struct LicenseCode: Equatable, Sendable {

    /// 品牌前缀。数字部分对应载荷中的格式版本，便于人眼快速识别。
    public static let prefix = "XNK1"
    /// 每组的字符数
    public static let groupSize = 4

    public var payload: LicensePayload
    /// Ed25519 签名，固定 64 字节
    public var signature: [UInt8]

    /// 签名固定长度
    public static let signatureByteCount = 64
    /// 载荷 + 签名的总字节数
    public static let totalByteCount = LicensePayload.byteCount + signatureByteCount
    /// Base32 编码后的字符数（不含前缀与分隔符）
    public static let bodyCharacterCount = CrockfordBase32.encodedLength(forByteCount: totalByteCount)

    public init(payload: LicensePayload, signature: [UInt8]) throws {
        guard signature.count == LicenseCode.signatureByteCount else {
            throw LicenseError.payloadCorrupted
        }
        self.payload = payload
        self.signature = signature
    }

    /// 拼接后的原始字节（载荷在前，签名在后）
    public var bytes: [UInt8] {
        payload.bytes + signature
    }

    /// 展示用字符串，形如 `XNK1-XXXX-XXXX-...`（共 28 组）
    public var encoded: String {
        let body = CrockfordBase32.encode(bytes)
        var groups: [String] = []
        var index = body.startIndex
        while index < body.endIndex {
            let end = body.index(index, offsetBy: LicenseCode.groupSize, limitedBy: body.endIndex) ?? body.endIndex
            groups.append(String(body[index..<end]))
            index = end
        }
        return LicenseCode.prefix + "-" + groups.joined(separator: "-")
    }

    /// 无分隔符的紧凑形式，用于 URL 查询参数传输
    public var compactEncoded: String {
        LicenseCode.prefix + CrockfordBase32.encode(bytes)
    }

    /// 一键激活链接
    public var activationURL: String {
        "xnook://activate?code=\(compactEncoded)"
    }

    /// 从用户输入解析邀请码。
    ///
    /// 容错处理：忽略大小写、分隔符、空白与换行；自动剥离前缀。
    /// - Throws: `LicenseError` 描述具体失败原因。
    public init(parsing input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LicenseError.emptyInput }

        // 剥离前缀（大小写不敏感），并去掉所有分隔符
        var working = trimmed.uppercased()
        if let range = working.range(of: LicenseCode.prefix) {
            working = String(working[range.upperBound...])
        }
        working = working.filter { $0 != "-" && $0 != " " && $0 != "\n" && $0 != "\r" && $0 != "\t" }

        guard !working.isEmpty else { throw LicenseError.emptyInput }

        // 长度校验先行，以便给出「被截断」这一更有用的提示
        if working.count != LicenseCode.bodyCharacterCount {
            // 若前缀完全不符且长度差异极大，判定为格式无法识别
            if !trimmed.uppercased().hasPrefix(LicenseCode.prefix) && working.count < LicenseCode.bodyCharacterCount / 2 {
                throw LicenseError.malformedPrefix(String(trimmed.prefix(4)))
            }
            throw LicenseError.wrongLength(
                expected: LicenseCode.bodyCharacterCount,
                actual: working.count
            )
        }

        let decoded = try CrockfordBase32.decode(working)
        guard decoded.count >= LicenseCode.totalByteCount else {
            throw LicenseError.wrongLength(
                expected: LicenseCode.totalByteCount,
                actual: decoded.count
            )
        }

        let payloadBytes = Array(decoded[0..<LicensePayload.byteCount])
        let signatureBytes = Array(decoded[LicensePayload.byteCount..<LicenseCode.totalByteCount])

        let payload = try LicensePayload(bytes: payloadBytes)
        guard payload.version <= LicensePayload.currentVersion else {
            throw LicenseError.unsupportedVersion(payload.version)
        }

        try self.init(payload: payload, signature: signatureBytes)
    }

    /// 仅解析载荷而不做签名校验。**仅供后台与调试使用，不可用于放行决策。**
    public static func parseUnverified(_ input: String) throws -> LicenseCode {
        try LicenseCode(parsing: input)
    }
}
