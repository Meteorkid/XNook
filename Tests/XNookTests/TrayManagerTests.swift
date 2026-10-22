import XCTest
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

    private func makeManager() -> TrayManager {
        TrayManager(storageURL: storageURL, resolveBookmark: { data in
            let bookmark = String(decoding: data, as: UTF8.self)
            guard bookmark != "offline" else { return nil }
            return (URL(fileURLWithPath: "/unused/\(bookmark).txt"), bookmark == "stale")
        }, makeBookmark: { Data($0.lastPathComponent.utf8) })
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
