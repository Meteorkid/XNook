import Foundation

/// 授权相关错误。
///
/// 注意：面向用户的文案刻意保持「不透露内部结构」的措辞——
/// 例如签名错误统一提示「邀请码无效」，而不是「第 3 段签名校验失败」，
/// 避免为伪造者提供反馈信号。
public enum LicenseError: Error, Equatable, LocalizedError {

    /// 输入为空
    case emptyInput
    /// 出现字母表外的字符（可能是 OCR 误识或输入错误）
    case invalidCharacter(Character)
    /// 长度不符（截断或多余字符）
    case wrongLength(expected: Int, actual: Int)
    /// 缺少或错误的品牌前缀
    case malformedPrefix(String)
    /// 格式版本不受支持（来自更新版本 App 生成的码）
    case unsupportedVersion(UInt8)
    /// 签名校验失败——可能被篡改，也可能是随意编造的字符串
    case invalidSignature
    /// 载荷自身字段不合法
    case payloadCorrupted

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return Self.text("请输入邀请码。", "Please enter an activation code.")
        case .invalidCharacter(let character):
            return Self.text(
                "邀请码包含无效字符「\(character)」，请检查是否复制完整。",
                "The code contains an invalid character \"\(character)\". Please check that it was copied completely."
            )
        case .wrongLength(let expected, let actual):
            return Self.text(
                "邀请码长度不正确（应为 \(expected) 个字符，实际 \(actual) 个），可能复制时被截断。",
                "The code length is incorrect (expected \(expected), got \(actual)). It may have been truncated."
            )
        case .malformedPrefix(let prefix):
            return Self.text(
                "邀请码格式无法识别（前缀「\(prefix)」）。请确认是从官方渠道获取的邀请码。",
                "Unrecognized code format (prefix \"\(prefix)\"). Please make sure the code came from an official source."
            )
        case .unsupportedVersion(let version):
            return Self.text(
                "该邀请码由更新版本的软件生成（格式版本 \(version)），请先更新软件。",
                "This code was issued by a newer version of the app (format version \(version)). Please update first."
            )
        case .invalidSignature:
            return Self.text(
                "邀请码无效。请确认完整复制，或联系获取渠道核对。",
                "This activation code is not valid. Please verify it was copied in full, or contact the seller."
            )
        case .payloadCorrupted:
            return Self.text(
                "邀请码数据已损坏，请重新复制。",
                "The code data is corrupted. Please copy it again."
            )
        }
    }

    /// 供 App 侧复用的双语选择逻辑，避免各处自行判断语言造成不一致。
    public static func text(_ zh: String, _ en: String) -> String {
        // 核心模块不依赖 App 的本地化系统，此处按系统语言直接选择
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? zh : en
    }
}
