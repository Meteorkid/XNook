import Foundation

/// 任务网页快照；打开旧存储时仍通过 validatedURL 复核地址。
struct LinkedTaskURL: Codable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let urlString: String
    /// 旧记录缺少修订标识；每次实际编辑生成新值以识别改后又改回的情况。
    let revision: UUID?

    init(id: UUID, title: String, urlString: String, revision: UUID? = nil) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.revision = revision
    }

    var validatedURL: URL? { Self.normalizedURL(urlString) }

    static func make(urlString: String, title: String) -> LinkedTaskURL? {
        guard let url = normalizedURL(urlString), let host = url.host else { return nil }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = trimmedTitle.isEmpty ? host : trimmedTitle
        guard displayTitle.count <= 120 else { return nil }
        return LinkedTaskURL(id: UUID(), title: displayTitle, urlString: url.absoluteString)
    }

    private static func normalizedURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4096,
              let url = URL(string: trimmed, encodingInvalidCharacters: false),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }

        components.scheme = scheme
        components.host = host.lowercased()
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        if components.path.isEmpty { components.path = "/" }
        guard let normalized = components.url, normalized.absoluteString.count <= 4096 else { return nil }
        return normalized
    }
}
