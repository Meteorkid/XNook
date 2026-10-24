import Foundation

extension L10n {
    static var flowTimeBudget: String { localized(zh: "预计用时", en: "Time budget") }
    static var flowBudgetMinutes: String { localized(zh: "分钟", en: "minutes") }
    static var flowApplyBudget: String { localized(zh: "设置", en: "Set") }
    static var flowClearBudget: String { localized(zh: "清除计划", en: "Clear plan") }
    static var flowNoBudget: String { localized(zh: "尚未设置预计结束时间", en: "No planned finish time") }
    static var flowBudgetHelp: String { localized(zh: "从现在起计算，1–1440 整数分钟。只修改任务计划，不改变系统日历。", en: "Count from now, using 1–1440 whole minutes. This changes the task plan, not Calendar.") }
    static var flowBudgetInvalid: String { localized(zh: "请输入 1–1440 的整数分钟。", en: "Enter a whole number from 1 to 1440 minutes.") }
    static var flowBudgetHistoryReadOnly: String { localized(zh: "历史任务保留原计划时间", en: "Historical tasks retain their original plan") }
    static var flowBudgetOverdue: String { localized(zh: "已到预计结束时间", en: "Planned finish reached") }
    static func flowBudgetEnd(_ time: String) -> String { localized(zh: "预计结束：\(time)", en: "Planned finish: \(time)") }
    static func flowBudgetDue(_ title: String) -> String { localized(zh: "任务已到预计结束时间：\(title)", en: "Planned finish reached: \(title)") }
}
