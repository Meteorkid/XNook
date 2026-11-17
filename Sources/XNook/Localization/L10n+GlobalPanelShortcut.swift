import Foundation

extension L10n {
    static var globalPanelShortcut: String { localized(zh: "全局快捷唤出", en: "Global panel shortcut") }
    static var globalPanelShortcutHelp: String { localized(
        zh: "设置后可从其他应用唤出面板。组合键至少包含 ⌘ 或 ⌃；按 Esc 取消录制。默认不设置快捷键。",
        en: "Bring up the panel from another app. Include ⌘ or ⌃ in the combination; press Esc to cancel recording. No shortcut is assigned by default.") }
    static var shortcutActive: String { localized(zh: "已启用", en: "Active") }
    static var shortcutInactive: String { localized(zh: "未启用", en: "Inactive") }
    static var shortcutNotSet: String { localized(zh: "未设置", en: "Not assigned") }
    static var shortcutRecording: String { localized(zh: "按下组合键…", en: "Press shortcut…") }
    static var shortcutRecord: String { localized(zh: "设置快捷键", en: "Record shortcut") }
    static var shortcutCancelRecording: String { localized(zh: "取消录制", en: "Cancel recording") }
    static var shortcutClear: String { localized(zh: "清除快捷键", en: "Clear shortcut") }
    static func shortcutFailure(_ failure: GlobalPanelShortcutFailure) -> String {
        switch failure {
        case .invalidShortcut:
            localized(zh: "请使用包含 ⌘ 或 ⌃ 的有效组合键。", en: "Use a valid combination containing ⌘ or ⌃.")
        case .invalidStoredShortcut:
            localized(zh: "保存的快捷键无法读取，请重新设置或清除。", en: "The saved shortcut could not be read. Record a new one or clear it.")
        case .inactive:
            localized(zh: "快捷唤出尚未启动，请从正在运行的 XNook 打开设置。", en: "Shortcut handling is inactive. Open Settings from the running XNook app.")
        case .systemConflict:
            localized(zh: "此组合键已用于系统快捷键，请选择其他组合；原快捷键保持不变。", en: "This combination is used by macOS. Choose another one; your previous shortcut is unchanged.")
        case .conflict:
            localized(zh: "此组合键已被占用，请选择其他组合；原快捷键保持不变。", en: "This combination is already registered. Choose another one; your previous shortcut is unchanged.")
        case .registrationFailed(let status):
            localized(zh: "无法注册快捷键（\(status)），原快捷键保持不变。", en: "The shortcut could not be registered (\(status)). Your previous shortcut is unchanged.")
        case .removalFailed(let status):
            localized(zh: "无法注销原快捷键（\(status)），已保留原设置，请重试。", en: "The previous shortcut could not be removed (\(status)). Its setting is retained; try again.")
        case .rollbackFailed:
            localized(zh: "新组合键未能完全撤销，原设置已保留；请重试或重新启动 XNook。", en: "The new registration could not be fully undone. Your previous setting is retained; retry or restart XNook.")
        }
    }
}
