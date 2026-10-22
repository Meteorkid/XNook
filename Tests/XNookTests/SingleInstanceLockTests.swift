import XCTest
import Darwin
@testable import XNook

final class SingleInstanceLockTests: XCTestCase {
    func testLockFilenameUsesProductionLockOutsideBuildDirectory() {
        let bundleURL = URL(fileURLWithPath: "/Applications/X Nook.app")

        XCTAssertEqual(
            SingleInstanceLock.lockFilename(for: bundleURL),
            "xnook_instance.lock"
        )
    }

    func testDevelopmentBundleUsesTheSameDataLockAsProduction() {
        let bundleURL = URL(fileURLWithPath: "/Users/meteor/github/XNook/.build/X Nook.app")

        XCTAssertEqual(
            SingleInstanceLock.lockFilename(for: bundleURL),
            "xnook_instance.lock"
        )
    }

    func testBothBundleTypesAndLegacyDevelopmentInstancesExcludeEachOther() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let production = URL(fileURLWithPath: "/Applications/X Nook.app")
        let development = URL(fileURLWithPath: "/tmp/project/.build/X Nook.app")
        let held = try XCTUnwrap(SingleInstanceLock.acquireFiles(in: directory, bundleURL: production))
        XCTAssertNil(try SingleInstanceLock.acquireFiles(in: directory, bundleURL: development))
        held.forEach { close($0) }
        let legacy = open(directory.appendingPathComponent("xnook_dev_instance.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(legacy, 0)
        defer { close(legacy) }
        XCTAssertEqual(flock(legacy, LOCK_EX | LOCK_NB), 0)
        XCTAssertNil(try SingleInstanceLock.acquireFiles(in: directory, bundleURL: production))
        XCTAssertEqual(flock(legacy, LOCK_UN), 0)
        let recovered = try XCTUnwrap(SingleInstanceLock.acquireFiles(in: directory, bundleURL: development))
        recovered.forEach { close($0) }
    }

    func testUnsafeLockPathFailsWithoutWritingThroughIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("xnook_instance.lock"), withDestinationURL: target)
        XCTAssertThrowsError(try SingleInstanceLock.acquireFiles(in: directory, bundleURL: URL(fileURLWithPath:"/Applications/X Nook.app")))
        XCTAssertEqual(try String(contentsOf: target), "keep")
    }

    func testIsDevelopmentBundleDetectsBuildPathComponent() {
        XCTAssertTrue(
            SingleInstanceLock.isDevelopmentBundle(
                URL(fileURLWithPath: "/tmp/some-project/.build/X Nook.app")
            )
        )
        XCTAssertFalse(
            SingleInstanceLock.isDevelopmentBundle(
                URL(fileURLWithPath: "/Applications/X Nook.app")
            )
        )
    }
}
