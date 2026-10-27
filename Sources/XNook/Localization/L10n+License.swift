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
            zh: "请联网验证授权。如使用权已到期，可购买新授权或联系管理员续费。本地数据仍可导出。",
            en: "Connect to verify your license. If the entitlement has expired, renew it or contact the administrator. Local data can still be exported."
        )
    }

    static var licenseSectionHowToGet: String {
        localized(zh: "如何获取邀请码", en: "How to get a code")
    }

    static var licenseHowToGetBody: String {
        localized(
            zh: "邀请码可在官方网站购买后获取，也可由管理员发放。首次试用和激活需要联网；每份付费授权最多绑定 3 台设备，离线有效期最长 7 天。旧版 XNK1 邀请码请联系管理员迁移。",
            en: "Purchase a code from the official website or contact the administrator. Starting a trial and activating require a connection. Each paid license supports up to three devices and seven days offline. Contact the administrator to migrate an old XNK1 code."
        )
    }

    // MARK: - 到期窗口

    static var licenseExpiredWindowTitle: String {
        localized(zh: "X Nook 软件授权", en: "X Nook License")
    }

    static var licenseExpiredWindowSubtitle: String {
        localized(
            zh: "联网开始 14 天试用，或输入邀请码激活月度、年度或永久使用权。",
            en: "Connect to start a 14-day trial, or activate a monthly, annual, or lifetime license."
        )
    }

    static var licenseQuit: String { localized(zh: "退出", en: "Quit") }

    static var licensePurchase: String { localized(zh: "前往购买", en: "Purchase") }
}
