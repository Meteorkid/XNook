import SwiftUI

/// NookFlow 区域视图 — 三态自适应
///
/// 显示策略：
/// - 有 activeSession：任务卡片（标题、开始时间、时长、关联笔记入口、关联文件架入口、结束任务按钮）
/// - 无 activeSession 但 history 非空：最近 1–3 条任务记录
/// - 两者皆空：EmptyView（不占布局，由父视图条件渲染避免调用）
struct FocusSessionView: View {
    @Environment(\.colorScheme) private var colorScheme

    let manager: FocusSessionManager
    /// 当前文件架文件数量，由 NotchContentView 传入，用于空态反馈
    let trayFileCount: Int
    // 由 NotchContentView 提供的协调回调（关联操作立即写入快照）
    let onCreateLinkedNote: () -> Void
    let onLinkTrayFiles: () -> Void
    let onEndSession: () -> Void

    var body: some View {
        if let session = manager.activeSession {
            activeCard(for: session)
        } else if !manager.history.isEmpty {
            historyList
        } else {
            // 理论上父视图已条件渲染，此处保留安全兜底
            EmptyView()
        }
    }

    // MARK: - 活跃任务卡片

    private func activeCard(for session: FocusSession) -> some View {
        VStack(spacing: 6) {
            // 标题行
            HStack(spacing: 4) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.green)
                Text(session.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text("进行中")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
            }

            // 时间行：开始时间 + 已进行时长（TimelineView 安全刷新）
            HStack(spacing: 6) {
                Text(startTimeString(from: session.startedAt))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(IslandStyle.tertiaryText(for: colorScheme))
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsedString(from: session.startedAt, to: context.date))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(IslandStyle.tertiaryText(for: colorScheme))
                }
            }

            // 关联状态 + 操作按钮
            HStack(spacing: 6) {
                // 关联笔记：已关联时显示标题并禁用，避免重复创建
                noteButton(for: session)

                // 关联文件架：文件架为空时禁用并提示
                trayButton(for: session)

                Spacer()

                // 结束任务
                Button(action: onEndSession) {
                    Text("结束任务")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.red.opacity(0.2))
                        .foregroundStyle(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 按钮构建

    /// 关联笔记按钮：已关联时显示"已关联：<标题>"并禁用，避免重复创建
    private func noteButton(for session: FocusSession) -> some View {
        let isLinked = session.linkedNote != nil
        let title = isLinked ? "已关联：\(session.linkedNote?.title ?? "")" : "创建关联笔记"
        return Button(action: { if !isLinked { onCreateLinkedNote() } }) {
            HStack(spacing: 3) {
                Image(systemName: isLinked ? "checkmark.circle.fill" : "note.text")
                    .font(.system(size: 9))
                Text(title)
                    .font(.system(size: 9))
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(IslandStyle.insetFill(for: colorScheme))
            .foregroundStyle(isLinked ? IslandStyle.secondaryText : IslandStyle.primaryText)
            .opacity(isLinked ? 0.6 : 1.0)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(isLinked)
    }

    /// 关联文件架按钮：文件架为空时显示"文件架为空"并禁用
    private func trayButton(for session: FocusSession) -> some View {
        let isTrayEmpty = trayFileCount == 0
        let title = isTrayEmpty
            ? "文件架为空"
            : (session.linkedFiles.isEmpty ? "关联文件架" : "文件 \(session.linkedFiles.count)")
        return Button(action: { if !isTrayEmpty { onLinkTrayFiles() } }) {
            HStack(spacing: 3) {
                Image(systemName: isTrayEmpty ? "tray" : "tray.full")
                    .font(.system(size: 9))
                Text(title)
                    .font(.system(size: 9))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(IslandStyle.insetFill(for: colorScheme))
            .foregroundStyle(isTrayEmpty ? IslandStyle.secondaryText : IslandStyle.primaryText)
            .opacity(isTrayEmpty ? 0.6 : 1.0)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(isTrayEmpty)
    }

    // MARK: - 历史记录列表

    private var historyList: some View {
        VStack(spacing: 4) {
            // 标题行
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 9))
                    .foregroundStyle(IslandStyle.secondaryText)
                Text("最近任务")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(IslandStyle.secondaryText)
                Spacer()
            }

            ForEach(manager.history.prefix(3)) { record in
                historyRow(record)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func historyRow(_ record: FocusSession) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.gray.opacity(0.4))
                .frame(width: 4, height: 4)

            Text(record.title)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)

            Spacer()

            // 关联数量摘要
            HStack(spacing: 3) {
                if record.linkedNote != nil {
                    Image(systemName: "note.text")
                        .font(.system(size: 8))
                }
                if !record.linkedFiles.isEmpty {
                    Text("\(record.linkedFiles.count)")
                        .font(.system(size: 8, design: .monospaced))
                }
            }
            .foregroundStyle(IslandStyle.tertiaryText(for: colorScheme))

            // 结束时间
            if let endedAt = record.endedAt {
                Text(endTimeString(from: endedAt))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(IslandStyle.tertiaryText(for: colorScheme))
            }
        }
    }

    // MARK: - 时间格式化

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func startTimeString(from date: Date) -> String {
        "开始 \(Self.timeFormatter.string(from: date))"
    }

    private func endTimeString(from date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    /// 已进行时长，格式 mm:ss 或 h:mm:ss
    private func elapsedString(from start: Date, to now: Date) -> String {
        let interval = max(0, now.timeIntervalSince(start))
        let total = Int(interval)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
