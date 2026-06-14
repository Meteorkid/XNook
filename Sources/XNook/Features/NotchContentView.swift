import SwiftUI

/// Notch 主内容视图
struct NotchContentView: View {
    @StateObject private var viewModel = NotchViewModel()
    @StateObject private var mediaManager = MediaManager()
    @StateObject private var calendarManager = CalendarManager()
    @State private var selectedWidget: WidgetType?

    enum WidgetType: String {
        case media
        case calendar
        case notes
        case tray
    }

    var body: some View {
        VStack(spacing: 0) {
            // 主内容区
            GeometryReader { geometry in
                ZStack {
                    // 背景
                    RoundedRectangle(cornerRadius: viewModel.currentState == .expanded ? 20 : 16)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: viewModel.currentState == .expanded ? 20 : 16)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )

                    // 内容
                    if viewModel.currentState == .expanded {
                        expandedContent
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        collapsedContent
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(
                    width: viewModel.currentState == .expanded ? 400 : 180,
                    height: viewModel.currentState == .expanded ? 200 : 32
                )
                .position(
                    x: geometry.size.width / 2,
                    y: geometry.size.height / 2
                )
            }

            // 底部指示器（展开时显示）
            if viewModel.currentState == .expanded {
                appSwitcherIndicator
                    .padding(.top, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.currentState)
        .onHover { isHovered in
            if isHovered && viewModel.currentState == .collapsed {
                viewModel.expand()
            }
        }
    }

    // MARK: - 收起状态（小药丸）

    private var collapsedContent: some View {
        HStack(spacing: 6) {
            // 应用图标
            Image(systemName: viewModel.currentApp.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)

            // 分隔线
            Circle()
                .fill(Color.white.opacity(0.5))
                .frame(width: 3, height: 3)

            // 应用名称缩写
            Text(viewModel.currentApp == .xnook ? "N" : "I")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onTapGesture {
            viewModel.toggleExpansion()
        }
    }

    // MARK: - 展开状态

    private var expandedContent: some View {
        VStack(spacing: 12) {
            // 顶部栏
            HStack {
                // 当前应用标识
                HStack(spacing: 8) {
                    Image(systemName: viewModel.currentApp.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.accentColor)

                    Text(viewModel.currentApp.rawValue)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                }

                Spacer()

                // 切换按钮
                Button(action: {
                    viewModel.switchToOtherApp()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 11))
                        Text("Switch to \(viewModel.currentApp.next.rawValue)")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.15))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                // 关闭按钮
                Button(action: {
                    viewModel.collapse()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // 功能预览区
            if let widget = selectedWidget {
                // 显示选中的 Widget
                Group {
                    switch widget {
                    case .media:
                        MediaWidgetView(mediaManager: mediaManager)
                    case .calendar:
                        CalendarWidgetView(calendarManager: calendarManager)
                    case .notes:
                        Text("Notes Widget")
                    case .tray:
                        Text("Tray Widget")
                    }
                }
                .transition(.scale.combined(with: .opacity))
            } else if viewModel.currentApp == .xnook {
                xnookPreview
            } else {
                xislandPreview
            }
        }
        .padding(16)
    }

    // MARK: - X Nook 预览

    private var xnookPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("X Nook - 工具中心")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 8) {
                FeatureButton(icon: "play.fill", title: "Media", color: .pink)
                    .onTapGesture {
                        withAnimation {
                            selectedWidget = .media
                        }
                    }
                FeatureButton(icon: "calendar", title: "Calendar", color: .blue)
                    .onTapGesture {
                        withAnimation {
                            selectedWidget = .calendar
                        }
                    }
                FeatureButton(icon: "note.text", title: "Notes", color: .yellow)
                    .onTapGesture {
                        withAnimation {
                            selectedWidget = .notes
                        }
                    }
                FeatureButton(icon: "tray.full", title: "Tray", color: .green)
                    .onTapGesture {
                        withAnimation {
                            selectedWidget = .tray
                        }
                    }
                FeatureButton(icon: "shortcuts", title: "Shortcuts", color: .purple)
                FeatureButton(icon: "camera.fill", title: "Mirror", color: .cyan)
            }

            // 返回按钮（当选中 Widget 时显示）
            if selectedWidget != nil {
                Button(action: {
                    withAnimation {
                        selectedWidget = nil
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10))
                        Text("Back")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - X Island 预览

    private var xislandPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("X Island - AI Agent")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            VStack(spacing: 6) {
                AgentStatusRow(name: "Claude Code", status: "Working", color: .blue)
                AgentStatusRow(name: "Cursor", status: "Idle", color: .green)
            }
        }
    }

    // MARK: - 应用切换指示器

    private var appSwitcherIndicator: some View {
        HStack(spacing: 12) {
            // 左箭头
            Image(systemName: "chevron.left")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(viewModel.currentApp == .xnook ? .primary : .secondary)

            // 圆点指示器
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.currentApp == .xnook ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)

                Circle()
                    .fill(viewModel.currentApp == .xisland ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
            }

            // 右箭头
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(viewModel.currentApp == .xisland ? .primary : .secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
        .onTapGesture {
            viewModel.switchToOtherApp()
        }
    }
}

// MARK: - 辅助视图

struct FeatureButton: View {
    let icon: String
    let title: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(color)
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

struct AgentStatusRow: View {
    let name: String
    let status: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(name)
                .font(.system(size: 12, weight: .medium))

            Spacer()

            Text(status)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(6)
    }
}

// MARK: - Preview

#Preview {
    NotchContentView()
        .frame(width: 400, height: 250)
        .background(Color.black)
}
