import Foundation

extension L10n {
    static var layoutEditorTitle: String { localized(zh: "编辑布局", en: "Edit layout") }
    static var layoutEditorChanged: String { localized(zh: "未保存更改", en: "Unsaved changes") }
    static var layoutEditorUnchanged: String { localized(zh: "尚未修改", en: "No changes") }
    static var layoutEditorDone: String { localized(zh: "完成", en: "Done") }
    static var layoutEditorSave: String { localized(zh: "保存布局", en: "Save layout") }
    static var layoutEditorSelected: String { localized(zh: "选中组件", en: "Selected module") }
    static var layoutEditorHidden: String { localized(zh: "已隐藏", en: "Hidden") }
    static var layoutEditorWidth: String { localized(zh: "布局宽度", en: "Layout width") }
    static var layoutEditorHeight: String { localized(zh: "组件高度", en: "Module height") }
    static var layoutEditorGuide: String { localized(
        zh: "单击选中 · 拖动标题移动 · 拖动右下角缩放。无需双击或长按。",
        en: "Click to select, drag a header to move, or drag its corner to resize. No double-click or hold needed.") }
    static var layoutEditorNarrowGuide: String { localized(
        zh: "单击选中；拖动标题调顺序，拖动右下角调高度。无需双击或长按。窄窗口自动换行，布局宽度在宽窗口生效。",
        en: "Click to select; drag a header to reorder or its corner to change height. No double-click or hold. Narrow windows wrap modules; widths apply in wider panels.") }
    static var layoutEditorVeryNarrowGuide: String { localized(
        zh: "单击选中；拖标题排序，拖右下角调高度。不需双击或长按。窄窗自动换行，宽度在宽窗生效。",
        en: "Click to select. Drag header: order; corner: height. No hold or double-click. Narrow panels wrap; width applies when wider.") }
    static var layoutEditorEarlierHelp: String { localized(zh: "按阅读顺序前移一位", en: "Move one place earlier in reading order") }
    static var layoutEditorLaterHelp: String { localized(zh: "按阅读顺序后移一位", en: "Move one place later in reading order") }
    static var layoutEditorSelectHelp: String { localized(zh: "单击选中组件，再调整上方设置", en: "Click to select this module, then adjust its settings above") }
    static var layoutEditorMoveHelp: String { localized(zh: "直接拖动标题移动，无需长按", en: "Drag this header directly to move; no hold needed") }
    static var layoutEditorResizeHelp: String { localized(zh: "拖动右下角调整组件大小", en: "Drag this corner to resize the module") }
    static var layoutEditorResizeHeightHelp: String { localized(zh: "窄窗口中拖动右下角调整高度", en: "Drag this corner to change height in a narrow panel") }
    static var layoutEditorMoving: String { localized(zh: "正在移动", en: "Moving") }
    static var layoutEditorResizing: String { localized(zh: "正在调整大小", en: "Resizing") }
    static var layoutEditorResizingHeight: String { localized(zh: "正在调整高度", en: "Changing height") }
    static var layoutEditorCardSelected: String { localized(zh: "已选中", en: "Selected") }
    static var layoutEditorCardUnselected: String { localized(zh: "单击选中", en: "Click to select") }

    static func layoutWidth(_ columns: Int) -> String {
        switch columns {
        case 4: localized(zh: "1/3 宽", en: "1/3 width")
        case 6: localized(zh: "半宽", en: "Half width")
        case 8: localized(zh: "2/3 宽", en: "2/3 width")
        default: localized(zh: "整行", en: "Full row")
        }
    }

    static func layoutHeight(_ rows: Int) -> String {
        let points = rows * Int(PanelGridGeometry.rowHeight) + max(0, rows - 1) * Int(PanelGridGeometry.spacing)
        return "\(layoutHeightName(rows)) · \(points) pt"
    }

    static func layoutHeightName(_ rows: Int) -> String {
        switch rows {
        case 3: localized(zh: "紧凑", en: "Compact")
        case 4: localized(zh: "标准", en: "Standard")
        case 6: localized(zh: "高", en: "Tall")
        default: localized(zh: "加高", en: "Extra tall")
        }
    }
}
