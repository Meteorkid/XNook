import Foundation

/// 授权相关文案。
///
/// 与项目既有约定一致：在 `L10n` 的扩展中按 `localized(zh:en:)` 提供双语。
extension L10n {

    // MARK: - 设置页

    static var license: String { localized(zh: "授权", en: "License") }
    static var licenseStatus: String { localized(zh: "当前状态", en: "Status") }
    static var licenseEnterCode: String { localized(zh: "邀请码", en: "Activation code") }
    static var licenseActivate: String { localized(zh: "激活", en: "Activate") }
    static var licenseActivating: String { localized(zh: "正在激活…", en: "Activating…") }
    static var licensePasteFromClipboard: String { localized(zh: "从剪贴板粘贴", en: "Paste from Clipboard") }
    static var licenseDeactivate: String { localized(zh: "解除激活", en: "Deactivate") }
    static var licenseDeactivated: String { localized(zh: "已解除激活。", en: "Deactivated.") }

    static var licensePasteHint: String {
        localized(
            zh: "邀请码较长，建议直接复制粘贴，无需手动输入。也可以点击邮件中的激活链接自动填入。",
            en: "The code is long — copy and paste it rather than typing. You can also click the activation link in your email to fill it automatically."
        )
    }

    static var licenseTrialHint: String {
        localized(
            zh: "试用期内可使用全部功能。试用结束后需输入邀请码才能继续使用。",
            en: "All features are available during the trial. After it ends, an activation code is required to continue."
        )
    }

    static var licenseExpiredHint: String {
        localized(
            zh: "试用已结束。输入有效邀请码后立即恢复全部功能，已激活的授权永久有效。",
            en: "The trial has ended. Enter a valid activation code to restore all features immediately. Once activated, the license is perpetual."
        )
    }

    static var licenseSectionHowToGet: String {
        localized(zh: "如何获取邀请码", en: "How to get a code")
    }

    static var licenseHowToGetBody: String {
        localized(
            zh: "邀请码可在官方网站购买后自动发放，也可由开发者直接发放。购买后你会收到一串以 XNK1 开头的字符，以及一个可一键激活的链接。",
            en: "Codes are issued automatically after purchase on the official website, or directly by the developer. You will receive a string starting with XNK1, plus a one-click activation link."
        )
    }

    // MARK: - 到期窗口

    static var licenseExpiredWindowTitle: String {
        localized(zh: "试用已结束", en: "Trial ended")
    }

    static var licenseExpiredWindowSubtitle: String {
        localized(
            zh: "感谢你试用 X Nook。输入邀请码即可永久解锁全部功能。",
            en: "Thanks for trying X Nook. Enter an activation code to unlock all features permanently."
        )
    }

    static var licenseQuit: String { localized(zh: "退出", en: "Quit") }

    static var licensePurchase: String { localized(zh: "前往购买", en: "Purchase") }
}
