import AppKit
import SwiftUI
import XCTest
@testable import XNook

@MainActor
final class IconMotionTests: XCTestCase {
    func testScaleOnlyButtonsKeepExistingMediaTargetSizesAndVisibleGlyphs() throws {
        try requireRendering()
        for scheme in [ColorScheme.dark, .light] {
            for icon in ["backward.fill", "play.fill", "pause.fill", "forward.fill", "chevron.right"] {
                let isDetails = icon == "chevron.right"
                let size = isDetails ? CGSize(width: 28, height: 24) : CGSize(width: 37, height: 37)
                var calls = 0
                let button = ScaleOnlyButton(reduceMotion: false, hitPadding: isDetails ? 2 : 0, action: { calls += 1 }) {
                    Image(systemName: icon)
                        .font(.system(size: isDetails ? 10 : 16, weight: .medium))
                        .frame(width: size.width, height: size.height)
                }
                let fixture = makeHost(button, scheme: scheme)
                defer { fixture.window.contentView = nil; fixture.window.close() }
                settle(fixture.host)
                XCTAssertEqual(fixture.host.fittingSize.width, size.width + 16, accuracy: 0.1)
                XCTAssertEqual(fixture.host.fittingSize.height, size.height + 16, accuracy: 0.1)
                XCTAssertGreaterThan(try pixels(in: fixture.host, scheme: scheme).ink, 8)
                XCTAssertEqual(calls, 0, "布局和渲染不得触发播放或跳转动作")
                XCTAssertFalse(fixture.window.isVisible)
            }
        }
    }

    /// 悬停输入由夹具驱动；真实鼠标与按压另行验收，不发送任何桌面事件。
    func testReducedMotionAndDisabledButtonsStayStationaryAcrossRepeatedHover() throws {
        try requireRendering()
        for scheme in [ColorScheme.dark, .light] {
            for (reduced, enabled) in [(true, true), (false, false)] {
                let state = MediaHoverFixtureState()
                let fixture = makeHost(MediaHoverFixture(state: state, reduced: reduced)
                    .disabled(!enabled), scheme: scheme)
                defer { fixture.window.contentView = nil; fixture.window.close() }
                settle(fixture.host)
                let size = fixture.host.fittingSize
                let baseline = try pixels(in: fixture.host, scheme: scheme)
                XCTAssertGreaterThan(baseline.ink, 8, "禁用或减少动态时仍应能看见按钮")
                for hovering in [true, false, true, false] {
                    state.hovering = hovering
                    settle(fixture.host)
                    let current = try pixels(in: fixture.host, scheme: scheme)
                    XCTAssertEqual(current.bytes, baseline.bytes, "减少动态或禁用状态不应随悬停改变像素")
                    XCTAssertEqual(fixture.host.fittingSize.width, size.width, accuracy: 0.1)
                    XCTAssertEqual(fixture.host.fittingSize.height, size.height, accuracy: 0.1)
                }
                XCTAssertFalse(fixture.window.isVisible)
            }
        }
    }

    private func requireRendering() throws {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("需要隔离按钮缩放渲染验证")
        }
        _ = NSApplication.shared
    }

    private func makeHost<V: View>(_ content: V, scheme: ColorScheme) -> (host: NSView, window: NSWindow) {
        let host = NSHostingView(rootView: content.foregroundStyle(.primary).padding(8)
            .background(scheme == .dark ? Color.black : Color.white)
            .environment(\.colorScheme, scheme))
        let size = host.fittingSize
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        return (host, window)
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.16))
        host.layoutSubtreeIfNeeded()
    }

    private func pixels(in host: NSView, scheme: ColorScheme) throws -> (bytes: [UInt8], ink: Int) {
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        var bytes: [UInt8] = []
        var ink = 0
        let background: CGFloat = scheme == .dark ? 0 : 1
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                let color = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let channels = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
                bytes.append(contentsOf: channels.map { UInt8((min(1, max(0, $0)) * 255).rounded()) })
                let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                if color.alphaComponent > 0.5 && abs(brightness - background) > 0.12 { ink += 1 }
            }
        }
        return (bytes, ink)
    }
}

@MainActor
private final class MediaHoverFixtureState: ObservableObject {
    @Published var hovering = false
}

@MainActor
private struct MediaHoverFixture: View {
    @ObservedObject var state: MediaHoverFixtureState
    let reduced: Bool

    var body: some View {
        Button {} label: {
            Image(systemName: "play.fill")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 37, height: 37)
        }
        .buttonStyle(ScaleOnlyButtonStyle(isHovering: state.hovering, reduceMotion: reduced))
        .contentShape(Rectangle())
    }
}
