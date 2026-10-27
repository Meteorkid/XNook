import AppKit
import Carbon
import XCTest
@testable import XNook

@MainActor
final class GlobalPanelShortcutTests: XCTestCase {
    func testLicenseSuspensionUnregistersWithoutLosingPreferenceAndCanResume() throws {
        let fixture = try Fixture(saved: Self.first)
        defer { fixture.cleanup() }
        fixture.controller.activate()
        fixture.controller.suspend()
        fixture.backend.press(1)
        XCTAssertEqual(fixture.invocations, 0)
        XCTAssertFalse(fixture.controller.isActivated)
        XCTAssertTrue(fixture.backend.registered.isEmpty)
        XCTAssertEqual(try fixture.persisted(), Self.first)
        fixture.controller.activate()
        fixture.backend.press(2)
        XCTAssertEqual(fixture.invocations, 1)
        XCTAssertEqual(fixture.controller.activeShortcut, Self.first)
    }

    func testFreshConstructionAndActivationDoNotRegisterOrWriteDefaults() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        XCTAssertTrue(fixture.backend.operations.isEmpty)
        XCTAssertNil(fixture.controller.configuredShortcut)
        fixture.controller.activate()
        XCTAssertTrue(fixture.backend.operations.isEmpty)
        XCTAssertNil(fixture.defaults.object(forKey: GlobalPanelShortcut.storageKey))
    }

    func testUnownedControllerCannotRegisterOrClearStoredConfiguration() throws {
        let fixture = try Fixture(saved: Self.first)
        defer { fixture.cleanup() }
        let data = fixture.defaults.data(forKey: GlobalPanelShortcut.storageKey)
        XCTAssertFalse(fixture.controller.apply(Self.second))
        XCTAssertFalse(fixture.controller.clear())
        fixture.controller.beginRecording()
        XCTAssertFalse(fixture.controller.isRecording)
        XCTAssertEqual(fixture.controller.failure, .inactive)
        XCTAssertTrue(fixture.backend.operations.isEmpty)
        XCTAssertEqual(fixture.defaults.data(forKey: GlobalPanelShortcut.storageKey), data)
    }

    func testSavedShortcutRestoresOnlyOnActivationWithoutRewritingData() throws {
        let fixture = try Fixture(saved: Self.first)
        defer { fixture.cleanup() }
        let data = fixture.defaults.data(forKey: GlobalPanelShortcut.storageKey)
        XCTAssertEqual(fixture.controller.configuredShortcut, Self.first)
        XCTAssertNil(fixture.controller.activeShortcut)
        XCTAssertTrue(fixture.backend.operations.isEmpty)
        fixture.controller.activate()
        fixture.controller.activate()
        XCTAssertEqual(fixture.backend.operations, [.register(1)])
        XCTAssertEqual(fixture.controller.activeShortcut, Self.first)
        XCTAssertEqual(fixture.defaults.data(forKey: GlobalPanelShortcut.storageKey), data)
    }

    func testInvalidSavedValuesArePreservedAndNeverRegistered() throws {
        let validData = try JSONEncoder().encode(Self.first)
        var wrongVersion = try XCTUnwrap(JSONSerialization.jsonObject(with: validData) as? [String: Any])
        wrongVersion["version"] = 2
        let inputs: [Any] = ["wrong type", Data("{".utf8), Data(repeating: 32, count: 1_025),
            try JSONSerialization.data(withJSONObject: wrongVersion)]
        for input in inputs {
            let fixture = try Fixture(raw: input)
            defer { fixture.cleanup() }
            fixture.controller.activate()
            XCTAssertEqual(fixture.controller.failure, .invalidStoredShortcut)
            XCTAssertNil(fixture.controller.activeShortcut)
            XCTAssertTrue(fixture.backend.operations.isEmpty)
            XCTAssertNotNil(fixture.defaults.object(forKey: GlobalPanelShortcut.storageKey))
            XCTAssertTrue(fixture.controller.clear())
            XCTAssertNil(fixture.defaults.object(forKey: GlobalPanelShortcut.storageKey))
        }
    }

    func testValidReplacementRegistersBeforeRemovingOldAndPersistsOnlySuccess() throws {
        let fixture = try Fixture(saved: Self.first)
        defer { fixture.cleanup() }
        fixture.controller.activate()
        XCTAssertTrue(fixture.controller.apply(Self.second))
        XCTAssertEqual(fixture.backend.operations, [.register(1), .register(2), .unregister(1)])
        XCTAssertEqual(fixture.controller.activeShortcut, Self.second)
        XCTAssertEqual(fixture.controller.configuredShortcut, Self.second)
        XCTAssertEqual(try fixture.persisted(), Self.second)
        XCTAssertTrue(fixture.controller.apply(Self.second))
        XCTAssertEqual(fixture.backend.operations.count, 3, "重复应用不重注册")
    }

    func testInvalidRecordingDoesNotHideCleanupForUnreadableStoredData() throws {
        let fixture = try Fixture(raw: Data("{".utf8))
        defer { fixture.cleanup() }
        fixture.controller.activate()
        XCTAssertEqual(fixture.controller.failure, .invalidStoredShortcut)
        XCTAssertTrue(fixture.controller.hasStoredShortcut)
        XCTAssertTrue(fixture.controller.canClear)
        fixture.controller.beginRecording()
        fixture.controller.rejectRecordedInput()
        XCTAssertEqual(fixture.controller.failure, .invalidShortcut)
        XCTAssertNil(fixture.controller.configuredShortcut)
        XCTAssertTrue(fixture.controller.hasStoredShortcut)
        XCTAssertTrue(fixture.controller.canClear, "清除入口不能随错误文案改变而消失")
        XCTAssertTrue(fixture.controller.clear())
        XCTAssertFalse(fixture.controller.hasStoredShortcut)
        XCTAssertFalse(fixture.controller.canClear)
        XCTAssertFalse(fixture.controller.isRecording)
        XCTAssertNil(fixture.defaults.object(forKey: GlobalPanelShortcut.storageKey))
    }

    func testRegistrationConflictKeepsOldRegistrationAndPersistedValue() throws {
        for failure in [GlobalPanelShortcutFailure.conflict, .systemConflict, .registrationFailed(-9868)] {
            let fixture = try Fixture(saved: Self.first)
            defer { fixture.cleanup() }
            fixture.controller.activate()
            fixture.backend.registrationFailure = failure
            XCTAssertFalse(fixture.controller.apply(Self.second))
            XCTAssertEqual(fixture.controller.failure, failure)
            XCTAssertEqual(fixture.backend.operations, [.register(1), .register(2)])
            XCTAssertEqual(fixture.backend.registered, [1: Self.first])
            XCTAssertEqual(fixture.controller.activeShortcut, Self.first)
            XCTAssertEqual(fixture.controller.configuredShortcut, Self.first)
            XCTAssertEqual(try fixture.persisted(), Self.first)
        }
    }

    func testRestoreConflictShowsSavedValueAsInactiveAndCanBeRetried() throws {
        let fixture = try Fixture(saved: Self.first)
        defer { fixture.cleanup() }
        fixture.backend.registrationFailure = .conflict
        fixture.controller.activate()
        XCTAssertEqual(fixture.controller.configuredShortcut, Self.first)
        XCTAssertNil(fixture.controller.activeShortcut)
        XCTAssertEqual(fixture.controller.failure, .conflict)
        fixture.backend.registrationFailure = nil
        XCTAssertTrue(fixture.controller.apply(Self.first))
        XCTAssertEqual(fixture.controller.activeShortcut, Self.first)
    }

    func testOldRemovalFailureRollsBackCandidateAndKeepsOldUIValue() throws {
        let fixture = try Fixture(saved: Self.first)
        defer { fixture.cleanup() }
        fixture.controller.activate()
        fixture.backend.removalFailures.insert(1)
        XCTAssertFalse(fixture.controller.apply(Self.second))
        XCTAssertEqual(fixture.backend.operations, [.register(1), .register(2), .unregister(1), .unregister(2)])
        XCTAssertEqual(fixture.backend.registered, [1: Self.first])
        XCTAssertEqual(fixture.controller.activeShortcut, Self.first)
        XCTAssertEqual(fixture.controller.configuredShortcut, Self.first)
        XCTAssertEqual(try fixture.persisted(), Self.first)
        XCTAssertEqual(fixture.controller.failure, .removalFailed(-1))
    }

    func testFailedRollbackCannotInvokeAndIsCleanedBeforeNextChange() throws {
        let fixture = try Fixture(saved: Self.first)
        defer { fixture.cleanup() }
        fixture.controller.activate()
        fixture.backend.removalFailures = [1, 2]
        XCTAssertFalse(fixture.controller.apply(Self.second))
        XCTAssertEqual(fixture.controller.failure, .rollbackFailed)
        fixture.backend.press(2)
        XCTAssertEqual(fixture.invocations, 0)
        fixture.backend.press(1)
        XCTAssertEqual(fixture.invocations, 1)
        fixture.backend.removalFailures = []
        XCTAssertTrue(fixture.controller.apply(Self.second))
        XCTAssertEqual(Array(fixture.backend.operations.suffix(3)), [.unregister(2), .register(3), .unregister(1)])
        XCTAssertEqual(fixture.backend.registered, [3: Self.second])
        XCTAssertEqual(try fixture.persisted(), Self.second)
    }

    func testClearRemovesOnlyOwnedSettingAfterUnregisterAndPreservesItOnFailure() throws {
        let fixture = try Fixture(saved: Self.first)
        defer { fixture.cleanup() }
        fixture.defaults.set("keep", forKey: "unrelated")
        fixture.controller.activate()
        fixture.backend.removalFailures = [1]
        XCTAssertFalse(fixture.controller.clear())
        XCTAssertEqual(fixture.controller.activeShortcut, Self.first)
        XCTAssertTrue(fixture.controller.hasStoredShortcut)
        XCTAssertEqual(try fixture.persisted(), Self.first)
        fixture.backend.removalFailures = []
        XCTAssertTrue(fixture.controller.clear())
        XCTAssertNil(fixture.controller.activeShortcut)
        XCTAssertNil(fixture.controller.configuredShortcut)
        XCTAssertFalse(fixture.controller.hasStoredShortcut)
        XCTAssertNil(fixture.defaults.object(forKey: GlobalPanelShortcut.storageKey))
        XCTAssertEqual(fixture.defaults.string(forKey: "unrelated"), "keep")
        fixture.backend.press(1)
        XCTAssertEqual(fixture.invocations, 0)
    }

    func testRecordingSuppressesOldShortcutWithoutUnregisteringIt() throws {
        let fixture = try Fixture(saved: Self.first)
        defer { fixture.cleanup() }
        fixture.controller.activate()
        fixture.controller.beginRecording()
        fixture.backend.press(1)
        XCTAssertEqual(fixture.invocations, 0)
        XCTAssertFalse(fixture.controller.isRecording)
        XCTAssertEqual(fixture.backend.operations, [.register(1)])
        fixture.controller.beginRecording()
        fixture.controller.endRecording()
        fixture.backend.press(1)
        XCTAssertEqual(fixture.invocations, 1)
        XCTAssertEqual(fixture.controller.activeShortcut, Self.first)
    }

    func testStaleAndShutdownEventsCannotInvoke() throws {
        let fixture = try Fixture(saved: Self.first)
        defer { fixture.cleanup() }
        fixture.controller.activate()
        XCTAssertTrue(fixture.controller.apply(Self.second))
        fixture.backend.press(1)
        fixture.backend.press(999)
        fixture.backend.press(2)
        XCTAssertEqual(fixture.invocations, 1)
        let queuedHandler = fixture.backend.onPress
        fixture.controller.shutdown()
        fixture.controller.shutdown()
        queuedHandler?(2)
        fixture.controller.activate()
        XCTAssertEqual(fixture.invocations, 1)
        XCTAssertEqual(fixture.backend.operations.last, .shutdown)
        XCTAssertFalse(fixture.controller.isActivated)
        XCTAssertNil(fixture.controller.activeShortcut)
        XCTAssertEqual(try fixture.persisted(), Self.second)
    }

    func testValidationRejectsUnmodifiedKeysUnknownCodesAndControlLabels() throws {
        for value in [GlobalPanelShortcut(keyCode: 45, modifiers: 0, displayKey: "N"),
            .init(keyCode: 45, modifiers: UInt32(optionKey | shiftKey), displayKey: "N"),
            .init(keyCode: 53, modifiers: UInt32(cmdKey), displayKey: "Esc"),
            .init(keyCode: 55, modifiers: UInt32(cmdKey), displayKey: "Cmd"),
            .init(keyCode: 500, modifiers: UInt32(cmdKey), displayKey: "N"),
            .init(keyCode: 45, modifiers: UInt32(cmdKey) | (1 << 30), displayKey: "N"),
            .init(keyCode: 45, modifiers: UInt32(cmdKey), displayKey: ""),
            .init(keyCode: 45, modifiers: UInt32(cmdKey), displayKey: "\nN"),
            .init(keyCode: 45, modifiers: UInt32(cmdKey), displayKey: String(repeating: "N", count: 13))] {
            XCTAssertFalse(value.isValid)
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            fixture.controller.activate()
            XCTAssertFalse(fixture.controller.apply(value))
            XCTAssertTrue(fixture.backend.operations.isEmpty)
            XCTAssertNil(fixture.defaults.object(forKey: GlobalPanelShortcut.storageKey))
        }
        XCTAssertEqual(Self.first.displayTitle, "⌥⌘N")
    }

    func testNativeEventCaptureUsesModifiersAndDisplayLabelWithoutGlobalRegistration() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
            timestamp: 0, windowNumber: 0, context: nil, characters: "n", charactersIgnoringModifiers: "n",
            isARepeat: false, keyCode: 45))
        XCTAssertEqual(GlobalPanelShortcut.captured(from: event), Self.first)
        let repeated = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "n", charactersIgnoringModifiers: "n",
            isARepeat: true, keyCode: 45))
        XCTAssertNil(GlobalPanelShortcut.captured(from: repeated))
    }

    static let first = GlobalPanelShortcut(keyCode: 45, modifiers: UInt32(cmdKey | optionKey), displayKey: "N")
    static let second = GlobalPanelShortcut(keyCode: 49, modifiers: UInt32(controlKey | shiftKey), displayKey: "Space")

    @MainActor
    private final class Fixture {
        let suite = "XNook.GlobalPanelShortcutTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let backend = TestGlobalPanelShortcutBackend()
        var invocations = 0
        lazy var controller = GlobalPanelShortcutController(defaults: defaults, backend: backend) { [weak self] in
            self?.invocations += 1
        }

        init(saved: GlobalPanelShortcut? = nil, raw: Any? = nil) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            if let saved { defaults.set(try JSONEncoder().encode(saved), forKey: GlobalPanelShortcut.storageKey) }
            if let raw { defaults.set(raw, forKey: GlobalPanelShortcut.storageKey) }
        }

        func persisted() throws -> GlobalPanelShortcut {
            try JSONDecoder().decode(GlobalPanelShortcut.self,
                from: XCTUnwrap(defaults.data(forKey: GlobalPanelShortcut.storageKey)))
        }

        func cleanup() { controller.shutdown(); defaults.removePersistentDomain(forName: suite) }
    }
}

/// 普通测试只使用此替身；不调用系统热键注册 API。
@MainActor
final class TestGlobalPanelShortcutBackend: GlobalPanelShortcutRegistering {
    enum Operation: Equatable { case register(UInt32), unregister(UInt32), shutdown }
    var onPress: ((UInt32) -> Void)?
    var registrationFailure: GlobalPanelShortcutFailure?
    var removalFailures: Set<UInt32> = []
    private(set) var operations: [Operation] = []
    private(set) var registered: [UInt32: GlobalPanelShortcut] = [:]

    func register(_ shortcut: GlobalPanelShortcut, id: UInt32) throws {
        operations.append(.register(id))
        if let registrationFailure { throw registrationFailure }
        registered[id] = shortcut
    }

    func unregister(id: UInt32) throws {
        operations.append(.unregister(id))
        if removalFailures.contains(id) { throw GlobalPanelShortcutFailure.removalFailed(-1) }
        registered.removeValue(forKey: id)
    }

    func press(_ id: UInt32) { onPress?(id) }
    func shutdown() { operations.append(.shutdown); registered.removeAll(); onPress = nil }
}
