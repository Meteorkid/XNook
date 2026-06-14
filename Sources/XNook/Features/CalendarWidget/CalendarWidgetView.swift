import SwiftUI
import EventKit

/// 日历 Widget 视图
struct CalendarWidgetView: View {
    @ObservedObject var calendarManager: CalendarManager

    var body: some View {
        VStack(spacing: 12) {
            // 标题
            HStack {
                Image(systemName: "calendar")
                    .font(.system(size: 12))
                    .foregroundColor(.blue)
                Text("Upcoming Events")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }

            if !calendarManager.hasAccess {
                // 无权限提示
                VStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                    Text("Calendar access required")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Button("Grant Access") {
                        Task {
                            await calendarManager.requestAccess()
                        }
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else if calendarManager.upcomingEvents.isEmpty {
                // 无事件提示
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                    Text("No upcoming events")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                // 事件列表
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(calendarManager.upcomingEvents.prefix(5), id: \.eventIdentifier) { event in
                            EventRow(event: event)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .padding(16)
        .frame(width: 250)
    }
}

// MARK: - Event Row

struct EventRow: View {
    let event: EKEvent

    var body: some View {
        HStack(spacing: 10) {
            // 时间指示器
            VStack(spacing: 2) {
                Text(timeString(from: event.startDate))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.blue)
                Text(dateString(from: event.startDate))
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
            .frame(width: 40)

            // 事件信息
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title ?? "Untitled")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .foregroundColor(.primary)

                if let location = event.location, !location.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin")
                            .font(.system(size: 8))
                        Text(location)
                            .font(.system(size: 9))
                    }
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }
            }

            Spacer()

            // 打开按钮
            Button(action: {
                openEventInCalendar()
            }) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(6)
    }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"
        return formatter.string(from: date)
    }

    private func openEventInCalendar() {
        // 打开系统日历
        if let url = URL(string: "calshow:") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Preview

#Preview {
    CalendarWidgetView(calendarManager: CalendarManager())
        .background(Color.black)
}
