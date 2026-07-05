import XCTest
@testable import XNook

@MainActor
final class UpdateManagerTests: XCTestCase {
    func testParsesGitHubReleasePayload() throws {
        let data = #"{"tag_name":"v1.2.6","html_url":"https://example.com/release","published_at":"2026-04-14T12:00:00Z","assets":[]}"#.data(using: .utf8)!
        let release = try UpdateManager.githubReleaseDecoder.decode(UpdateManager.ReleaseInfo.self, from: data)

        XCTAssertEqual(release.tagName, "v1.2.6")
        XCTAssertEqual(release.htmlURL, URL(string: "https://example.com/release"))
        XCTAssertEqual(release.normalizedVersion, "1.2.6")
    }

    func testApplyCheckResultTransitionsToUpdateAvailable() throws {
        let manager = UpdateManager()
        let currentVersion = manager.currentVersion
        let remoteVersion = bumpedPatchVersion(from: currentVersion)
        let data = #"{"tag_name":"\#(remoteVersion)","html_url":"https://example.com/release","published_at":"2026-04-14T12:00:00Z","assets":[]}"#.data(using: .utf8)!
        let release = try UpdateManager.githubReleaseDecoder.decode(UpdateManager.ReleaseInfo.self, from: data)

        manager.applyCheckResult(release)

        XCTAssertEqual(manager.latestRelease?.tagName, remoteVersion)
        XCTAssertEqual(manager.state, .updateAvailable(version: UpdateManager.normalize(version: remoteVersion)))
        XCTAssertNotNil(manager.lastCheckedAt)
    }

    func testApplyCheckResultTransitionsToUpToDateForCurrentVersion() throws {
        let manager = UpdateManager()
        let data = #"{"tag_name":"v\#(manager.currentVersion)","html_url":"https://example.com/release","published_at":"2026-04-14T12:00:00Z","assets":[]}"#.data(using: .utf8)!
        let release = try UpdateManager.githubReleaseDecoder.decode(UpdateManager.ReleaseInfo.self, from: data)

        manager.applyCheckResult(release)

        XCTAssertEqual(manager.state, .upToDate)
        XCTAssertEqual(manager.latestRelease?.normalizedVersion, manager.currentVersion)
    }

    func testCheckForUpdatesClearsStaleReleaseOnDecodeFailure() async throws {
        let manager = UpdateManager(fetchReleaseData: {
            Data("not valid json".utf8)
        })
        let staleData = #"{"tag_name":"v9.9.9","html_url":"https://example.com/release","published_at":"2026-04-14T12:00:00Z","assets":[]}"#.data(using: .utf8)!
        manager.latestRelease = try UpdateManager.githubReleaseDecoder.decode(UpdateManager.ReleaseInfo.self, from: staleData)

        await manager.checkForUpdates()

        XCTAssertNil(manager.latestRelease)
        XCTAssertEqual(manager.state, .failed(message: L10n.updateCheckFailed))
        XCTAssertNotNil(manager.lastCheckedAt)
    }

    // MARK: - normalize

    func testNormalizeStripsVPrefix() {
        XCTAssertEqual(UpdateManager.normalize(version: "v1.2.3"), "1.2.3")
    }

    func testNormalizeStripsCapitalVPrefix() {
        XCTAssertEqual(UpdateManager.normalize(version: "V1.2.3"), "1.2.3")
    }

    func testNormalizeTrimsWhitespace() {
        XCTAssertEqual(UpdateManager.normalize(version: " v1.2.3 "), "1.2.3")
    }

    func testNormalizeNoPrefix() {
        XCTAssertEqual(UpdateManager.normalize(version: "1.2.3"), "1.2.3")
    }

    // MARK: - isRemoteVersionNewer

    func testRemoteNewerPatch() {
        XCTAssertTrue(UpdateManager.isRemoteVersionNewer("1.2.4", than: "1.2.3"))
    }

    func testRemoteOlder() {
        XCTAssertFalse(UpdateManager.isRemoteVersionNewer("1.2.3", than: "1.2.4"))
    }

    func testRemoteEqual() {
        XCTAssertFalse(UpdateManager.isRemoteVersionNewer("1.2.3", than: "1.2.3"))
    }

    func testRemoteNewerMajor() {
        XCTAssertTrue(UpdateManager.isRemoteVersionNewer("2.0.0", than: "1.9.9"))
    }

    func testRemoteNewerMinor() {
        XCTAssertTrue(UpdateManager.isRemoteVersionNewer("1.3.0", than: "1.2.9"))
    }

    func testRemoteShorterVersionTreatedAsOlder() {
        // "1.2" should be treated as "1.2.0", which is older than "1.2.3"
        XCTAssertFalse(UpdateManager.isRemoteVersionNewer("1.2", than: "1.2.3"))
    }

    func testRemoteLongerVersionTreatedAsNewer() {
        // "1.2.3.1" should be newer than "1.2.3"
        XCTAssertTrue(UpdateManager.isRemoteVersionNewer("1.2.3.1", than: "1.2.3"))
    }

    func testInvalidVersionReturnsFalse() {
        XCTAssertFalse(UpdateManager.isRemoteVersionNewer("abc", than: "1.2.3"))
        XCTAssertFalse(UpdateManager.isRemoteVersionNewer("1.2.3", than: "xyz"))
    }

    func testEmptyVersionReturnsFalse() {
        XCTAssertFalse(UpdateManager.isRemoteVersionNewer("", than: "1.2.3"))
        XCTAssertFalse(UpdateManager.isRemoteVersionNewer("1.2.3", than: ""))
    }

    // MARK: - applyCheckResult with older remote

    func testApplyCheckResultWithOlderRemoteSetsUpToDate() throws {
        let manager = UpdateManager()
        let data = #"{"tag_name":"v0.0.1","html_url":"https://example.com/release","published_at":"2026-04-14T12:00:00Z","assets":[]}"#.data(using: .utf8)!
        let release = try UpdateManager.githubReleaseDecoder.decode(UpdateManager.ReleaseInfo.self, from: data)

        manager.applyCheckResult(release)

        XCTAssertEqual(manager.state, .upToDate)
    }

    // MARK: - ReleaseInfo.dmgURL

    func testDmgURLPicksFirstDmgAsset() throws {
        let data = """
        {"tag_name":"v1.0.0","html_url":"https://example.com","published_at":"2026-04-14T12:00:00Z",
         "assets":[{"name":"not-a-dmg.zip","browser_download_url":"https://example.com/zip"},
                   {"name":"1.0.0.dmg","browser_download_url":"https://example.com/dmg"}]}
        """.data(using: .utf8)!
        let release = try UpdateManager.githubReleaseDecoder.decode(UpdateManager.ReleaseInfo.self, from: data)
        XCTAssertEqual(release.dmgURL, URL(string: "https://example.com/dmg"))
    }

    func testDmgURLReturnsNilWhenNoDmg() throws {
        let data = """
        {"tag_name":"v1.0.0","html_url":"https://example.com","published_at":"2026-04-14T12:00:00Z",
         "assets":[{"name":"not-a-dmg.zip","browser_download_url":"https://example.com/zip"}]}
        """.data(using: .utf8)!
        let release = try UpdateManager.githubReleaseDecoder.decode(UpdateManager.ReleaseInfo.self, from: data)
        XCTAssertNil(release.dmgURL)
    }

    private func bumpedPatchVersion(from version: String) -> String {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return "v1.0.1" }

        var bumped = parts
        bumped[bumped.count - 1] += 1
        return "v" + bumped.map(String.init).joined(separator: ".")
    }
}
