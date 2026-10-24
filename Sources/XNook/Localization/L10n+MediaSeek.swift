import Foundation

extension L10n {
    static var mediaSeekPending: String { localized(zh: "正在确认播放位置…", en: "Confirming playback position…") }
    static var mediaSeekUnavailable: String { localized(zh: "此曲目暂不支持定位", en: "Seeking is unavailable for this track") }
    static func mediaSeekFailure(_ failure: MediaSeekFailure) -> String {
        switch failure {
        case .unavailable: mediaSeekUnavailable
        case .trackChanged: localized(zh: "曲目已变化，请重新定位。", en: "The track changed. Try seeking again.")
        case .commandFailed: localized(zh: "无法定位，请检查播放器控制权限后重试。", en: "Could not seek. Check player control permissions and retry.")
        case .unconfirmed: localized(zh: "未确认新的播放位置，请重试。", en: "The new playback position was not confirmed. Please retry.")
        }
    }
}
