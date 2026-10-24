import XCTest
@testable import XNook

@MainActor
final class FocusLinkIndexTests: XCTestCase {
    func testLegacyDuplicateIDsPreserveFirstMatchAndOrder() throws {
        let suiteName = "XNook.FocusIndex.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let id = UUID(), newID = UUID()
        let first = LinkedFile(id: id, name: "Original first", icon: "doc")
        let duplicate = LinkedFile(id: id, name: "Legacy duplicate", icon: "photo")
        let session = FocusSession(id: UUID(), title: "Legacy", eventIdentifier: nil, startedAt: Date(),
                                   scheduledEndAt: nil, endedAt: nil, state: .active, linkedNote: nil, linkedFiles: [first, duplicate])
        defaults.set(try JSONEncoder().encode(FocusSessionStore(activeSession: session, history: [])), forKey: "nookflow.sessions")
        var writes = 0
        let manager = FocusSessionManager(userDefaults: defaults, writeData: { _ in writes += 1 })
        let bookmark = Data([1, 2])
        let input = [LinkedFile(id: id, name: "Must not rename", icon: "folder", bookmarkData: bookmark),
                     LinkedFile(id: newID, name: "First input", icon: "doc"),
                     LinkedFile(id: newID, name: "Duplicate input", icon: "folder", bookmarkData: bookmark)]
        XCTAssertTrue(manager.linkFiles(input, to: session.id))
        XCTAssertEqual(manager.activeSession?.linkedFiles, [
            LinkedFile(id: id, name: first.name, icon: first.icon, bookmarkData: bookmark), duplicate,
            LinkedFile(id: newID, name: "First input", icon: "doc", bookmarkData: bookmark)
        ])
        XCTAssertEqual(writes, 1)
        XCTAssertTrue(manager.linkFiles(input, to: session.id))
        XCTAssertEqual(writes, 1)
    }
}
