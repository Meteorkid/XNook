import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class UpdateManager {
    typealias ReleaseFetcher = () async throws -> Data

    struct ReleaseInfo: Codable, Equatable {
        let tagName: String
        let htmlURL: URL
        let publishedAt: Date
        let assets: [Asset]

        struct Asset: Codable, Equatable {
            let name: String
            let browserDownloadURL: URL

            private enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case assets
        }

        var normalizedVersion: String {
            UpdateManager.normalize(version: tagName)
        }

        var dmgURL: URL? {
            assets.first(where: { $0.name.hasSuffix(".dmg") })?.browserDownloadURL
        }
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(version: String)
        case installing(stage: String)
        case failed(message: String)
    }

    static let githubReleaseDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/meteorkid/XNook/releases/latest")!

    var state: State = .idle
    var latestRelease: ReleaseInfo?
    var lastCheckedAt: Date?

    @ObservationIgnored private let fetchReleaseData: ReleaseFetcher

    init(fetchReleaseData: @escaping ReleaseFetcher = UpdateManager.fetchLatestReleaseData) {
        self.fetchReleaseData = fetchReleaseData
    }

    var currentVersion: String {
        let rawVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        return Self.normalize(version: rawVersion)
    }

    nonisolated static func normalize(version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "v" || first == "V" else {
            return trimmed
        }
        return String(trimmed.dropFirst())
    }

    nonisolated static func isRemoteVersionNewer(_ remote: String, than local: String) -> Bool {
        guard let remoteParts = normalizedVersionParts(remote),
              let localParts = normalizedVersionParts(local) else {
            return false
        }

        let upperBound = max(remoteParts.count, localParts.count)
        for index in 0..<upperBound {
            let remotePart = index < remoteParts.count ? remoteParts[index] : 0
            let localPart = index < localParts.count ? localParts[index] : 0

            if remotePart > localPart { return true }
            if remotePart < localPart { return false }
        }

        return false
    }

    func checkForUpdates() async {
        state = .checking

        do {
            let data = try await fetchReleaseData()
            let release = try Self.githubReleaseDecoder.decode(ReleaseInfo.self, from: data)
            applyCheckResult(release)
        } catch is CancellationError {
            state = .idle
        } catch let urlError as URLError where urlError.code == .cancelled {
            state = .idle
        } catch {
            latestRelease = nil
            state = .failed(message: L10n.updateCheckFailed)
            lastCheckedAt = Date()
        }
    }

    func installUpdate() async {
        guard let release = latestRelease, let dmgURL = release.dmgURL else {
            state = .failed(message: L10n.updateCheckFailed)
            return
        }

        state = .installing(stage: "downloading")

        do {
            // 下载 DMG
            let (tempURL, _) = try await URLSession.shared.download(for: URLRequest(url: dmgURL))

            // 移动到临时目录
            let fileManager = FileManager.default
            let tempDir = fileManager.temporaryDirectory
            let dmgName = dmgURL.lastPathComponent
            let destURL = tempDir.appendingPathComponent(dmgName)

            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.moveItem(at: tempURL, to: destURL)

            // 挂载 DMG
            state = .installing(stage: "mounting")
            let mountOutput = try runCommand(
                "/usr/bin/hdiutil",
                arguments: ["attach", destURL.path, "-nobrowse", "-quiet"]
            )
            let mountPath = parseMountPath(from: mountOutput)

            // 复制应用到 /Applications
            state = .installing(stage: "installing")
            let appSource = mountPath.appendingPathComponent("X Nook.app")
            let appDest = URL(fileURLWithPath: "/Applications/X Nook.app")

            if fileManager.fileExists(atPath: appDest.path) {
                try fileManager.removeItem(at: appDest)
            }
            try fileManager.copyItem(at: appSource, to: appDest)

            // 卸载 DMG
            _ = try? runCommand("/usr/bin/hdiutil", arguments: ["detach", mountPath.path, "-quiet"])

            // 清理临时文件
            try? fileManager.removeItem(at: destURL)

            // 重启应用
            state = .installing(stage: "relaunching")
            let workspace = NSWorkspace.shared
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            try await workspace.openApplication(at: appDest, configuration: config)

            // 退出当前应用
            NSApp.terminate(self)

        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    func applyCheckResult(_ release: ReleaseInfo) {
        latestRelease = release
        lastCheckedAt = Date()

        guard Self.normalizedVersionParts(release.normalizedVersion) != nil else {
            state = .failed(message: L10n.malformedReleaseVersion(release.tagName))
            return
        }

        guard Self.isRemoteVersionNewer(release.normalizedVersion, than: currentVersion) else {
            state = .upToDate
            return
        }

        state = .updateAvailable(version: release.normalizedVersion)
    }

    nonisolated private static func normalizedVersionParts(_ version: String) -> [Int]? {
        let components = normalize(version: version).split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return nil }

        var parts: [Int] = []
        parts.reserveCapacity(components.count)

        for component in components {
            guard !component.isEmpty else { return nil }
            guard component.allSatisfy(\.isNumber) else { return nil }
            guard let value = Int(component) else { return nil }
            parts.append(value)
        }

        return parts
    }

    private static func fetchLatestReleaseData() async throws -> Data {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("X-Nook", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func runCommand(_ path: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UpdateError.commandFailed(path: path, status: process.terminationStatus)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func parseMountPath(from output: String) -> URL {
        let lines = output.components(separatedBy: .newlines)
        for line in lines where line.contains("/Volumes/") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let range = trimmed.range(of: "/Volumes/") {
                let path = String(trimmed[range.lowerBound...])
                return URL(fileURLWithPath: path)
            }
        }
        return URL(fileURLWithPath: "/Volumes/X Nook")
    }

    enum UpdateError: LocalizedError {
        case commandFailed(path: String, status: Int32)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let path, let status):
                return "Command \(path) failed with status \(status)"
            }
        }
    }
}
