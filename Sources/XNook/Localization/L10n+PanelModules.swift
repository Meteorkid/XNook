import Foundation

extension L10n {
    static var trayDropHint: String {
        localized(zh: "暂存文件，稍后拖出或打开", en: "Keep files ready to drag out or open")
    }

    static func panelCalendarMonth(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: isChinese ? "zh_CN" : "en_US")
        formatter.dateFormat = isChinese ? "yyyy年 M月" : "MMM yyyy"
        return formatter.string(from: date)
    }
}
