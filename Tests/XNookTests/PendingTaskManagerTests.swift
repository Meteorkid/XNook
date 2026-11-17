import Darwin
import XCTest
@testable import XNook

@MainActor
final class PendingTaskManagerTests: XCTestCase {
    func testStableIdentifierUsesFixedNamespaceAndIgnoresTitleAndDate() {
        let original = pendingTaskFixture(id: "task-001", source: "manual-export")
        let renamed = PendingTask(source: original.source, externalID: original.externalID,
            title: "另一个标题", createdAt: Date(timeIntervalSince1970: 9))
        XCTAssertEqual(original.id.uuidString.lowercased(), "5f644855-00ed-8c63-938e-f8ed3e7e9850")
        XCTAssertEqual(original.id, renamed.id)
        XCTAssertNotEqual(original.id, pendingTaskFixture(id: "task-001", source: "other").id)
        XCTAssertNotEqual(PendingTask.stableID(source: "ab", externalID: "c"),
            PendingTask.stableID(source: "a", externalID: "bc"))
    }

    func testNewFileRoundTripPreservesIdentityAndTrimsManualTitle() async throws {
        let files = try PendingTaskTestFiles()
        let manager = PendingTaskManager(storageURL: files.storageURL,
            now: { Date(timeIntervalSince1970: 123) })
        await manager.waitUntilLoaded()
        XCTAssertNil(manager.storageError)
        let first = try await manager.add(title: "  写测试\n")
        let second = try await manager.add(title: "写测试")
        XCTAssertEqual(first.title, "写测试")
        XCTAssertEqual(first.createdAt, Date(timeIntervalSince1970: 123))
        XCTAssertNotEqual(first.id, second.id)
        let reloaded = PendingTaskManager(storageURL: files.storageURL)
        await reloaded.waitUntilLoaded()
        XCTAssertEqual(reloaded.items, [first, second])
        try await reloaded.remove(id: first.id)
        let final = PendingTaskManager(storageURL: files.storageURL)
        await final.waitUntilLoaded()
        XCTAssertEqual(final.items, [second])
    }

    func testInvalidManualTitlesAndUnknownIDsDoNotWrite() async throws {
        let store = PendingTaskTestStorage()
        let manager = await pendingTaskManagerFixture(store)
        for title in ["", " \n", String(repeating: "字", count: 501)] {
            await expectPendingTaskError(.invalidTitle) { _ = try await manager.add(title: title) }
        }
        await expectPendingTaskError(.taskNotFound) { try await manager.remove(id: UUID()) }
        await expectPendingTaskError(.taskNotFound) { try await manager.markHandoff(id: UUID()) }
        let writes = await store.writeCount
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertNil(manager.storageError)
    }

    func testCorruptUnknownVersionAndDuplicateStoresRetainOriginalAndLockWrites() async throws {
        let task = pendingTaskFixture()
        let cases: [(Data, PendingTaskError)] = [
            (Data("{broken".utf8), .invalidStorage),
            (try pendingTaskStoreData([task], version: 2), .unsupportedVersion(2)),
            (try pendingTaskStoreData([task, task]), .duplicateStoredID)
        ]
        for (data, failure) in cases {
            let files = try PendingTaskTestFiles()
            try data.write(to: files.storageURL)
            let manager = PendingTaskManager(storageURL: files.storageURL)
            await manager.waitUntilLoaded()
            XCTAssertEqual(manager.storageError, failure)
            XCTAssertTrue(manager.items.isEmpty)
            await expectPendingTaskError(.storageUnavailable) { _ = try await manager.add(title: "拒绝覆盖") }
            XCTAssertEqual(try Data(contentsOf: files.storageURL), data)
        }
    }

    func testInvalidStoredFieldsAndIdentityBlockWrites() async throws {
        let valid = pendingTaskFixture()
        let cases: [(PendingTask, PendingTaskError)] = [
            (PendingTask(source: " ", externalID: "1", title: "标题", createdAt: valid.createdAt), .invalidSource),
            (PendingTask(source: "s", externalID: "", title: "标题", createdAt: valid.createdAt), .invalidExternalID),
            (PendingTask(source: "s", externalID: "1", title: "", createdAt: valid.createdAt), .invalidTitle),
            (PendingTask(id: UUID(), source: "s", externalID: "1", title: "标题", createdAt: valid.createdAt), .invalidIdentifier)
        ]
        for (task, failure) in cases {
            let data = try pendingTaskStoreData([task])
            let store = PendingTaskTestStorage(data: data)
            let manager = await pendingTaskManagerFixture(store)
            XCTAssertEqual(manager.storageError, failure)
            await expectPendingTaskError(.storageUnavailable) { _ = try await manager.add(title: "拒绝覆盖") }
            let snapshot = await store.data
            let writes = await store.writeCount
            XCTAssertEqual(snapshot, data)
            XCTAssertEqual(writes, 0)
        }
    }

    func testNonFiniteCreationDateIsRejectedBeforeWriting() async {
        let store = PendingTaskTestStorage()
        let manager = PendingTaskManager(storageURL: pendingTaskTestURL,
            readData: { _ in try await store.read() }, writeData: { data, _ in try await store.write(data) },
            now: { Date(timeIntervalSinceReferenceDate: .infinity) })
        await manager.waitUntilLoaded()
        await expectPendingTaskError(.invalidCreatedAt) { _ = try await manager.add(title: "无效时间") }
        let writes = await store.writeCount
        XCTAssertEqual(writes, 0)
    }

    func testOversizedStorageIsNotDecodedOrOverwritten() async throws {
        let files = try PendingTaskTestFiles()
        let data = Data(repeating: 32, count: PendingTaskManager.storageByteLimit + 1)
        try data.write(to: files.storageURL)
        let manager = PendingTaskManager(storageURL: files.storageURL)
        await manager.waitUntilLoaded()
        XCTAssertEqual(manager.storageError, .fileTooLarge)
        await expectPendingTaskError(.storageUnavailable) { _ = try await manager.add(title: "拒绝覆盖") }
        XCTAssertEqual(try Data(contentsOf: files.storageURL), data)
    }

    func testReadFailureRetainsLastPublishedItemsUntilSuccessfulReload() async throws {
        let task = pendingTaskFixture()
        let store = PendingTaskTestStorage(data: try pendingTaskStoreData([task]))
        let manager = await pendingTaskManagerFixture(store)
        await store.setReadFailure(true)
        let failed = await manager.retryLoading()
        XCTAssertFalse(failed)
        XCTAssertEqual(manager.items, [task])
        XCTAssertEqual(manager.storageError, .readFailed)
        await expectPendingTaskError(.storageUnavailable) { try await manager.remove(id: task.id) }
        await store.setReadFailure(false)
        let recovered = await manager.retryLoading()
        XCTAssertTrue(recovered)
        XCTAssertEqual(manager.items, [task])
        XCTAssertNil(manager.storageError)
    }

    func testInitialWriteFailurePublishesNothingAndRequiresReloadBeforeRetry() async throws {
        let store = PendingTaskTestStorage(behavior: .failBeforeWrite)
        let manager = await pendingTaskManagerFixture(store)
        await expectPendingTaskError(.writeFailed) { _ = try await manager.add(title: "保留输入") }
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertEqual(manager.storageError, .writeFailed)
        let snapshot = await store.data
        XCTAssertNil(snapshot)
        await store.setBehavior(.succeed)
        await expectPendingTaskError(.storageUnavailable) { _ = try await manager.add(title: "不可直接重试") }
        let reloaded = await manager.retryLoading()
        XCTAssertTrue(reloaded)
        _ = try await manager.add(title: "显式重载后重试")
        XCTAssertEqual(manager.items.count, 1)
    }

    func testWriteThenThrowReloadsActualStoredCandidateBeforeFurtherChanges() async throws {
        let store = PendingTaskTestStorage(behavior: .failAfterWrite)
        let manager = await pendingTaskManagerFixture(store)
        await expectPendingTaskError(.writeFailed) { _ = try await manager.add(title: "已落盘但未确认") }
        XCTAssertTrue(manager.items.isEmpty)
        await expectPendingTaskError(.storageUnavailable) { _ = try await manager.add(title: "拒绝覆盖") }
        await store.setBehavior(.succeed)
        let reloaded = await manager.retryLoading()
        XCTAssertTrue(reloaded)
        XCTAssertEqual(manager.items.map(\.title), ["已落盘但未确认"])
        let writes = await store.writeCount
        XCTAssertEqual(writes, 1)
    }

    func testHandoffPersistsAndCannotBeRemovedDirectly() async throws {
        let task = pendingTaskFixture()
        let store = PendingTaskTestStorage(data: try pendingTaskStoreData([task]))
        let manager = await pendingTaskManagerFixture(store)
        try await manager.markHandoff(id: task.id)
        XCTAssertEqual(manager.items.first?.state, .handoff)
        try await manager.markHandoff(id: task.id)
        await expectPendingTaskError(.handoffRequiresReconciliation) { try await manager.remove(id: task.id) }
        let reloaded = await pendingTaskManagerFixture(store)
        XCTAssertEqual(reloaded.items.first?.state, .handoff)
        let writes = await store.writeCount
        XCTAssertEqual(writes, 1)
    }

    func testHandoffWriteFailuresPreservePublishedPendingAndRequireReload() async throws {
        for behavior in [PendingTaskTestStorage.WriteBehavior.failBeforeWrite, .failAfterWrite] {
            let task = pendingTaskFixture()
            let store = PendingTaskTestStorage(data: try pendingTaskStoreData([task]), behavior: behavior)
            let manager = await pendingTaskManagerFixture(store)
            await expectPendingTaskError(.writeFailed) { try await manager.markHandoff(id: task.id) }
            XCTAssertEqual(manager.items, [task])
            await expectPendingTaskError(.storageUnavailable) { try await manager.markHandoff(id: task.id) }
            let reloaded = await manager.retryLoading()
            XCTAssertTrue(reloaded)
            XCTAssertEqual(manager.items.first?.state, behavior == .failAfterWrite ? .handoff : .pending)
        }
    }

    func testReconciliationDeletesMatchedHandoffsRestoresUnmatchedAndKeepsPending() async throws {
        let matched = pendingTaskFixture(id: "matched", state: .handoff)
        let unmatched = pendingTaskFixture(id: "unmatched", state: .handoff)
        let pending = pendingTaskFixture(id: "pending")
        let store = PendingTaskTestStorage(data: try pendingTaskStoreData([matched, unmatched, pending]))
        let manager = await pendingTaskManagerFixture(store)
        try await manager.reconcileHandoffs(knownStartedIDs: [matched.id, pending.id])
        var restored = unmatched
        restored.state = .pending
        XCTAssertEqual(manager.items, [restored, pending])
        let reloaded = await pendingTaskManagerFixture(store)
        XCTAssertEqual(reloaded.items, [restored, pending])
    }

    func testReconciliationFailuresNeverPublishCleanupOrRestorationEarly() async throws {
        for matches in [false, true] {
            for behavior in [PendingTaskTestStorage.WriteBehavior.failBeforeWrite, .failAfterWrite] {
                let task = pendingTaskFixture(state: .handoff)
                let store = PendingTaskTestStorage(data: try pendingTaskStoreData([task]), behavior: behavior)
                let manager = await pendingTaskManagerFixture(store)
                let known: Set<UUID> = matches ? [task.id] : []
                await expectPendingTaskError(.writeFailed) { try await manager.reconcileHandoffs(knownStartedIDs: known) }
                XCTAssertEqual(manager.items, [task])
                XCTAssertEqual(manager.storageError, .writeFailed)
                let reloaded = await manager.retryLoading()
                XCTAssertTrue(reloaded)
                if behavior == .failBeforeWrite {
                    XCTAssertEqual(manager.items, [task])
                } else if matches {
                    XCTAssertTrue(manager.items.isEmpty)
                } else {
                    XCTAssertEqual(manager.items.first?.state, .pending)
                }
            }
        }
    }

    func testReconciliationWithoutHandoffsDoesNotWrite() async throws {
        let task = pendingTaskFixture()
        let store = PendingTaskTestStorage(data: try pendingTaskStoreData([task]))
        let manager = await pendingTaskManagerFixture(store)
        try await manager.reconcileHandoffs(knownStartedIDs: [task.id])
        XCTAssertEqual(manager.items, [task])
        let writes = await store.writeCount
        XCTAssertEqual(writes, 0)
    }

    func testFIFOAndInternalSymbolicLinkAreRejectedWithoutReplacingOriginal() async throws {
        let files = try PendingTaskTestFiles()
        XCTAssertEqual(mkfifo(files.storageURL.path, 0o600), 0)
        let fifo = PendingTaskManager(storageURL: files.storageURL)
        await fifo.waitUntilLoaded()
        XCTAssertEqual(fifo.storageError, .notRegularFile)
        await expectPendingTaskError(.storageUnavailable) { _ = try await fifo.add(title: "不写 FIFO") }
        var attributes = stat()
        XCTAssertEqual(lstat(files.storageURL.path, &attributes), 0)
        XCTAssertEqual(attributes.st_mode & S_IFMT, S_IFIFO)
        try FileManager.default.removeItem(at: files.storageURL)
        let target = files.directory.appendingPathComponent("original.json")
        let data = try pendingTaskStoreData([pendingTaskFixture()])
        try data.write(to: target)
        try FileManager.default.createSymbolicLink(at: files.storageURL, withDestinationURL: target)
        let link = PendingTaskManager(storageURL: files.storageURL)
        await link.waitUntilLoaded()
        XCTAssertEqual(link.storageError, .notRegularFile)
        await expectPendingTaskError(.storageUnavailable) { _ = try await link.add(title: "不写链接") }
        XCTAssertEqual(try Data(contentsOf: target), data)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: files.storageURL.path), target.path)
    }

    func testStorageFileReplacedBySymbolicLinkBeforeSaveIsRejected() async throws {
        let files = try PendingTaskTestFiles()
        let manager = PendingTaskManager(storageURL: files.storageURL)
        await manager.waitUntilLoaded()
        let target = files.directory.appendingPathComponent("other.json")
        let original = Data("保留目标文件".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: files.storageURL, withDestinationURL: target)
        await expectPendingTaskError(.notRegularFile) { _ = try await manager.add(title: "拒绝写入") }
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: files.storageURL.path), target.path)
    }

    func testLoadingRejectsMutationsAndRetryUntilReaderFinishes() async throws {
        let gate = PendingTaskTestGate()
        let entered = expectation(description: "reader entered")
        let manager = PendingTaskManager(storageURL: pendingTaskTestURL, readData: { _ in
            entered.fulfill()
            await gate.wait()
            return nil
        }, writeData: { _, _ in XCTFail("加载期间不得写入") })
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(manager.isLoading)
        await expectPendingTaskError(.busy) { _ = try await manager.add(title: "等待加载") }
        let retried = await manager.retryLoading()
        XCTAssertFalse(retried)
        await gate.release()
        await manager.waitUntilLoaded()
        XCTAssertFalse(manager.isLoading)
    }

    func testAsyncSaveKeepsMainActorResponsiveAndRejectsEveryConcurrentMutation() async throws {
        let original = pendingTaskFixture()
        let data = try pendingTaskStoreData([original])
        let gate = PendingTaskTestGate()
        let entered = expectation(description: "writer entered")
        let manager = PendingTaskManager(storageURL: pendingTaskTestURL, readData: { _ in data },
            writeData: { _, _ in
                entered.fulfill()
                await gate.wait()
            })
        await manager.waitUntilLoaded()
        let saving = Task { try await manager.add(title: "后台保存") }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(manager.isSaving)
        XCTAssertEqual(manager.items, [original])
        let responsive = expectation(description: "main actor remains responsive")
        Task { @MainActor in responsive.fulfill() }
        await fulfillment(of: [responsive], timeout: 1)
        await expectPendingTaskError(.busy) { _ = try await manager.add(title: "第二次新增") }
        await expectPendingTaskError(.busy) { try await manager.remove(id: original.id) }
        await expectPendingTaskError(.busy) { try await manager.markHandoff(id: original.id) }
        await expectPendingTaskError(.busy) { try await manager.reconcileHandoffs(knownStartedIDs: []) }
        await expectPendingTaskError(.busy) { _ = try await manager.importTasks(data: Data(), knownStartedIDs: []) }
        let retried = await manager.retryLoading()
        XCTAssertFalse(retried)
        await gate.release()
        let saved = try await saving.value
        XCTAssertFalse(manager.isSaving)
        XCTAssertEqual(manager.items, [original, saved])
    }
}

// 以下夹具仅使用注入存储或独立临时目录，不接触 Application Support。
let pendingTaskTestURL = URL(fileURLWithPath: "/unused-injected-pending-tasks.json")

func pendingTaskFixture(id: String = "external-1", source: String = "test", title: String = "测试任务",
    state: PendingTask.State = .pending) -> PendingTask {
    PendingTask(source: source, externalID: id, title: title,
        createdAt: Date(timeIntervalSince1970: 123), state: state)
}

func pendingTaskStoreData(_ items: [PendingTask], version: Int = 1) throws -> Data {
    struct Store: Encodable { let version: Int; let items: [PendingTask] }
    return try JSONEncoder().encode(Store(version: version, items: items))
}

@MainActor
func pendingTaskManagerFixture(_ store: PendingTaskTestStorage) async -> PendingTaskManager {
    let manager = PendingTaskManager(storageURL: pendingTaskTestURL,
        readData: { _ in try await store.read() }, writeData: { data, _ in try await store.write(data) })
    await manager.waitUntilLoaded()
    return manager
}

@MainActor
func expectPendingTaskError(_ expected: PendingTaskError, file: StaticString = #filePath, line: UInt = #line,
    operation: () async throws -> Void) async {
    do {
        try await operation()
        XCTFail("预期错误 \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? PendingTaskError, expected, file: file, line: line)
    }
}

final class PendingTaskTestFiles {
    let directory: URL
    var storageURL: URL { directory.appendingPathComponent("pending_tasks.json") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("XNook.PendingTask.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

actor PendingTaskTestStorage {
    enum WriteBehavior: Equatable, Sendable { case succeed, failBeforeWrite, failAfterWrite }
    private(set) var data: Data?
    private(set) var writeCount = 0
    private var behavior: WriteBehavior
    private var readFailure = false

    init(data: Data? = nil, behavior: WriteBehavior = .succeed) {
        self.data = data
        self.behavior = behavior
    }

    func read() throws -> Data? {
        if readFailure { throw CocoaError(.fileReadUnknown) }
        return data
    }

    func write(_ candidate: Data) throws {
        writeCount += 1
        if behavior == .failBeforeWrite { throw CocoaError(.fileWriteUnknown) }
        data = candidate
        if behavior == .failAfterWrite { throw CocoaError(.fileWriteUnknown) }
    }

    func setBehavior(_ value: WriteBehavior) { behavior = value }
    func setReadFailure(_ value: Bool) { readFailure = value }
}

actor PendingTaskTestGate {
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
