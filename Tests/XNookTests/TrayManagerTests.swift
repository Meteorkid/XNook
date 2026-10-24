import XCTest
import AppKit
import UniformTypeIdentifiers
import Observation
@testable import XNook

@MainActor
final class TrayManagerTests: XCTestCase {
    private var directory: URL!
    private var storageURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("XNook-TrayTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storageURL = directory.appendingPathComponent("tray_files.json")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testUnavailableRecordSurvivesAddingAndRemovingAnotherFile() throws {
        let unavailable = Record(bookmark: "offline")
        let available = Record(bookmark: "available")
        try write([unavailable, available])
        let manager = makeManager()

        XCTAssertEqual(manager.unavailableFileCount, 1)
        manager.addFile(from: directory.appendingPathComponent("new.txt"))
        manager.removeFile(try XCTUnwrap(manager.files.first { $0.id == available.id }))

        let records = try read()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first { $0.id == unavailable.id }, unavailable)
        XCTAssertFalse(records.contains { $0.id == available.id })
    }

    func testUnavailableRecordSurvivesBookmarkRefreshAndLaterSave() throws {
        let unavailable = Record(bookmark: "offline")
        let stale = Record(bookmark: "stale")
        try write([unavailable, stale])
        let manager = makeManager()

        XCTAssertEqual(try read().first { $0.id == unavailable.id }, unavailable)
        XCTAssertEqual(try read().first { $0.id == stale.id }?.bookmarkData, Data("stale.txt".utf8))
        manager.addFile(from: directory.appendingPathComponent("new.txt"))
        XCTAssertEqual(try read().first { $0.id == unavailable.id }, unavailable)
    }

    func testUnavailableRecordCanBeResolvedAfterReload() throws {
        let unavailable = Record(bookmark: "offline")
        try write([unavailable])
        let manager = makeManager()
        manager.addFile(from: directory.appendingPathComponent("new.txt"))

        let reloaded = TrayManager(storageURL: storageURL, resolveBookmark: { data in
            (URL(fileURLWithPath: "/unused/\(String(decoding: data, as: UTF8.self)).txt"), false)
        }, makeBookmark: { Data($0.lastPathComponent.utf8) })

        XCTAssertEqual(reloaded.unavailableFileCount, 0)
        XCTAssertTrue(reloaded.files.contains { $0.id == unavailable.id })
        XCTAssertEqual(reloaded.files.count, 2)
    }

    func testFailedStaleBookmarkRefreshPreservesOriginalRecord() throws {
        let stale = Record(bookmark: "stale")
        try write([stale])
        let manager = TrayManager(storageURL: storageURL, resolveBookmark: { _ in
            (URL(fileURLWithPath: "/unused/stale.txt"), true)
        }, makeBookmark: { _ in throw CocoaError(.fileReadNoPermission) })

        XCTAssertEqual(manager.unavailableFileCount, 1)
        XCTAssertTrue(manager.files.isEmpty)
        XCTAssertEqual(try read(), [stale])
    }

    func testCorruptStorageIsNotOverwrittenByAddOrRemove() throws {
        let corruptData = Data("not valid json".utf8)
        try corruptData.write(to: storageURL)
        let manager = makeManager()

        XCTAssertEqual(manager.issue, .readFailed)
        manager.addFile(from: directory.appendingPathComponent("new.txt"))
        manager.removeFile(.init(id: UUID(), bookmarkData: Data(), name: "unused", icon: "doc", size: 0, addedAt: Date()))

        XCTAssertEqual(try Data(contentsOf: storageURL), corruptData)
        XCTAssertTrue(manager.files.isEmpty)
        XCTAssertEqual(manager.issue, .readFailed)
    }

    func testFailedReloadKeepsDisplayedRecordsAndBlocksRemovalUntilSuccessfulRetry() throws {
        let record = Record(bookmark: "available")
        try write([record])
        let manager = makeManager()
        let file = try XCTUnwrap(manager.files.first)
        let corruptData = Data("broken".utf8)
        try corruptData.write(to: storageURL)

        manager.loadFiles()
        manager.removeFile(file)
        XCTAssertEqual(manager.files.first?.id, record.id)
        XCTAssertEqual(try Data(contentsOf: storageURL), corruptData)

        try write([record])
        manager.loadFiles()
        manager.removeFile(file)
        XCTAssertNil(manager.issue)
        XCTAssertTrue(try read().isEmpty)
    }

    func testBookmarkCreationFailureDoesNotAddFileOrOverwriteStorage() throws {
        let record = Record(bookmark: "available")
        try write([record])
        let originalData = try Data(contentsOf: storageURL)
        let manager = TrayManager(storageURL: storageURL, resolveBookmark: { _ in
            (URL(fileURLWithPath: "/unused/available.txt"), false)
        }, makeBookmark: { _ in throw CocoaError(.fileReadNoPermission) })

        manager.addFile(from: directory.appendingPathComponent("new.txt"))

        XCTAssertEqual(manager.files.count, 1)
        XCTAssertEqual(manager.issue, .bookmarkCreationFailed)
        XCTAssertEqual(try Data(contentsOf: storageURL), originalData)
    }

    func testFailedSaveDoesNotShowNewFileAsPersisted() throws {
        let manager = makeManager()
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: false)

        manager.addFile(from: directory.appendingPathComponent("new.txt"))

        XCTAssertTrue(manager.files.isEmpty)
        XCTAssertEqual(manager.issue, .saveFailed)
    }

    func testPastingTwentyFilesWritesOnceAndPreservesOfflineRecord() throws {
        let offline = Record(bookmark: "offline")
        let existing = [offline] + (1..<1_000).map { Record(bookmark: "existing-\($0)") }
        try write(existing)
        var writeCount = 0
        let manager = makeManager { data, url in
            writeCount += 1
            try data.write(to: url, options: .atomic)
        }
        let urls = (0..<20).map { directory.appendingPathComponent("new-\($0).txt") }
        let pasteboard = NSPasteboard(name: .init("XNook-TrayTests-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects(urls.map { $0 as NSURL }))

        manager.addFile(from: pasteboard)

        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(manager.files.count, 1_019)
        XCTAssertEqual(manager.files.suffix(20).map(\.name), urls.map(\.lastPathComponent))
        XCTAssertEqual(manager.unavailableFileCount, 1)
        let records = try read()
        XCTAssertEqual(records.count, 1_020)
        XCTAssertEqual(records.first { $0.id == offline.id }, offline)
    }

    func testBatchPreservesDuplicateURLsAsDistinctFiles() throws {
        var writeCount = 0
        let manager = makeManager { data, url in
            writeCount += 1
            try data.write(to: url, options: .atomic)
        }
        let url = directory.appendingPathComponent("same.txt")

        XCTAssertTrue(manager.addFiles(from: [url, url]))

        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(manager.files.map(\.name), ["same.txt", "same.txt"])
        XCTAssertEqual(Set(manager.files.map(\.id)).count, 2)
        XCTAssertEqual(try read().count, 2)
    }

    func testRemovingUnknownOrAlreadyRemovedFileDoesNotWriteOrClearIssue() throws {
        try write([Record(bookmark: "available")])
        var writeCount = 0
        let manager = makeManager { data, url in
            writeCount += 1
            try data.write(to: url, options: .atomic)
        }
        let original = try XCTUnwrap(manager.files.first)
        let missing = TrayManager.TrayFile(
            id: UUID(), bookmarkData: Data(), name: "missing", icon: "doc", size: 0, addedAt: Date()
        )

        manager.removeFile(missing)
        XCTAssertEqual(writeCount, 0)
        XCTAssertEqual(manager.files.map(\.id), [original.id])

        manager.removeFile(original)
        XCTAssertEqual(writeCount, 1)
        XCTAssertFalse(manager.addFiles(from: [try XCTUnwrap(URL(string: "https://example.com/file.txt"))]))
        manager.removeFile(original)
        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(manager.issue, .fileUnavailable)
    }

    func testBatchWriteFailureRollsBackAllFilesAndPreservesOfflineStorage() throws {
        let offline = Record(bookmark: "offline")
        let available = Record(bookmark: "available")
        try write([offline, available])
        let originalData = try Data(contentsOf: storageURL)
        var writeCount = 0
        let manager = makeManager { _, _ in
            writeCount += 1
            throw CocoaError(.fileWriteNoPermission)
        }

        XCTAssertFalse(manager.addFiles(from: [
            directory.appendingPathComponent("first.txt"),
            directory.appendingPathComponent("second.txt")
        ]))

        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(manager.files.map(\.id), [available.id])
        XCTAssertEqual(manager.unavailableFileCount, 1)
        XCTAssertEqual(manager.issue, .saveFailed)
        XCTAssertEqual(try Data(contentsOf: storageURL), originalData)
    }

    func testLaterBookmarkFailureDoesNotCommitEarlierFiles() throws {
        let available = Record(bookmark: "available")
        try write([available])
        let originalData = try Data(contentsOf: storageURL)
        var bookmarkNames: [String] = []
        var writeCount = 0
        let manager = TrayManager(storageURL: storageURL, resolveBookmark: { _ in
            (URL(fileURLWithPath: "/unused/available.txt"), false)
        }, makeBookmark: { url in
            bookmarkNames.append(url.lastPathComponent)
            if url.lastPathComponent == "second.txt" { throw CocoaError(.fileReadNoPermission) }
            return Data(url.lastPathComponent.utf8)
        }, writeData: { _, _ in writeCount += 1 })

        XCTAssertFalse(manager.addFiles(from: [
            directory.appendingPathComponent("first.txt"),
            directory.appendingPathComponent("second.txt"),
            directory.appendingPathComponent("third.txt")
        ]))

        XCTAssertEqual(bookmarkNames, ["first.txt", "second.txt"])
        XCTAssertEqual(writeCount, 0)
        XCTAssertEqual(manager.files.map(\.id), [available.id])
        XCTAssertEqual(manager.issue, .bookmarkCreationFailed)
        XCTAssertEqual(try Data(contentsOf: storageURL), originalData)
    }

    func testBatchRejectsNonFileURLsBeforeCreatingBookmarks() throws {
        var bookmarkCount = 0
        var writeCount = 0
        let manager = TrayManager(storageURL: storageURL, makeBookmark: { _ in
            bookmarkCount += 1
            return Data()
        }, writeData: { _, _ in writeCount += 1 })

        XCTAssertFalse(manager.addFiles(from: [
            directory.appendingPathComponent("first.txt"),
            try XCTUnwrap(URL(string: "https://example.com/file.txt"))
        ]))
        XCTAssertFalse(manager.addFiles(from: []))

        XCTAssertEqual(bookmarkCount, 0)
        XCTAssertEqual(writeCount, 0)
        XCTAssertTrue(manager.files.isEmpty)
        XCTAssertEqual(manager.issue, .fileUnavailable)
    }

    func testDropWaitsForAllProvidersAndPreservesInputOrder() async throws {
        let providers = (0..<3).map { _ in fileProvider() }
        let unsupported = NSItemProvider(object: "text" as NSString)
        let started = expectation(description: "All file providers start loading")
        started.expectedFulfillmentCount = 3
        let written = expectation(description: "The complete drop is written once")
        var pending: [Int: CheckedContinuation<URL, Error>] = [:]
        var writeCount = 0
        let manager = TrayManager(storageURL: storageURL, makeBookmark: { Data($0.lastPathComponent.utf8) },
                                  writeData: { data, url in
            writeCount += 1
            try data.write(to: url, options: .atomic)
            written.fulfill()
        }, loadDropURL: { provider in
            let index = try XCTUnwrap(providers.firstIndex { $0 === provider })
            return try await withCheckedThrowingContinuation { continuation in
                pending[index] = continuation
                started.fulfill()
            }
        })

        XCTAssertTrue(manager.handleDrop([providers[0], unsupported, providers[1], providers[2]]))
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(manager.files.isEmpty)
        XCTAssertEqual(writeCount, 0)
        pending[2]?.resume(returning: directory.appendingPathComponent("third.txt"))
        pending[0]?.resume(returning: directory.appendingPathComponent("first.txt"))
        XCTAssertTrue(manager.files.isEmpty)
        pending[1]?.resume(returning: directory.appendingPathComponent("second.txt"))
        await fulfillment(of: [written], timeout: 1)

        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(manager.files.map(\.name), ["first.txt", "second.txt", "third.txt"])
        XCTAssertNil(manager.issue)
    }

    func testFailedDropProviderRejectsEntireBatch() async throws {
        let providers = [fileProvider(), fileProvider()]
        let failed = expectation(description: "Drop failure is reported")
        var writeCount = 0
        let manager = TrayManager(storageURL: storageURL, makeBookmark: { Data($0.lastPathComponent.utf8) },
                                  writeData: { _, _ in writeCount += 1 }, loadDropURL: { provider in
            if provider === providers[1] { throw CocoaError(.fileReadUnknown) }
            return self.directory.appendingPathComponent("first.txt")
        })
        withObservationTracking {
            _ = manager.issue
        } onChange: {
            failed.fulfill()
        }

        XCTAssertTrue(manager.handleDrop(providers))
        await fulfillment(of: [failed], timeout: 1)

        XCTAssertTrue(manager.files.isEmpty)
        XCTAssertEqual(writeCount, 0)
        XCTAssertEqual(manager.issue, .fileUnavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path))
    }

    func testDropLoadsRegisteredFileURLsWithDefaultLoader() async throws {
        let urls = [directory.appendingPathComponent("first.txt"), directory.appendingPathComponent("second.txt")]
        let written = expectation(description: "Registered file URLs are written together")
        var writeCount = 0
        let manager = TrayManager(storageURL: storageURL, makeBookmark: { Data($0.lastPathComponent.utf8) },
                                  writeData: { data, url in
            writeCount += 1
            try data.write(to: url, options: .atomic)
            written.fulfill()
        })

        XCTAssertTrue(manager.handleDrop(urls.map { NSItemProvider(object: $0 as NSURL) }))
        await fulfillment(of: [written], timeout: 1)

        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(manager.files.map(\.name), urls.map(\.lastPathComponent))
        XCTAssertNil(manager.issue)
    }

    func testDropWithoutFileProvidersOrWithUnreadableStorageIsRejected() throws {
        var loadCount = 0
        let manager = TrayManager(storageURL: storageURL, loadDropURL: { _ in
            loadCount += 1
            return self.directory.appendingPathComponent("unused.txt")
        })

        XCTAssertFalse(manager.handleDrop([]))
        XCTAssertFalse(manager.handleDrop([NSItemProvider(object: "text" as NSString)]))
        try Data("broken".utf8).write(to: storageURL)
        manager.loadFiles()
        XCTAssertFalse(manager.handleDrop([fileProvider()]))
        XCTAssertEqual(loadCount, 0)
        XCTAssertEqual(manager.issue, .readFailed)
    }

    private func fileProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(nil, CocoaError(.fileReadUnknown))
            return nil
        }
        return provider
    }

    private func makeManager(
        writeData: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    ) -> TrayManager {
        TrayManager(storageURL: storageURL, resolveBookmark: { data in
            let bookmark = String(decoding: data, as: UTF8.self)
            guard bookmark != "offline" else { return nil }
            return (URL(fileURLWithPath: "/unused/\(bookmark).txt"), bookmark == "stale")
        }, makeBookmark: { Data($0.lastPathComponent.utf8) }, writeData: writeData)
    }

    private func write(_ records: [Record]) throws {
        try JSONEncoder().encode(records).write(to: storageURL, options: .atomic)
    }

    private func read() throws -> [Record] {
        try JSONDecoder().decode([Record].self, from: Data(contentsOf: storageURL))
    }

    /// 与既有磁盘格式一致，避免测试依赖管理器的私有持久化实现。
    private struct Record: Codable, Equatable {
        let id: UUID
        let bookmarkData: Data
        let size: Int
        let addedAt: Date

        init(bookmark: String) {
            id = UUID()
            bookmarkData = Data(bookmark.utf8)
            size = 42
            addedAt = Date(timeIntervalSince1970: 1_700_000_000)
        }
    }
}
