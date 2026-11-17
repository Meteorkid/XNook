import Foundation

enum PanelHeightMode: String, CaseIterable, Identifiable {
    case automatic, limited

    var id: Self { self }

    /// 空值沿用旧开关，不在读取设置时改写用户偏好。
    static func resolved(storedValue: String, legacyAutomaticallyFit: Bool) -> Self {
        Self(rawValue: storedValue) ?? (legacyAutomaticallyFit ? .automatic : .limited)
    }

    /// 自定义的是窗口上限；默认组件仍按内容收紧，已保存的网格由布局存储继续保护。
    static func fitsDefaultContent(storedValue: String, legacyAutomaticallyFit: Bool) -> Bool {
        Self(rawValue: storedValue) != nil || legacyAutomaticallyFit
    }
}
