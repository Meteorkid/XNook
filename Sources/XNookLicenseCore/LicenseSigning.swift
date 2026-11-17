import Foundation
import CryptoKit

/// Ed25519 签名与验签。
///
/// 分工：
/// - **发码方**（`licensegen` 工具、管理后台）持有私钥，负责签名。
///   私钥绝不进入 App 仓库，绝不随二进制分发。
/// - **App** 仅内嵌公钥，负责验签。公钥泄露无风险。
public enum LicenseSigning {

    /// 域分隔前缀。
    ///
    /// 签名对象不是裸载荷，而是「域前缀 + 载荷」。这样即使未来用同一对密钥
    /// 签署其他用途的数据，签名也无法跨用途重放。
    public static let domainSeparator = Data("XNook-License-v1".utf8)

    /// 构造待签名的消息
    public static func message(for payload: LicensePayload) -> Data {
        domainSeparator + Data(payload.bytes)
    }

    // MARK: - 签名（发码侧）

    /// 用私钥对载荷签名
    public static func sign(payload: LicensePayload,
                            with privateKey: Curve25519.Signing.PrivateKey) throws -> [UInt8] {
        let signature = try privateKey.signature(for: message(for: payload))
        return [UInt8](signature)
    }

    /// 生成完整邀请码
    public static func issue(payload: LicensePayload,
                             privateKey: Curve25519.Signing.PrivateKey) throws -> LicenseCode {
        let signature = try sign(payload: payload, with: privateKey)
        return try LicenseCode(payload: payload, signature: signature)
    }

    // MARK: - 验签（App 侧）

    /// 校验邀请码签名是否有效
    public static func verify(_ code: LicenseCode,
                              using publicKey: Curve25519.Signing.PublicKey) -> Bool {
        publicKey.isValidSignature(Data(code.signature), for: message(for: code.payload))
    }

    /// 一步完成：解析 + 验签。
    /// - Throws: `LicenseError.invalidSignature` 当签名不匹配。
    public static func verify(input: String,
                              using publicKey: Curve25519.Signing.PublicKey) throws -> LicenseCode {
        let code = try LicenseCode(parsing: input)
        guard verify(code, using: publicKey) else {
            throw LicenseError.invalidSignature
        }
        return code
    }

    // MARK: - 密钥编解码

    /// 从 32 字节原始表示还原公钥
    public static func publicKey(fromRaw bytes: Data) throws -> Curve25519.Signing.PublicKey {
        try Curve25519.Signing.PublicKey(rawRepresentation: bytes)
    }

    /// 从 32 字节原始表示还原私钥
    public static func privateKey(fromRaw bytes: Data) throws -> Curve25519.Signing.PrivateKey {
        try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
    }

    /// Base64 字符串 → 公钥（便于写入源码常量）
    public static func publicKey(base64: String) throws -> Curve25519.Signing.PublicKey {
        guard let data = Data(base64Encoded: base64) else {
            throw LicenseError.payloadCorrupted
        }
        return try publicKey(fromRaw: data)
    }

    /// 生成新密钥对
    public static func generateKeyPair() -> Curve25519.Signing.PrivateKey {
        Curve25519.Signing.PrivateKey()
    }
}
