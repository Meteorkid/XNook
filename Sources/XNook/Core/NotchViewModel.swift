import SwiftUI
import Combine

/// Notch 区域的状态管理
@MainActor
final class NotchViewModel: ObservableObject {
    // MARK: - 状态枚举

    enum NotchState: Equatable {
        case collapsed       // 收起状态（小药丸）
        case expanded        // 展开状态
        case switching       // 切换动画中
    }

    // MARK: - Published Properties

    @Published var currentState: NotchState = .collapsed
    @Published var currentApp: SupportedApp = .xnook

    // MARK: - 支持的应用

    enum SupportedApp: String, CaseIterable {
        case xnook = "X Nook"
        case xisland = "X Island"

        var bundleID: String {
            switch self {
            case .xnook: return "com.meteorkid.xnook"
            case .xisland: return "com.meteorkid.xisland"
            }
        }

        var icon: String {
            switch self {
            case .xnook: return "square.grid.2x2"
            case .xisland: return "sparkle"
            }
        }

        var next: SupportedApp {
            switch self {
            case .xnook: return .xisland
            case .xisland: return .xnook
            }
        }
    }

    // MARK: - Init

    init() {
        detectCurrentApp()
    }

    // MARK: - Methods

    /// 检测当前运行的是哪个应用
    private func detectCurrentApp() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        if bundleID.contains("xnook") {
            currentApp = .xnook
        } else {
            currentApp = .xisland
        }
    }

    /// 切换到另一个应用
    func switchToOtherApp() {
        currentApp = currentApp.next
        AppSwitcher.shared.switchToOtherApp()
    }

    /// 展开 Notch
    func expand() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            currentState = .expanded
        }
    }

    /// 收起 Notch
    func collapse() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            currentState = .collapsed
        }
    }

    /// 切换展开/收起
    func toggleExpansion() {
        switch currentState {
        case .collapsed:
            expand()
        case .expanded:
            collapse()
        case .switching:
            break
        }
    }
}
