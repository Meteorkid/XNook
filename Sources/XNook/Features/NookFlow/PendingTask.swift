import CryptoKit
import Foundation

struct PendingTask: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case pending
        case handoff
    }

    let id: UUID
    let source: String
    let externalID: String
    let title: String
    let createdAt: Date
    var state: State

    init(
        id: UUID? = nil,
        source: String,
        externalID: String,
        title: String,
        createdAt: Date,
        state: State = .pending
    ) {
        self.id = id ?? Self.stableID(source: source, externalID: externalID)
        self.source = source
        self.externalID = externalID
        self.title = title
        self.createdAt = createdAt
        self.state = state
    }

    /// 固定命名空间和 UTF-8 字节长度前缀避免字段连接歧义；标题与创建时间不参与身份。
    static func stableID(source: String, externalID: String) -> UUID {
        var input = Data("XNook.PendingTask.v1\0".utf8)
        for value in [source, externalID] {
            let bytes = Data(value.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
            input.append(bytes)
        }
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        // UUID v8 为应用定义的 SHA-256 派生方式保留版本位。
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    func validate() throws {
        guard Self.isValid(source, limit: 64) else { throw PendingTaskError.invalidSource }
        guard Self.isValid(externalID, limit: 128) else { throw PendingTaskError.invalidExternalID }
        guard Self.isValid(title, limit: 500) else { throw PendingTaskError.invalidTitle }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else { throw PendingTaskError.invalidCreatedAt }
        guard id == Self.stableID(source: source, externalID: externalID) else {
            throw PendingTaskError.invalidIdentifier
        }
    }

    static func isValid(_ value: String, limit: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= limit
    }
}

enum PendingTaskError: Error, Equatable, Sendable {
    case busy
    case storageUnavailable
    case taskNotFound
    case handoffRequiresReconciliation
    case invalidSource
    case invalidExternalID
    case invalidTitle
    case invalidCreatedAt
    case invalidIdentifier
    case invalidStorage
    case duplicateStoredID
    case unsupportedVersion(Int)
    case invalidImportFormat
    case tooManyImportItems
    case fileTooLarge
    case notRegularFile
    case readFailed
    case writeFailed
}

enum ImportInvalidReason: Equatable, Sendable {
    case invalidItem
    case invalidSource
    case invalidExternalID
    case invalidTitle
}

struct ImportItemResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case added
        case duplicate
        case invalid(reason: ImportInvalidReason)
    }

    /// 与输入 tasks 数组一致，采用零基索引。
    let index: Int
    let title: String?
    let outcome: Outcome
}
