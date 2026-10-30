import XCTest
import Foundation

final class AppPermissionConfigurationTests: XCTestCase {
    func testHardenedRuntimeDeclaresEveryProtectedResourceUsedByTheApp() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("XNook.entitlements"))
        let entitlements = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        // 系统隐私开关不能替代签名能力，正式包必须同时具备这两层授权。
        for key in ["com.apple.security.personal-information.calendars",
                    "com.apple.security.automation.apple-events",
                    "com.apple.security.files.bookmarks.app-scope"] {
            XCTAssertEqual(entitlements[key] as? Bool, true, "缺少正式包能力声明：\(key)")
        }
        let info = try Data(contentsOf: root.appendingPathComponent("Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any])
        for key in ["NSCalendarsFullAccessUsageDescription", "NSAppleEventsUsageDescription"] {
            XCTAssertFalse((plist[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
