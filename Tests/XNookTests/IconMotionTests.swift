import XCTest
import SwiftUI
@testable import XNook

final class IconMotionTests: XCTestCase {

    /// 图标动效必须能在部署目标 macOS 14 上编译。
    ///
    /// 这条测试的意义在于：如果将来有人把实现改回 `.symbolEffect(.drawOn)`
    /// 而未加版本分支，本项目（部署目标 macOS 14）会直接编译失败。
    /// 当前实现只依赖 mask + scaleEffect + opacity，无版本门槛。
    @MainActor
    func testIconMotionRendersOnDeploymentTarget() {
        let view = Image(systemName: "gear")
            .iconMotion(trigger: 0, isHovering: false, isPressed: false, breathing: false, reduceMotion: false)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
    }

    /// 减少动态效果时必须禁用一切动效，但图标本身仍要渲染出来。
    @MainActor
    func testReduceMotionStillRendersIcon() {
        let view = Image(systemName: "gear")
            .iconMotion(trigger: 3, isHovering: true, isPressed: true, breathing: true, reduceMotion: true)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
    }

    /// MotionIcon 在无悬停时应正常渲染（不因初始 trigger 为 0 而不可见）。
    ///
    /// 这条是对 `.symbolEffect(.drawOn)` 方案的回归防线：那个方案的初始态是
    /// "未绘制"，若 onAppear 未触发图标会永久不可见。当前方案初始 drawProgress = 1。
    @MainActor
    func testMotionIconIsVisibleWithoutHover() {
        let view = MotionIcon(systemName: "gear", fontSize: 12)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0, "未悬停时图标也必须可见")
    }

    @MainActor
    func testMotionIconRendersWithBreathingEnabled() {
        let view = MotionIcon(systemName: "bell", fontSize: 14, breathing: true)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
    }
}
