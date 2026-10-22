import Foundation

extension L10n {
    static var notesUntitled: String { localized(zh: "未命名笔记", en: "Untitled Note") }
    static var notesNew: String { localized(zh: "新建笔记", en: "New Note") }
    static var notesSearch: String { localized(zh: "搜索标题和内容", en: "Search titles and contents") }
    static var notesTitle: String { localized(zh: "笔记标题", en: "Note Title") }
    static var notesContent: String { localized(zh: "笔记内容", en: "Note Contents") }
    static var notesNoMatches: String { localized(zh: "没有匹配的笔记", en: "No matching notes") }
    static var notesEmptyHint: String { localized(zh: "点击加号，记录新的想法。", en: "Use the plus button to capture an idea.") }
    static var notesSearchHint: String { localized(zh: "试试其他关键词。", en: "Try another search term.") }
    static var notesDelete: String { localized(zh: "删除笔记", en: "Delete Note") }
    static var notesDeleted: String { localized(zh: "笔记已删除", en: "Note deleted") }
    static var notesUndoDelete: String { localized(zh: "撤销删除", en: "Undo Delete") }
    static var notesExport: String { localized(zh: "导出", en: "Export") }
    static var notesExportMarkdown: String { localized(zh: "Markdown（.md）", en: "Markdown (.md)") }
    static var notesExportText: String { localized(zh: "纯文本（.txt）", en: "Plain Text (.txt)") }
    static var notesExportFailed: String { localized(zh: "导出失败", en: "Export Failed") }
    static var notesExportMissing: String { localized(zh: "这条笔记已不存在。", en: "This note no longer exists.") }
    static var notesExportInvalidDestination: String { localized(zh: "请选择其他位置，不能覆盖笔记存储或恢复备份。", en: "Choose another location. Notes storage and recovery backups cannot be overwritten.") }
    static var notesDone: String { localized(zh: "完成", en: "Done") }
    static var notesNoContent: String { localized(zh: "暂无内容", en: "No contents yet") }

    static func notesShowAll(_ count: Int) -> String {
        localized(zh: "查看全部（\(count)）", en: "View All (\(count))")
    }

    static func notesCount(_ count: Int) -> String {
        localized(zh: "\(count) 条笔记", en: "\(count) notes")
    }
}
