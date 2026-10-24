import Darwin
import XCTest
@testable import XNook

@MainActor
final class PendingTaskImportTests: XCTestCase {
    func testValidFieldLimitsAndTrimmedTitleAreAccepted() async throws {
        let store = PendingTaskTestStorage()
        let manager = await pendingTaskManagerFixture(store)
        let source = String(repeating: "源", count: 64)
        let externalID = String(repeating: "号", count: 128)
        let title = String(repeating: "题", count: 500)
        let data = try importData([
            importEntry(source: source, id: externalID, title: title),
            importEntry(id: "trimmed", title: "  标题\n")
        ])
        let result = try await manager.importTasks(data: data, knownStartedIDs: [])
        XCTAssertEqual(result.map(\.outcome), [.added, .added])
        XCTAssertEqual(result.map(\.index), [0, 1])
        XCTAssertEqual(manager.items.map(\.title), [title, "标题"])
        XCTAssertEqual(manager.items.first?.id, PendingTask.stableID(source: source, externalID: externalID))
        let reloaded = await pendingTaskManagerFixture(store)
        XCTAssertEqual(reloaded.items, manager.items)
        let writes = await store.writeCount
        XCTAssertEqual(writes, 1)
    }

    func testInvalidEntriesAreReportedIndividuallyWithoutDiscardingValidNeighbor() async throws {
        let store = PendingTaskTestStorage()
        let manager = await pendingTaskManagerFixture(store)
        let cases: [(Any, ImportInvalidReason)] = [
            (NSNull(), .invalidItem),
            (42, .invalidItem),
            ("not an object", .invalidItem),
            ([["source": "nested"]], .invalidItem),
            ([String: Any](), .invalidSource),
            (importEntry(source: " \n"), .invalidSource),
            (importEntry(source: String(repeating: "源", count: 65)), .invalidSource),
            (["source": 1, "id": "x", "title": "标题"] as [String: Any], .invalidSource),
            (["source": "s", "title": "标题"], .invalidExternalID),
            (importEntry(id: "\n"), .invalidExternalID),
            (importEntry(id: String(repeating: "号", count: 129)), .invalidExternalID),
            (["source": "s", "id": false, "title": "标题"] as [String: Any], .invalidExternalID),
            (["source": "s", "id": "x"], .invalidTitle),
            (importEntry(title: " \n"), .invalidTitle),
            (importEntry(title: String(repeating: "题", count: 501)), .invalidTitle),
            (["source": "s", "id": "x", "title": ["nested"]] as [String: Any], .invalidTitle)
        ]
        let data = try importData(cases.map(\.0) + [importEntry(id: "valid", title: "有效邻项")])
        let result = try await manager.importTasks(data: data, knownStartedIDs: [])
        XCTAssertEqual(result.count, cases.count + 1)
        for (index, invalid) in cases.enumerated() {
            XCTAssertEqual(result[index].index, index)
            XCTAssertEqual(result[index].outcome, .invalid(reason: invalid.1), "input index \(index)")
        }
        XCTAssertEqual(result.last?.outcome, .added)
        XCTAssertEqual(manager.items.map(\.title), ["有效邻项"])
        let writes = await store.writeCount
        XCTAssertEqual(writes, 1)
    }

    func testSameBatchDuplicatesKeepFirstTitleAndDifferentSourcesStayDistinct() async throws {
        let store = PendingTaskTestStorage()
        let manager = await pendingTaskManagerFixture(store)
        let data = try importData([
            importEntry(source: "a", id: "same", title: "第一个标题"),
            importEntry(source: "a", id: "same", title: "后来的标题"),
            importEntry(source: "b", id: "same", title: "另一来源")
        ])
        let result = try await manager.importTasks(data: data, knownStartedIDs: [])
        XCTAssertEqual(result.map(\.outcome), [.added, .duplicate, .added])
        XCTAssertEqual(manager.items.map(\.title), ["第一个标题", "另一来源"])
        XCTAssertNotEqual(manager.items[0].id, manager.items[1].id)
        let reloaded = await pendingTaskManagerFixture(store)
        let repeated = try await reloaded.importTasks(data: data, knownStartedIDs: [])
        XCTAssertEqual(repeated.map(\.outcome), [.duplicate, .duplicate, .duplicate])
        XCTAssertEqual(reloaded.items, manager.items)
        let writes = await store.writeCount
        XCTAssertEqual(writes, 1)
    }

    func testExistingPendingHandoffAndKnownStartedIDsAllDeduplicateWithoutRenaming() async throws {
        let pending = pendingTaskFixture(id: "pending", title: "手工保留标题")
        let handoff = pendingTaskFixture(id: "handoff", title: "交接原标题", state: .handoff)
        let startedID = PendingTask.stableID(source: "test", externalID: "started")
        let original = try pendingTaskStoreData([pending, handoff])
        let store = PendingTaskTestStorage(data: original)
        let manager = await pendingTaskManagerFixture(store)
        let result = try await manager.importTasks(data: importData([
            importEntry(id: "pending", title: "覆盖 pending"),
            importEntry(id: "handoff", title: "覆盖 handoff"),
            importEntry(id: "started", title: "重复开始"),
            importEntry(id: "new", title: "新增")
        ]), knownStartedIDs: [startedID])
        XCTAssertEqual(result.map(\.outcome), [.duplicate, .duplicate, .duplicate, .added])
        XCTAssertEqual(Array(manager.items.prefix(2)), [pending, handoff])
        XCTAssertEqual(manager.items.last?.title, "新增")
        XCTAssertEqual(manager.items.count, 3)
    }

    func testInvalidAndDuplicateOnlyBatchDoesNotWriteOrFailFromUnusedWriter() async throws {
        let task = pendingTaskFixture()
        let original = try pendingTaskStoreData([task])
        let store = PendingTaskTestStorage(data: original, behavior: .failBeforeWrite)
        let manager = await pendingTaskManagerFixture(store)
        let result = try await manager.importTasks(data: importData([
            importEntry(id: task.externalID, title: "不得覆盖"),
            importEntry(id: "invalid", title: "")
        ]), knownStartedIDs: [])
        XCTAssertEqual(result.map(\.outcome), [.duplicate, .invalid(reason: .invalidTitle)])
        XCTAssertEqual(manager.items, [task])
        XCTAssertNil(manager.storageError)
        let snapshot = await store.data
        let writes = await store.writeCount
        XCTAssertEqual(snapshot, original)
        XCTAssertEqual(writes, 0)
    }

    func testTwoHundredItemsAreAcceptedAsOneWrite() async throws {
        let store = PendingTaskTestStorage()
        let manager = await pendingTaskManagerFixture(store)
        let data = try importData((0..<200).map { importEntry(id: "item-\($0)") })
        let result = try await manager.importTasks(data: data, knownStartedIDs: [])
        XCTAssertEqual(result.count, 200)
        XCTAssertTrue(result.allSatisfy { $0.outcome == .added })
        XCTAssertEqual(manager.items.count, 200)
        let writes = await store.writeCount
        XCTAssertEqual(writes, 1)
    }

    func testTwoHundredAndOneItemsRejectWholeBatchBeforeWriting() async throws {
        let store = PendingTaskTestStorage()
        let manager = await pendingTaskManagerFixture(store)
        let data = try importData((0..<201).map { importEntry(id: "item-\($0)") })
        await expectPendingTaskError(.tooManyImportItems) {
            _ = try await manager.importTasks(data: data, knownStartedIDs: [])
        }
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertNil(manager.storageError)
        let writes = await store.writeCount
        XCTAssertEqual(writes, 0)
    }

    func testImportByteLimitAcceptsExactLimitAndRejectsOneExtraByte() async throws {
        let store = PendingTaskTestStorage()
        let manager = await pendingTaskManagerFixture(store)
        var data = try importData([])
        data.append(Data(repeating: 32, count: PendingTaskManager.importByteLimit - data.count))
        let result = try await manager.importTasks(data: data, knownStartedIDs: [])
        XCTAssertEqual(result, [])
        data.append(32)
        await expectPendingTaskError(.fileTooLarge) {
            _ = try await manager.importTasks(data: data, knownStartedIDs: [])
        }
        let writes = await store.writeCount
        XCTAssertEqual(writes, 0)
        XCTAssertNil(manager.storageError)
    }

    func testMalformedAndUnknownVersionImportsNeverWrite() async throws {
        let store = PendingTaskTestStorage()
        let manager = await pendingTaskManagerFixture(store)
        let cases: [(Data, PendingTaskError)] = [
            (Data("{".utf8), .invalidImportFormat),
            (Data("[]".utf8), .invalidImportFormat),
            (Data("{\"version\":1,\"tasks\":{}}".utf8), .invalidImportFormat),
            (Data("{\"version\":\"1\",\"tasks\":[]}".utf8), .invalidImportFormat),
            (try importData([importEntry()], version: 99), .unsupportedVersion(99))
        ]
        for (data, failure) in cases {
            await expectPendingTaskError(failure) { _ = try await manager.importTasks(data: data, knownStartedIDs: []) }
        }
        let writes = await store.writeCount
        XCTAssertEqual(writes, 0)
        XCTAssertNil(manager.storageError)
    }

    func testBatchWriteFailureDoesNotPublishAddedResultsAndCanRetryAfterReload() async throws {
        let original = pendingTaskFixture(id: "existing")
        let initialData = try pendingTaskStoreData([original])
        let store = PendingTaskTestStorage(data: initialData, behavior: .failBeforeWrite)
        let manager = await pendingTaskManagerFixture(store)
        let data = try importData([importEntry(id: "a"), importEntry(id: "b")])
        await expectPendingTaskError(.writeFailed) { _ = try await manager.importTasks(data: data, knownStartedIDs: []) }
        XCTAssertEqual(manager.items, [original])
        let snapshot = await store.data
        XCTAssertEqual(snapshot, initialData)
        await store.setBehavior(.succeed)
        await expectPendingTaskError(.storageUnavailable) { _ = try await manager.importTasks(data: data, knownStartedIDs: []) }
        let reloaded = await manager.retryLoading()
        XCTAssertTrue(reloaded)
        let result = try await manager.importTasks(data: data, knownStartedIDs: [])
        XCTAssertEqual(result.map(\.outcome), [.added, .added])
        XCTAssertEqual(manager.items.count, 3)
        let writes = await store.writeCount
        XCTAssertEqual(writes, 2)
    }

    func testBatchWriteThenThrowReloadsAndRepeatedImportOnlyReportsDuplicates() async throws {
        let store = PendingTaskTestStorage(behavior: .failAfterWrite)
        let manager = await pendingTaskManagerFixture(store)
        let data = try importData([importEntry(id: "a"), importEntry(id: "b")])
        await expectPendingTaskError(.writeFailed) { _ = try await manager.importTasks(data: data, knownStartedIDs: []) }
        XCTAssertTrue(manager.items.isEmpty)
        await expectPendingTaskError(.storageUnavailable) { _ = try await manager.importTasks(data: data, knownStartedIDs: []) }
        let reloaded = await manager.retryLoading()
        XCTAssertTrue(reloaded)
        let result = try await manager.importTasks(data: data, knownStartedIDs: [])
        XCTAssertEqual(result.map(\.outcome), [.duplicate, .duplicate])
        XCTAssertEqual(manager.items.count, 2)
        let writes = await store.writeCount
        XCTAssertEqual(writes, 1)
    }

    func testInvalidClockRejectsImportBeforeWriting() async throws {
        let store = PendingTaskTestStorage()
        let manager = PendingTaskManager(storageURL: pendingTaskTestURL,
            readData: { _ in try await store.read() }, writeData: { data, _ in try await store.write(data) },
            now: { Date(timeIntervalSinceReferenceDate: .infinity) })
        await manager.waitUntilLoaded()
        let data = try importData([importEntry()])
        await expectPendingTaskError(.invalidCreatedAt) { _ = try await manager.importTasks(data: data, knownStartedIDs: []) }
        let writes = await store.writeCount
        XCTAssertEqual(writes, 0)
    }

    func testExplicitImportAllowsSymbolicLinkToRegularFileAndKeepsSourceUnchanged() async throws {
        let files = try PendingTaskTestFiles()
        let target = files.directory.appendingPathComponent("import.json")
        let link = files.directory.appendingPathComponent("chosen-link.json")
        let data = try importData([importEntry()])
        try data.write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let direct = try await PendingTaskManager.readImportFile(target)
        let linked = try await PendingTaskManager.readImportFile(link)
        XCTAssertEqual(direct, data)
        XCTAssertEqual(linked, data)
        XCTAssertEqual(try Data(contentsOf: target), data)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    func testImportRejectsFIFODeviceDirectoryAndLinkToFIFO() async throws {
        let files = try PendingTaskTestFiles()
        let fifo = files.directory.appendingPathComponent("input.fifo")
        let fifoLink = files.directory.appendingPathComponent("fifo-link")
        let deviceLink = files.directory.appendingPathComponent("device-link")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        try FileManager.default.createSymbolicLink(at: fifoLink, withDestinationURL: fifo)
        try FileManager.default.createSymbolicLink(at: deviceLink,
            withDestinationURL: URL(fileURLWithPath: "/dev/null"))
        for url in [fifo, fifoLink, deviceLink, files.directory] {
            await expectPendingTaskError(.notRegularFile) { _ = try await PendingTaskManager.readImportFile(url) }
        }
    }

    func testImportFileReadEnforcesByteLimitBeforeReturningData() async throws {
        let files = try PendingTaskTestFiles()
        let url = files.directory.appendingPathComponent("import.json")
        let exact = Data(repeating: 32, count: PendingTaskManager.importByteLimit)
        try exact.write(to: url)
        let read = try await PendingTaskManager.readImportFile(url)
        XCTAssertEqual(read, exact)
        var oversized = exact
        oversized.append(32)
        try oversized.write(to: url)
        await expectPendingTaskError(.fileTooLarge) { _ = try await PendingTaskManager.readImportFile(url) }
        XCTAssertEqual(try Data(contentsOf: url), oversized)
    }

    func testImportMissingFileAndNonFileURLReportReadFailure() async throws {
        let files = try PendingTaskTestFiles()
        await expectPendingTaskError(.readFailed) { _ = try await PendingTaskManager.readImportFile(files.storageURL) }
        let nonFileURL = try XCTUnwrap(URL(string: "data:application/json,{}"))
        await expectPendingTaskError(.readFailed) { _ = try await PendingTaskManager.readImportFile(nonFileURL) }
    }

    private func importEntry(source: String = "test", id: String = "external-1", title: String = "导入任务") -> [String: String] {
        ["source": source, "id": id, "title": title]
    }

    private func importData(_ tasks: [Any], version: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": version, "tasks": tasks], options: [.sortedKeys])
    }
}
