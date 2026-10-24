import AppKit
import SwiftUI
import XCTest
@testable import XNook

@MainActor
final class LyricsDetailsPreviewTests: XCTestCase {
    func testLyricsDetailsAndMediaOverviewFitInBothLanguagesAndAppearances() async throws {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("需要隔离歌词详情渲染")
        }
        _ = NSApplication.shared
        let previousArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }
        let suite = "XNook.LyricsDetailsPreview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SettingsDefaults.register(on: defaults)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/feature-reintegration-20261024/media-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for language in ["zh", "en"] {
            var arguments = previousArguments
            arguments["appLanguage"] = language
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            for scenario in ["synced", "failed", "disabled", "refreshFailed", "refreshNoMatch"] {
                defaults.set(scenario != "disabled", forKey: "showLyrics")
                let lyrics = LyricsManager(defaults: defaults,
                    loadRequest: { request in
                        if scenario == "refreshNoMatch" {
                            let exact = request.url!.path.hasSuffix("/get")
                            return (Data((exact ? "{}" : "[]").utf8), HTTPURLResponse(url: request.url!, statusCode: exact ? 404 : 200, httpVersion: nil, headerFields: nil)!)
                        }
                        throw URLError(.notConnectedToInternet)
                    },
                    readCache: { _, _, _ in
                        ["synced", "refreshFailed", "refreshNoMatch"].contains(scenario) ? LyricsCache.Entry(type: .synced,
                            payload: "[00:00.00]这是用于检查详情的示例歌词 A sample lyric for layout",
                            fetchedAt: Date(), key: "preview") : nil
                    }, writeCache: { _, _, _, _, _, _ in }, sleep: { _ in })
                let media = MediaManager(startMonitoring: false, defaults: defaults, lyricsManager: lyrics,
                    infoProvider: { ["title": "示例歌曲 · A song with a long title", "artist": "示例歌手",
                        "album": "Preview", "duration": 180.0, "playbackRate": 0.0,
                        "playerPosition": 1.0, "positionTimestamp": Date()] },
                    artworkProvider: { _ in nil }, commandSender: { _ in XCTFail("渲染不能控制播放器") })
                await media.refreshNowPlayingInfo()
                for _ in 0..<200 {
                    if !lyrics.isFetching { break }
                    try await Task.sleep(for: .milliseconds(1))
                }
                XCTAssertFalse(lyrics.isFetching)
                if scenario.hasPrefix("refresh") {
                    XCTAssertTrue(lyrics.retryCurrentTrack())
                    for _ in 0..<200 {
                        if !lyrics.isFetching { break }
                        try await Task.sleep(for: .milliseconds(1))
                    }
                    XCTAssertFalse(lyrics.isFetching)
                    XCTAssertEqual(lyrics.refreshNotice, scenario == "refreshFailed" ? .failedKeepingCurrent : .noMatchKeepingCurrent)
                }
                let expected: LyricsStatus = ["synced", "refreshFailed", "refreshNoMatch"].contains(scenario) ? .synced : scenario == "failed" ? .failed : .disabled
                XCTAssertEqual(lyrics.status, expected)

                for scheme in [ColorScheme.light, .dark] {
                    let suffix = "\(language)-\(scenario)-\(scheme == .dark ? "dark" : "light")"
                    try render(LyricsDetailsView(mediaManager: media, onClose: {}),
                        size: NSSize(width: 340, height: 460), scheme: scheme,
                        defaults: defaults, path: directory.appendingPathComponent("details-\(suffix).png"))
                    if scenario == "synced" {
                        try render(MediaWidgetView(mediaManager: media),
                            size: NSSize(width: 290, height: 160), scheme: scheme,
                            defaults: defaults, path: directory.appendingPathComponent("media-\(language)-\(scheme == .dark ? "dark" : "light").png"))
                    }
                }
            }
        }
        XCTAssertEqual(defaults.double(forKey: "panelBaseHeight"), 200)
        XCTAssertEqual(defaults.double(forKey: "panelWidth"), 800)
    }

    private func render<Content: View>(
        _ content: Content, size: NSSize, scheme: ColorScheme,
        defaults: UserDefaults, path: URL
    ) throws {
        let hosting = NSHostingView(rootView: content
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(hosting.bounds.size, size)
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1500)
        try png.write(to: path, options: .atomic)
    }
}
