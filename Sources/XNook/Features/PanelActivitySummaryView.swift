import SwiftUI

struct PanelActivitySummaryView: View {
    let event: PanelActivityEvent
    let onDismiss: () -> Void
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(event.kind == .failure ? Color.orange : Color.accentColor)
            Text(event.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(event.title)
            if event.action != .none {
                Button(action: onAction) { Image(systemName: "arrow.up.forward.square") }
                    .help(L10n.activityOpenCalendar)
                    .accessibilityLabel(L10n.activityOpenCalendar)
            }
            Button(L10n.activityDismissShort, action: onDismiss)
                .help(L10n.activityDismiss)
                .accessibilityLabel(L10n.activityDismiss)
        }
        .font(.system(size: 10, weight: .medium))
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch event.kind {
        case .failure: "exclamationmark.circle"
        case .deadline: "calendar.badge.clock"
        case .completion: "checkmark.circle"
        case .information: "info.circle"
        }
    }
}
