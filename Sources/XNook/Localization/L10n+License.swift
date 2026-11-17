import Foundation

/// 授权相关文案。
///
/// 与项目既有约定一致：在 `L10n` 的扩展中按 `localized(zh:en:)` 提供双语。
extension L10n {

    // MARK: - 设置页

    static var license: String { localized(zh: "授权", en: "License") }
    static var licenseStatus: String { localized(zh: "当前状态", en: "Status") }
    static var licenseEnterCode: String { localized(zh: "激活码", en: "Activation code") }
    static var licenseActivate: String { localized(zh: "激活", en: "Activate") }
    static var licenseActivating: String { localized(zh: "正在激活…", en: "Activating…") }
    static var licensePasteFromClipboard: String { localized(zh: "从剪贴板粘贴", en: "Paste from Clipboard") }
    static var licenseDeactivate: String { localized(zh: "解除激活", en: "Deactivate") }
    static var licenseDeactivated: String {
        localized(zh: "本机已解绑，可在其他设备使用激活码。",
                  en: "This device is unlinked. Use the activation code on another device.")
    }

    static var licensePasteHint: String {
        localized(
            zh: "从官网账户中复制对应软件的激活码，粘贴到这里后激活。",
            en: "Copy the matching activation code from your website account, then paste it here."
        )
    }

    static var licenseTrialHint: String {
        localized(
            zh: "试用期内可使用全部功能。试用结束后需输入激活码才能继续使用。",
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
        localized(zh: "如何获取激活码", en: "How to get an activation code")
    }

    static var licenseHowToGetBody: String {
        localized(
            zh: "购买或由管理员赠送后，在官网账户中查看激活码。首次试用和激活需要联网；每份付费授权最多绑定 3 台设备，离线有效期最长 7 天。旧版 XNK1 离线激活码请联系管理员迁移。",
            en: "Find purchased or administrator-granted activation codes in your website account. Starting a trial and activating require a connection. Each paid license supports up to three devices and seven days offline. Contact the administrator to migrate an old XNK1 offline activation code."
        )
    }

    // MARK: - 到期窗口

    static var licenseExpiredWindowTitle: String {
        localized(zh: "X Nook 软件授权", en: "X Nook License")
    }

    static var licenseExpiredWindowSubtitle: String {
        localized(
            zh: "联网开始 14 天试用，或输入激活码解锁一个月、一年或永久使用权。",
            en: "Connect to start a 14-day trial, or enter an activation code for 1 month, 1 year, or Lifetime access."
        )
    }

    static var licenseQuit: String { localized(zh: "退出", en: "Quit") }

    static var licensePurchase: String { localized(zh: "前往购买", en: "Purchase") }
}
