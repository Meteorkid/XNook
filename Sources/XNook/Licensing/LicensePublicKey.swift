import Foundation
import CryptoKit
import XNookLicenseCore

/// 内嵌的 Ed25519 公钥。
///
/// ⚠️ 此文件由 `licensegen keygen` 生成，**不要手工编辑**。
/// 重新运行 `licensegen keygen` 会覆盖本文件。
///
/// 公钥可以安全地公开——它只能用于验证签名，无法用于生成有效邀请码。
/// 对应的私钥必须离线保管，绝不进入版本控制。
enum LicensePublicKey {

    /// Base64 编码的 Ed25519 公钥（32 字节）。
    ///
    /// 当前为**开发用占位密钥**，必须在正式发码前替换为真实密钥：
    /// ```
    /// swift run licensegen keygen --out Sources/XNook/Licensing/LicensePublicKey.swift
    /// ```
    static let base64 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    /// 是否为尚未替换的占位密钥。
    /// 为 `true` 时，App 会拒绝一切激活并给出明确提示，避免把开发密钥误发上线。
    static var isPlaceholder: Bool {
        base64 == "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    }

    /// 解析后的公钥。占位状态下返回 `nil`。
    static var publicKey: Curve25519.Signing.PublicKey? {
        guard !isPlaceholder else { return nil }
        return try? LicenseSigning.publicKey(base64: base64)
    }
}
