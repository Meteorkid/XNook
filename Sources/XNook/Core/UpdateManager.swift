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
        let body: String?

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
            case body
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

    /// 是否开启自动检查更新
    var autoCheckForUpdates: Bool {
        get { UserDefaults.standard.bool(forKey: "autoCheckForUpdates") }
        set { UserDefaults.standard.set(newValue, forKey: "autoCheckForUpdates") }
    }

    @ObservationIgnored private let fetchReleaseData: ReleaseFetcher
    @ObservationIgnored private var autoCheckTimer: Timer?

    init(fetchReleaseData: @escaping ReleaseFetcher = UpdateManager.fetchLatestReleaseData) {
        self.fetchReleaseData = fetchReleaseData
        // 注册默认设置
        UserDefaults.standard.register(defaults: [
            "autoCheckForUpdates": true
        ])
    }

    /// 启动自动检查更新（应用启动时调用）
    func startAutoCheck() {
        stopAutoCheck()
        guard autoCheckForUpdates else { return }

        // 启动时立即检查一次
        Task { @MainActor in
            await checkForUpdates()
        }

        // 每 24 小时检查一次
        autoCheckTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.autoCheckForUpdates else { return }
                await self.checkForUpdates()
            }
        }
    }

    /// 停止自动检查
    func stopAutoCheck() {
        autoCheckTimer?.invalidate()
        autoCheckTimer = nil
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

            // SHA256 完整性校验
            if let expectedSHA256 = extractSHA256(from: release) {
                let actualSHA256 = try calculateSHA256(for: destURL)
                guard actualSHA256 == expectedSHA256 else {
                    try? fileManager.removeItem(at: destURL)
                    state = .failed(message: "SHA256 校验失败，下载的文件可能已被篡改。")
                    return
                }
            }

            // 挂载 DMG
            state = .installing(stage: "mounting")
            let mountOutput = try runCommand(
                "/usr/bin/hdiutil",
                arguments: ["attach", destURL.path, "-nobrowse", "-quiet"]
            )
            let mountPath = try parseMountPath(from: mountOutput)

            // 验证应用代码签名
            let appSource = mountPath.appendingPathComponent("X Nook.app")
            try verifyCodeSignature(at: appSource)

            // 复制应用到 /Applications
            state = .installing(stage: "installing")
            let appDest = URL(fileURLWithPath: "/Applications/X Nook.app")

            if fileManager.fileExists(atPath: appDest.path) {
                try fileManager.removeItem(at: appDest)
            }
            try fileManager.copyItem(at: appSource, to: appDest)

            // 清除扩展属性（避免 Gatekeeper 问题）
            _ = try? runCommand("/usr/bin/xattr", arguments: ["-cr", appDest.path])

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
            NSApp.terminate(nil)

        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    /// 从 release 中提取 SHA256
    private func extractSHA256(from release: ReleaseInfo) -> String? {
        guard let body = release.body else { return nil }
        let dmgFilename = "\(release.normalizedVersion).dmg"

        // 查找 "filename: sha256" 格式
        let pattern = "\(dmgFilename)\\s+([a-fA-F0-9]{64})"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body) else {
            return nil
        }
        return String(body[range])
    }

    /// 计算文件 SHA256
    private func calculateSHA256(for url: URL) throws -> String {
        let output = try runCommand("/usr/bin/shasum", arguments: ["-a", "256", url.path])
        return output.components(separatedBy: " ").first ?? ""
    }

    /// 验证代码签名（结构完整性 + 签发身份）
    private func verifyCodeSignature(at appURL: URL) throws {
        // 第一步：验证签名结构完整性
        _ = try runCommand(
            "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", appURL.path]
        )

        // 第二步：验证签名身份（codesign -dv 的 verbose 输出可能在 stderr，需合并读取）
        let identOutput = try runCommandCombinedOutput(
            "/usr/bin/codesign",
            arguments: ["-dv", "--verbose=4", appURL.path]
        )
        guard identOutput.contains("Identifier=X Nook") || identOutput.contains("Identifier=com.xnook") else {
            throw UpdateError.verificationFailed("签名身份不匹配：更新包的 Identifier 不是 X Nook。")
        }

        // 第三步：验证签发者身份（防止攻击者用自有证书签名同名应用）
        guard identOutput.contains("Authority=Developer ID Application") else {
            throw UpdateError.verificationFailed("签名Authority不匹配：更新包不是由 Developer ID 签发。")
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

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UpdateError.commandFailed(path: path, status: process.terminationStatus)
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 执行命令并同时读取 stdout + stderr（codesign -dv 的 verbose 输出可能在 stderr）
    private func runCommandCombinedOutput(_ path: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let combinedPipe = Pipe()
        process.standardOutput = combinedPipe
        process.standardError = combinedPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UpdateError.commandFailed(path: path, status: process.terminationStatus)
        }

        let data = combinedPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func parseMountPath(from output: String) throws -> URL {
        let lines = output.components(separatedBy: .newlines)
        for line in lines where line.contains("/Volumes/") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let range = trimmed.range(of: "/Volumes/") {
                let path = String(trimmed[range.lowerBound...])
                return URL(fileURLWithPath: path)
            }
        }
        throw UpdateError.verificationFailed("无法从 hdiutil 输出中解析挂载路径，安装已中止。")
    }

    enum UpdateError: LocalizedError {
        case commandFailed(path: String, status: Int32)
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let path, let status):
                return "Command \(path) failed with status \(status)"
            case .verificationFailed(let reason):
                return reason
            }
        }
    }
}
