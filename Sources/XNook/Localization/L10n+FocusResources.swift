import Foundation

extension L10n {
    static var flowResourceNoteUnsaved: String { localized(
        zh: "当前笔记尚未保存，请先处理保存错误再重试。",
        en: "The current note has not been saved. Resolve the save error, then retry.") }
    static var flowResourceNoteKept: String { localized(
        zh: "笔记已保留，但任务关联未能保存。请重新读取任务记录后重试，或关联这篇已有笔记。",
        en: "The note is preserved, but its task link could not be saved. Reload task records and retry, or link the existing note.") }
    static var flowResourceBookmarkFailure: String { localized(
        zh: "无法保存所选文件的访问凭据，原关联已保留。请重新选择文件。",
        en: "Access to the selected file could not be saved. The original link is preserved. Select the file again.") }
}
