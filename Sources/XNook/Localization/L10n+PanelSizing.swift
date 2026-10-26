import Foundation

extension L10n {
    static var panelHeightMode: String { localized(zh: "展开高度", en: "Expanded height") }
    static var panelHeightModeDesc: String { localized(
        zh: "自动模式贴合当前内容；自定义模式在贴合内容的基础上增加高度上限。两种模式都不会将空白撑到设定高度。",
        en: "Fit content follows the current page. Custom limit adds a maximum height while still fitting shorter content. Neither mode pads the panel to a fixed height.") }
    static var panelHeightAutomatic: String { localized(zh: "自动贴合内容", en: "Fit content") }
    static var panelHeightLimited: String { localized(zh: "自定义高度上限", en: "Custom limit") }
    static var panelHeightAutomaticStatus: String { localized(
        zh: "随当前页面内容收紧；超出屏幕可用高度时滚动显示。",
        en: "Fits the current page; content scrolls when it exceeds the available screen height.") }
    static func panelHeightLimitedStatus(_ height: Double) -> String {
        let value = String(format: "%.0f", height.isFinite ? height : SettingsDefaults.double(for: "panelBaseHeight"))
        return localized(zh: "最高 \(value) pt；内容少时仍收紧，超出时滚动显示。可点击右侧数值直接输入。",
            en: "Up to \(value) pt. Shorter content still fits; longer content scrolls. Click the value to enter a height.")
    }
    static var settingsModuleChangesHint: String { localized(
        zh: "显示开关立即生效；排列和组件尺寸在编辑布局中保存后生效。",
        en: "Visibility switches apply immediately. Arrangement and module sizes apply after saving in the layout editor.") }
    static var settingsLayoutGuide: String { localized(
        zh: "单击选中组件，拖动标题移动，拖动右下角调整大小；无需双击或长按。",
        en: "Click a module to select it, drag its title to move it, or drag its lower-right corner to resize. No double-click or long press is needed.") }
}
