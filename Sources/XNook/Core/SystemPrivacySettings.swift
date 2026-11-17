import AppKit
import Foundation

/// 打开 macOS 系统设置中的常见权限面板，便于首次配置 X Nook 所需能力。
enum SystemPrivacySettings {
    /// 隐私面板的具体分页。所有跳转集中在这里，避免各视图各自拼 URL 拼错。
    enum Pane: String {
        case privacy
        case screenRecording
        case speechRecognition
        case calendars
        case automation
        case accessibility
        case loginItems

        var urlString: String {
            switch self {
            case .privacy:
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
            case .screenRecording:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            case .speechRecognition:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
            case .calendars:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
            case .automation:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
            case .accessibility:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            case .loginItems:
                "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
            }
        }

        /// 分页在系统设置里的叫法，用于「拖到右边『屏幕录制』列表里」这类指路文案。
        var listTitle: String {
            switch self {
            case .privacy:
                L10n.localized(zh: "隐私与安全性", en: "Privacy & Security")
            case .screenRecording:
                L10n.localized(zh: "屏幕录制", en: "Screen Recording")
            case .speechRecognition:
                L10n.localized(zh: "语音识别", en: "Speech Recognition")
            case .calendars:
                L10n.localized(zh: "日历", en: "Calendars")
            case .automation:
                L10n.localized(zh: "自动化", en: "Automation")
            case .accessibility:
                L10n.localized(zh: "辅助功能", en: "Accessibility")
            case .loginItems:
                L10n.localized(zh: "登录项", en: "Login Items")
            }
        }
    }

    static func open(_ pane: Pane) {
        open(pane.urlString)
    }

    static func openPrivacySecurity() {
        open(.privacy)
    }

    static func openCalendars() {
        open(.calendars)
    }

    static func openAutomation() {
        open(.automation)
    }

    static func openAccessibility() {
        open(.accessibility)
    }

    /// 实时字幕：ScreenCaptureKit 抓系统音频依赖此项。
    static func openScreenRecording() {
        open(.screenRecording)
    }

    static func openSpeechRecognition() {
        open(.speechRecognition)
    }

    static func openLoginItems() {
        open(.loginItems)
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
