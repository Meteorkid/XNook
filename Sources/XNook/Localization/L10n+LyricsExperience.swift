import Foundation

extension L10n {
    static var lyricsDetailsClose: String { localized(zh: "关闭", en: "Close") }
    static var lyricsDetails: String { localized(zh: "歌词与校正", en: "Lyrics & timing") }
    static var lyricsOffset: String { localized(zh: "全局歌词偏移", en: "Global lyric offset") }
    static var lyricsOffsetHelp: String {
        localized(zh: "适用于所有歌曲。正值延后，负值提前；用于校正整首固定的早晚偏差。",
                  en: "Applies to all songs. Positive values delay lyrics; negative values advance them. Use this for a consistent timing difference.")
    }
    static var lyricsEarlier: String { localized(zh: "提前 0.1 秒", en: "Earlier 0.1 s") }
    static var lyricsLater: String { localized(zh: "延后 0.1 秒", en: "Later 0.1 s") }
    static var lyricsResetOffset: String { localized(zh: "重置", en: "Reset") }
    static var lyricsRetry: String { localized(zh: "重新查找歌词", en: "Retry lyrics") }
    static var lyricsRetryCoolingDown: String { localized(zh: "稍后可重试", en: "Retry available shortly") }
    static var lyricsRetryBypassesCache: String { localized(zh: "重新从网络查找，忽略本曲缓存；查找失败时保留可用歌词。", en: "Search online without this track's cache. Keep available lyrics if the lookup fails.") }
    static func lyricsRefreshNotice(_ notice: LyricsRefreshNotice) -> String {
        switch notice {
        case .failedKeepingCurrent: localized(zh: "重新查找失败，继续显示原歌词。", en: "The lookup failed. Previous lyrics are still available.")
        case .noMatchKeepingCurrent: localized(zh: "没有找到新的可用歌词，继续显示原歌词。", en: "No new lyrics were found. Previous lyrics are still available.")
        }
    }

    static func lyricsOffsetValue(_ value: Double) -> String {
        let seconds = String(format: "%.1f", abs(value))
        if value > 0 { return localized(zh: "延后 \(seconds) 秒", en: "Delay by \(seconds) seconds") }
        if value < 0 { return localized(zh: "提前 \(seconds) 秒", en: "Advance by \(seconds) seconds") }
        return localized(zh: "无偏移", en: "No offset")
    }

    static func lyricsStatus(_ status: LyricsStatus) -> String {
        switch status {
        case .idle: localized(zh: "等待歌曲信息", en: "Waiting for a track")
        case .loading: localized(zh: "正在查找歌词…", en: "Finding lyrics…")
        case .synced: localized(zh: "已有同步歌词", en: "Synced lyrics available")
        case .plainText: localized(zh: "只有文本歌词，暂无同步时间轴", en: "Text lyrics available without timing")
        case .notFound: localized(zh: "未找到可用歌词", en: "No lyrics found")
        case .failed: localized(zh: "歌词暂时加载失败", en: "Lyrics could not be loaded")
        case .disabled: localized(zh: "歌词已关闭，可在设置中开启", en: "Lyrics are off. Enable them in Settings.")
        }
    }
}
