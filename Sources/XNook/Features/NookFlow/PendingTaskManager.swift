import Darwin
import Foundation
import Observation

/// handoff 条目保留开始意图，只有核对 Focus 的完整来源集合后才允许清理。
@Observable @MainActor
final class PendingTaskManager {
    typealias ReadData = @Sendable (URL) async throws -> Data?
    typealias WriteData = @Sendable (Data, URL) async throws -> Void

    nonisolated static let storageByteLimit = 8 * 1_024 * 1_024
    nonisolated static let importByteLimit = 1_024 * 1_024
    nonisolated static let importItemLimit = 200

    private(set) var items: [PendingTask] = []
    private(set) var storageError: PendingTaskError?
    private(set) var isLoading = true
    private(set) var isSaving = false

    private let storageURL: URL
    private let readData: ReadData
    private let writeData: WriteData
    private let now: @Sendable () -> Date
    @ObservationIgnored private var loadingTask: Task<Bool, Never>?

    init(
        storageURL: URL? = nil,
        readData: ReadData? = nil,
        writeData: WriteData? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storageURL = storageURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("XNook/pending_tasks.json")
        self.readData = readData ?? { url in
            try Self.readRegularFile(url, limit: Self.storageByteLimit, allowSymbolicLink: false)
        }
        self.writeData = writeData ?? { data, url in
            try Self.writeStorageFile(data, to: url)
        }
        self.now = now
        loadingTask = Task { [weak self] in
            guard let self else { return false }
            return await self.loadFromStorage()
        }
    }

    func waitUntilLoaded() async {
        _ = await loadingTask?.value
    }

    @discardableResult
    func retryLoading() async -> Bool {
        guard !isLoading, !isSaving else { return false }
        isLoading = true
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.loadFromStorage()
        }
        loadingTask = task
        return await task.value
    }

    @discardableResult
    func add(title: String) async throws -> PendingTask {
        try requireWritable()
        let task = PendingTask(
            source: "manual", externalID: UUID().uuidString,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines), createdAt: now()
        )
        try task.validate()
        try await persist(items + [task])
        return task
    }

    func remove(id: UUID) async throws {
        try requireWritable()
        guard let task = items.first(where: { $0.id == id }) else { throw PendingTaskError.taskNotFound }
        guard task.state == .pending else { throw PendingTaskError.handoffRequiresReconciliation }
        try await persist(items.filter { $0.id != id })
    }

    func markHandoff(id: UUID) async throws {
        try requireWritable()
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw PendingTaskError.taskNotFound }
        guard items[index].state != .handoff else { return }
        var candidate = items
        candidate[index].state = .handoff
        try await persist(candidate)
    }

    func reconcileHandoffs(knownStartedIDs: Set<UUID>) async throws {
        try requireWritable()
        guard items.contains(where: { $0.state == .handoff }) else { return }
        let candidate = items.compactMap { task -> PendingTask? in
            guard task.state == .handoff else { return task }
            guard !knownStartedIDs.contains(task.id) else { return nil }
            var restored = task
            restored.state = .pending
            return restored
        }
        try await persist(candidate)
    }

    /// 调用方必须先确认 Focus 存储可读，再传入 active/history 的完整来源 ID。
    func importTasks(data: Data, knownStartedIDs: Set<UUID>) async throws -> [ImportItemResult] {
        try requireWritable()
        guard data.count <= Self.importByteLimit else { throw PendingTaskError.fileTooLarge }
        let batch: ImportBatch
        do {
            batch = try JSONDecoder().decode(ImportBatch.self, from: data)
        } catch {
            throw PendingTaskError.invalidImportFormat
        }
        guard batch.version == 1 else { throw PendingTaskError.unsupportedVersion(batch.version) }
        guard batch.tasks.count <= Self.importItemLimit else { throw PendingTaskError.tooManyImportItems }

        var candidate = items
        var knownIDs = Set(items.map(\.id)).union(knownStartedIDs)
        var results: [ImportItemResult] = []
        let createdAt = now()
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else { throw PendingTaskError.invalidCreatedAt }
        for (index, entry) in batch.tasks.enumerated() {
            let outcome: ImportItemResult.Outcome
            if let reason = entry.invalidReason {
                outcome = .invalid(reason: reason)
            } else if let source = entry.source, let externalID = entry.id, let title = entry.title {
                let task = PendingTask(
                    source: source, externalID: externalID,
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines), createdAt: createdAt
                )
                if knownIDs.insert(task.id).inserted {
                    candidate.append(task)
                    outcome = .added
                } else {
                    outcome = .duplicate
                }
            } else {
                outcome = .invalid(reason: .invalidItem)
            }
            results.append(ImportItemResult(index: index, title: entry.title, outcome: outcome))
        }
        if candidate != items { try await persist(candidate) }
        return results
    }

    /// 调用方保持 security scope。显式选取的符号链接可跟随，但目标必须为普通文件。
    nonisolated static func readImportFile(_ url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            guard let data = try Self.readRegularFile(url, limit: Self.importByteLimit, allowSymbolicLink: true) else {
                throw PendingTaskError.readFailed
            }
            return data
        }.value
    }

    private func requireWritable() throws {
        guard !isLoading, !isSaving else { throw PendingTaskError.busy }
        guard storageError == nil else { throw PendingTaskError.storageUnavailable }
    }

    private func loadFromStorage() async -> Bool {
        defer { isLoading = false }
        let reader = readData
        let url = storageURL
        do {
            let loaded = try await Task.detached(priority: .utility) {
                guard let data = try await reader(url) else { return [PendingTask]() }
                guard data.count <= Self.storageByteLimit else { throw PendingTaskError.fileTooLarge }
                let store: PendingTaskStore
                do {
                    store = try JSONDecoder().decode(PendingTaskStore.self, from: data)
                } catch {
                    throw PendingTaskError.invalidStorage
                }
                guard store.version == 1 else { throw PendingTaskError.unsupportedVersion(store.version) }
                var ids = Set<UUID>()
                for task in store.items {
                    try task.validate()
                    guard ids.insert(task.id).inserted else { throw PendingTaskError.duplicateStoredID }
                }
                return store.items
            }.value
            items = loaded
            storageError = nil
            return true
        } catch {
            storageError = error as? PendingTaskError ?? .readFailed
            return false
        }
    }

    private func persist(_ candidate: [PendingTask]) async throws {
        isSaving = true
        defer { isSaving = false }
        let writer = writeData
        let url = storageURL
        do {
            try await Task.detached(priority: .utility) {
                let data = try JSONEncoder().encode(PendingTaskStore(version: 1, items: candidate))
                guard data.count <= Self.storageByteLimit else { throw PendingTaskError.fileTooLarge }
                try await writer(data, url)
            }.value
            items = candidate
        } catch {
            let failure = error as? PendingTaskError ?? PendingTaskError.writeFailed
            storageError = failure
            throw failure
        }
    }

    nonisolated private static func readRegularFile(
        _ url: URL, limit: Int, allowSymbolicLink: Bool
    ) throws -> Data? {
        guard url.isFileURL else { throw PendingTaskError.readFailed }
        let flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC | (allowSymbolicLink ? 0 : O_NOFOLLOW)
        let descriptor = open(url.path, flags)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw PendingTaskError.notRegularFile }
            throw PendingTaskError.readFailed
        }
        defer { close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else { throw PendingTaskError.readFailed }
        guard (attributes.st_mode & S_IFMT) == S_IFREG else { throw PendingTaskError.notRegularFile }
        guard attributes.st_size >= 0, attributes.st_size <= limit else { throw PendingTaskError.fileTooLarge }
        var data = Data()
        data.reserveCapacity(Int(attributes.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while data.count <= limit {
            let count = read(descriptor, &buffer, min(buffer.count, limit + 1 - data.count))
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw PendingTaskError.readFailed
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        throw PendingTaskError.fileTooLarge
    }

    nonisolated private static func writeStorageFile(_ data: Data, to url: URL) throws {
        guard url.isFileURL else { throw PendingTaskError.writeFailed }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var attributes = stat()
        if lstat(url.path, &attributes) == 0 {
            guard (attributes.st_mode & S_IFMT) == S_IFREG else { throw PendingTaskError.notRegularFile }
        } else if errno != ENOENT {
            throw PendingTaskError.writeFailed
        }
        try data.write(to: url, options: .atomic)
    }
}

private struct PendingTaskStore: Codable, Sendable {
    let version: Int
    let items: [PendingTask]
}

private struct ImportBatch: Decodable {
    let version: Int
    let tasks: [ImportEntry]
}

private struct ImportEntry: Decodable {
    let source: String?
    let id: String?
    let title: String?
    let isObject: Bool

    private enum CodingKeys: String, CodingKey { case source, id, title }

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        isObject = container != nil
        source = try? container?.decode(String.self, forKey: .source)
        id = try? container?.decode(String.self, forKey: .id)
        title = try? container?.decode(String.self, forKey: .title)
    }

    var invalidReason: ImportInvalidReason? {
        guard isObject else { return .invalidItem }
        guard let source, PendingTask.isValid(source, limit: 64) else { return .invalidSource }
        guard let id, PendingTask.isValid(id, limit: 128) else { return .invalidExternalID }
        guard let title, PendingTask.isValid(title, limit: 500) else { return .invalidTitle }
        return nil
    }
}
