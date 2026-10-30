import XCTest
import Carbon
import EventKit
import ServiceManagement
@testable import XNook

@MainActor
final class SettingsPermissionsTests: XCTestCase {
    func testAutomationSkipsPermissionProbeForMissingOrStoppedPlayers() {
        for installed in [false, true] {
            var probes = 0
            let state = SettingsAutomationApp.music.permissionState(
                isInstalled: { _ in installed }, runningProcessIdentifier: { _ in nil },
                determinePermission: { _, _ in probes += 1; return noErr })
            XCTAssertEqual(state, installed ? .notRunning : .notInstalled)
            XCTAssertEqual(probes, 0)
        }
    }

    func testAutomationMapsSystemResultsWithoutRequestingConsent() {
        for (result, expected) in [(OSStatus(noErr), SettingsPermissionState.allowed),
            (OSStatus(errAEEventWouldRequireUserConsent), .notRequested),
            (OSStatus(errAEEventNotPermitted), .denied),
            (OSStatus(procNotFound), .notRunning), (OSStatus(-1), .unknown)] {
            let state = SettingsAutomationApp.spotify.permissionState(
                isInstalled: { XCTAssertEqual($0, "com.spotify.client"); return true },
                runningProcessIdentifier: { _ in 123 },
                determinePermission: { processIdentifier, askUserIfNeeded in
                    XCTAssertEqual(processIdentifier, 123)
                    XCTAssertFalse(askUserIfNeeded)
                    return result
                })
            XCTAssertEqual(state, expected)
        }
    }

    func testRefreshShowsIndependentPlayerPermissions() async {
        let permissions = SettingsPermissions(readCalendar: { .fullAccess }, readLoginItems: { .enabled },
            readAutomation: { app in app == .music ? .allowed : .denied })
        await permissions.refresh().value
        XCTAssertEqual(permissions.automation[.music], .allowed)
        XCTAssertEqual(permissions.automation[.spotify], .denied)
    }

    func testCancelledRefreshDoesNotStartAnAutomationQuery() async {
        let permissions = SettingsPermissions(readCalendar: { .notDetermined }, readLoginItems: { .notRegistered },
            readAutomation: { _ in XCTFail("Cancelled refresh must not query the system"); return .allowed })
        // 同一主 actor 回合取消，任务尚未获得执行机会。
        let task = permissions.refresh()
        task.cancel()
        await task.value
        XCTAssertEqual(permissions.automation, [.music: .unknown, .spotify: .unknown])
    }

    func testLateCancelledRefreshCannotOverwriteNewerAutomationStates() async {
        let started = expectation(description: "Old automation read suspended")
        let gate = AutomationPermissionReadGate(started: started)
        let permissions = SettingsPermissions(readCalendar: { .notDetermined }, readLoginItems: { .notRegistered },
            readAutomation: { _ in await gate.read() })
        let oldRefresh = permissions.refresh()
        await fulfillment(of: [started], timeout: 1)

        await permissions.refresh().value
        XCTAssertEqual(permissions.automation, [.music: .allowed, .spotify: .allowed])
        await gate.finish(returning: .denied)
        await oldRefresh.value

        XCTAssertEqual(permissions.automation, [.music: .allowed, .spotify: .allowed])
        let reads = await gate.reads
        XCTAssertEqual(reads, 3, "旧刷新返回后必须停止，不能再查询第二个播放器")
    }

    func testPendingAutomationReadDoesNotKeepPermissionsAlive() async {
        let started = expectation(description: "Automation read suspended")
        let gate = AutomationPermissionReadGate(started: started)
        var permissions: SettingsPermissions? = SettingsPermissions(readCalendar: { .notDetermined },
            readLoginItems: { .notRegistered }, readAutomation: { _ in await gate.read() })
        weak var weakPermissions = permissions
        let task = permissions?.refresh()
        await fulfillment(of: [started], timeout: 1)
        permissions = nil
        XCTAssertNil(weakPermissions)
        await gate.finish()
        await task?.value
    }

    func testLoginRefreshUsesSystemStateWithoutChangingRegistrationOrPreference() {
        var systemStatus = SMAppService.Status.notRegistered
        var registrations = 0
        var preferenceWrites = 0
        let permissions = SettingsPermissions(readCalendar: { .notDetermined }, readLoginItems: { systemStatus },
            readAutomation: { _ in .unknown },
            writeLoginItems: { _ in registrations += 1 },
            writeLoginPreference: { _ in preferenceWrites += 1 })
        for (status, enabled) in [(SMAppService.Status.enabled, true), (.notRegistered, false),
            (.requiresApproval, true), (.notFound, false)] {
            systemStatus = status
            permissions.refresh()
            XCTAssertEqual(permissions.launchAtLoginEnabled, enabled)
        }
        XCTAssertEqual(registrations, 0)
        XCTAssertEqual(preferenceWrites, 0)
    }

    func testExplicitLoginChangePreservesPendingApprovalAndStoresPreference() {
        var systemStatus = SMAppService.Status.notRegistered
        var requestedValues: [Bool] = []
        var preferences: [Bool] = []
        let permissions = SettingsPermissions(readCalendar: { .notDetermined }, readLoginItems: { systemStatus },
            readAutomation: { _ in .unknown }, writeLoginItems: { enabled in
                requestedValues.append(enabled)
                systemStatus = enabled ? .requiresApproval : .notRegistered
            }, writeLoginPreference: { preferences.append($0) })
        permissions.setLaunchAtLogin(true)
        XCTAssertTrue(permissions.launchAtLoginEnabled)
        XCTAssertEqual(permissions.loginItems, .requiresApproval)
        permissions.setLaunchAtLogin(false)
        XCTAssertFalse(permissions.launchAtLoginEnabled)
        XCTAssertEqual(requestedValues, [true, false])
        XCTAssertEqual(preferences, [true, false])
    }

    func testLoginFailureKeepsSystemStateAndStoredPreference() {
        let permissions = SettingsPermissions(readCalendar: { .notDetermined }, readLoginItems: { .enabled },
            readAutomation: { _ in .unknown },
            writeLoginItems: { _ in throw CocoaError(.fileWriteNoPermission) },
            writeLoginPreference: { _ in XCTFail("Failed operation must not change the preference") })
        permissions.refresh()
        permissions.setLaunchAtLogin(false)
        XCTAssertTrue(permissions.launchAtLoginEnabled)
        XCTAssertEqual(permissions.loginItems, .allowed)
        XCTAssertNotNil(permissions.loginItemsError)
    }

}

private actor AutomationPermissionReadGate {
    let started: XCTestExpectation
    private(set) var reads = 0
    private var continuation: CheckedContinuation<SettingsPermissionState, Never>?

    init(started: XCTestExpectation) { self.started = started }

    func read() async -> SettingsPermissionState {
        reads += 1
        guard reads == 1 else { return .allowed }
        return await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func finish(returning state: SettingsPermissionState = .allowed) {
        continuation?.resume(returning: state)
        continuation = nil
    }
}
