import AppKit
import SwiftUI
import XCTest
@testable import XNook

@MainActor
final class PanelHeaderButtonTests: XCTestCase {
    func testProductionHeaderIconsRemainVisibleInBothAppearances() throws {
        try requireRendering()
        for scheme in [ColorScheme.dark, .light] {
            for reduced in [false, true] {
                for icon in ["gearshape", "xmark"] {
                    let button = PanelHeaderButton(icon: icon, title: icon, reduceMotion: reduced, action: {})
                    let fixture = makeHost(button, scheme: scheme)
                    defer { fixture.window.contentView = nil; fixture.window.close() }
                    settle(fixture.host)
                    XCTAssertEqual(fixture.host.fittingSize.width, 42, accuracy: 0.1)
                    XCTAssertEqual(fixture.host.fittingSize.height, 42, accuracy: 0.1)
                    let bitmap = try snapshot(fixture.host)
                    XCTAssertGreaterThan(inkPixels(bitmap, scheme: scheme), 8, "生产按钮必须实际绘出图标")
                    if !reduced {
                        try save(bitmap, name: "production-\(icon)-\(scheme == .dark ? "dark" : "light")")
                    }
                    XCTAssertFalse(fixture.window.isVisible)
                }
            }
        }
    }

    /// 直接驱动生产 ButtonStyle 的悬停输入；不将受控状态等同于真实鼠标路径验收。
    func testControlledHoverTransitionsKeepGlyphsVisibleWithoutChangingLayout() throws {
        try requireRendering()
        for scheme in [ColorScheme.dark, .light] {
            for reduced in [false, true] {
                let state = HeaderHoverFixtureState()
                let fixture = makeHost(HeaderHoverFixture(state: state, reduced: reduced), scheme: scheme)
                defer { fixture.window.contentView = nil; fixture.window.close() }
                settle(fixture.host)
                let initialSize = fixture.host.fittingSize
                let baseline = inkPixels(try snapshot(fixture.host), scheme: scheme)
                XCTAssertGreaterThan(baseline, 8)
                for (index, hovering) in [true, false, true, false].enumerated() {
                    state.hovering = hovering
                    for delay in [0.0, 0.025, 0.16] {
                        settle(fixture.host, delay: delay)
                        XCTAssertEqual(fixture.host.fittingSize.width, initialSize.width, accuracy: 0.1)
                        XCTAssertEqual(fixture.host.fittingSize.height, initialSize.height, accuracy: 0.1)
                        let bitmap = try snapshot(fixture.host)
                        let visible = inkPixels(bitmap, scheme: scheme)
                        XCTAssertGreaterThan(visible, baseline / 2, "进入或离开时不得先擦掉图标露出底色")
                        if reduced { XCTAssertEqual(visible, baseline, "减少动态效果时图标像素应保持稳定") }
                        if index == 0 && delay == 0.16 && !reduced {
                            try save(bitmap, name: "controlled-hover-\(scheme == .dark ? "dark" : "light")")
                        }
                    }
                }
                XCTAssertFalse(fixture.window.isVisible)
            }
        }
    }

    func testProductionButtonExposesAnExecutableActionWhenHostAccessibilityIsAvailable() throws {
        try requireRendering()
        for icon in ["gearshape", "xmark"] {
            var calls = 0
            let label = "Header action \(icon)"
            let fixture = makeHost(PanelHeaderButton(icon: icon, title: label, reduceMotion: false) {
                calls += 1
            }, scheme: .dark)
            defer { fixture.window.contentView = nil; fixture.window.close() }
            settle(fixture.host)
            if let button = nativeViews(in: fixture.host).compactMap({ $0 as? NSButton }).first {
                button.performClick(nil)
            } else if let button = accessibilityElements(in: fixture.host).first(where: {
                $0.accessibilityRole() == .button && $0.accessibilityLabel() == label
            }) {
                XCTAssertTrue(button.accessibilityPerformPress())
            } else {
                throw XCTSkip("离屏宿主没有公开按钮动作；渲染通过不等于真实点击验收")
            }
            XCTAssertEqual(calls, 1, "原生或辅助功能按钮动作只应调用一次业务回调")
            XCTAssertFalse(fixture.window.isVisible)
        }
    }

    private func requireRendering() throws {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("需要隔离头部按钮渲染验证")
        }
        _ = NSApplication.shared
    }

    private func makeHost<V: View>(_ view: V, scheme: ColorScheme) -> (host: NSView, window: NSWindow) {
        let host = NSHostingView(rootView: view.padding(8)
            .background(scheme == .dark ? Color.black : Color.white)
            .environment(\.colorScheme, scheme))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        return (host, window)
    }

    private func settle(_ host: NSView, delay: TimeInterval = 0.03) {
        host.layoutSubtreeIfNeeded()
        if delay > 0 { RunLoop.main.run(until: Date().addingTimeInterval(delay)) }
        host.layoutSubtreeIfNeeded()
    }

    private func snapshot(_ host: NSView) throws -> NSBitmapImageRep {
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        return image
    }

    private func inkPixels(_ image: NSBitmapImageRep, scheme: ColorScheme) -> Int {
        var count = 0
        let background: CGFloat = scheme == .dark ? 0 : 1
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                if color.alphaComponent > 0.5 && abs(brightness - background) > 0.25 { count += 1 }
            }
        }
        return count
    }

    private func save(_ image: NSBitmapImageRep, name: String) throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/header-hover-20261025/ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }

    private func nativeViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { nativeViews(in: $0) }
    }

    private func accessibilityElements(in host: NSView) -> [NSAccessibilityProtocol] {
        var visited = Set<ObjectIdentifier>()
        func collect(_ value: Any) -> [NSAccessibilityProtocol] {
            guard let element = value as? NSAccessibilityProtocol,
                  visited.insert(ObjectIdentifier(element as AnyObject)).inserted else { return [] }
            return [element] + (element.accessibilityChildren() ?? []).flatMap(collect)
        }
        return nativeViews(in: host).flatMap(collect)
    }
}

@MainActor
private final class HeaderHoverFixtureState: ObservableObject {
    @Published var hovering = false
}

@MainActor
private struct HeaderHoverFixture: View {
    @ObservedObject var state: HeaderHoverFixtureState
    let reduced: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(["gearshape", "xmark"], id: \.self) { icon in
                Button {} label: {
                    Image(systemName: icon)
                        .font(.system(size: IslandTokens.Font.body, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(PanelHeaderButtonStyle(isHovering: state.hovering, reduceMotion: reduced))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
            }
        }
    }
}
