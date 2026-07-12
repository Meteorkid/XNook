import XCTest
@testable import XNook

final class SingleInstanceLockTests: XCTestCase {
    func testLockFilenameUsesProductionLockOutsideBuildDirectory() {
        let bundleURL = URL(fileURLWithPath: "/Applications/X Nook.app")

        XCTAssertEqual(
            SingleInstanceLock.lockFilename(for: bundleURL),
            "xnook_instance.lock"
        )
    }

    func testLockFilenameUsesDevelopmentLockInsideBuildDirectory() {
        let bundleURL = URL(fileURLWithPath: "/Users/meteor/github/XNook/.build/X Nook.app")

        XCTAssertEqual(
            SingleInstanceLock.lockFilename(for: bundleURL),
            "xnook_dev_instance.lock"
        )
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
