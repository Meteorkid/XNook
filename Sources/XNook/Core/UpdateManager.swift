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

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case publishedAt = "published_at"
        }

        var normalizedVersion: String {
            UpdateManager.normalize(version: tagName)
        }
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(version: String)
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
}
