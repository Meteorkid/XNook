import Foundation

extension L10n {
    static var claudeCompletion: String { localized(zh: "Claude Code 完成提示", en: "Claude Code notices") }
    static var claudeCompletionHelp: String { localized(
        zh: "需开启“显示短提示”并配置 Claude Code 的 Stop hook。只提示本轮响应结束；不扫描聊天记录或终端，不转发回复正文，不自动展开面板。",
        en: "Requires brief notices and a Claude Code Stop hook. Reports the end of a response without scanning chats or terminal history, forwarding response text, or opening the panel.") }
    static var claudeResponseEnded: String { localized(zh: "Claude Code 本轮响应已结束", en: "Claude Code finished this response") }
    static var claudeCopyConfiguration: String { localized(zh: "复制 Stop 配置", en: "Copy Stop configuration") }
    static var claudeConfigurationCopied: String { localized(zh: "已复制；请合并到已有 hooks，保留其他配置。", en: "Copied. Merge with existing hooks and keep your other settings.") }
    static var claudeConfigurationHelp: String { localized(zh: "复制配置不会修改 Claude Code。移动应用或 Python 后需更新命令路径。", en: "Copying does not change Claude Code. Update the command if you move the app or Python.") }
    static var claudeHelperMissing: String { localized(zh: "请从包含接入脚本的完整应用包中复制配置。", en: "Copy the configuration from a complete app bundle with the hook script.") }
    static func claudeReceiverState(_ state: ClaudeCompletionReceiver.State) -> String {
        switch state {
        case .disabled: localized(zh: "本地接入已关闭", en: "Local connection is off")
        case .starting: localized(zh: "正在准备本地接入…", en: "Preparing local connection…")
        case .listening: localized(zh: "本地接入已就绪", en: "Local connection is ready")
        case .failed: localized(zh: "本地接入失败，请关闭后重试", en: "Local connection failed. Turn it off and try again")
        }
    }
}
