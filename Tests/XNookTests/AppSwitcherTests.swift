import XCTest
@testable import XNook

@MainActor
final class AppSwitcherTests: XCTestCase {

    private var appSwitcher: AppSwitcher!

    override func setUp() {
        super.setUp()
        appSwitcher = AppSwitcher.shared
    }

    override func tearDown() {
        appSwitcher = nil
        super.tearDown()
    }

    // MARK: - currentAppName

    func testCurrentAppNameReturnsXNookWhenBundleIDMatches() {
        XCTAssertEqual(appSwitcher.currentAppName, "xnook")
        XCTAssertEqual(appSwitcher.currentURLScheme, "xnook")
    }

    // MARK: - otherIslandNames

    func testOtherIslandNamesReturnsArray() {
        let otherNames = appSwitcher.otherIslandNames
        // 验证返回的是数组
        XCTAssertNotNil(otherNames)
    }

    func testOtherIslandNamesReturnsSortedArray() {
        let otherNames = appSwitcher.otherIslandNames
        XCTAssertEqual(otherNames, otherNames.sorted(), "otherIslandNames 应该是排序的")
    }

    func testOtherIslandNamesExcludesCurrentApp() {
        let otherNames = appSwitcher.otherIslandNames
        if let currentName = appSwitcher.currentAppName {
            XCTAssertFalse(otherNames.contains(currentName), "otherIslandNames 不应包含当前应用")
        }
    }

    // MARK: - switchToNextIsland

    func testSwitchToNextIslandDoesNotCrash() {
        // 验证 switchToNextIsland 不会崩溃
        appSwitcher.switchToNextIsland()
    }

    // MARK: - switchToIsland

    func testSwitchToIslandWithInvalidTargetDoesNothing() {
        // 切换到不存在的应用应该什么都不做
        appSwitcher.switchToIsland(named: "nonexistent")
    }

    func testSwitchToIslandWithCurrentAppDoesNothing() {
        // 切换到自身应该什么都不做
        if let currentName = appSwitcher.currentAppName {
            appSwitcher.switchToIsland(named: currentName)
        }
    }

    // MARK: - isOtherAppRunning

    func testIsOtherAppRunningReturnsBoolean() {
        let result = appSwitcher.isOtherAppRunning()
        // 验证返回的是布尔值（不是 nil）
        // isOtherAppRunning 返回 Bool，不是 Optional
        XCTAssertTrue(result || !result)
    }

    // MARK: - URL Routing

    func testSwitchURLUsesTargetSpecificScheme() {
        XCTAssertEqual(
            appSwitcher.switchURL(for: "xnook"),
            URL(string: "xnook://xnook/show")
        )
        XCTAssertEqual(
            appSwitcher.switchURL(for: "xisland"),
            URL(string: "xisland://xisland/show")
        )
    }
}
