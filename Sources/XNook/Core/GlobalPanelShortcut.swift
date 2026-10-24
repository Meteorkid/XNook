import AppKit
import Carbon
import Observation

struct GlobalPanelShortcut: Codable, Equatable {
    let version: Int
    let keyCode: UInt32
    let modifiers: UInt32
    let displayKey: String

    init(keyCode: UInt32, modifiers: UInt32, displayKey: String) {
        version = 1
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.displayKey = displayKey
    }

    static let storageKey = "globalPanelShortcut.v1"
    static let maximumStoredBytes = 1_024
    static let allowedModifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)
    private static let namedKeys: [UInt32: String] = [
        49: "Space", 64: "F17", 79: "F18", 80: "F19", 90: "F20", 96: "F5",
        97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12",
        113: "F15", 118: "F4", 120: "F2", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    var isValid: Bool {
        let printableKey = keyCode <= 50 && keyCode != 36 && keyCode != 48
        let visibleLabel = !displayKey.isEmpty && displayKey.count <= 12
            && displayKey.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        return version == 1 && (printableKey || Self.namedKeys[keyCode] != nil)
            && modifiers & ~Self.allowedModifiers == 0
            && modifiers & UInt32(cmdKey | controlKey) != 0 && visibleLabel
    }

    var displayTitle: String {
        [(UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"), (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined() + displayKey
    }

    static func captured(from event: NSEvent) -> Self? {
        guard event.type == .keyDown, !event.isARepeat else { return nil }
        var modifiers: UInt32 = 0
        for (flag, carbon) in [(NSEvent.ModifierFlags.command, UInt32(cmdKey)), (.control, UInt32(controlKey)),
                               (.option, UInt32(optionKey)), (.shift, UInt32(shiftKey))] {
            if event.modifierFlags.contains(flag) { modifiers |= carbon }
        }
        let code = UInt32(event.keyCode)
        let label = namedKeys[code] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        let value = Self(keyCode: code, modifiers: modifiers, displayKey: label)
        return value.isValid ? value : nil
    }
}

enum GlobalPanelShortcutFailure: Error, Equatable {
    case invalidShortcut, invalidStoredShortcut, inactive, systemConflict, conflict
    case registrationFailed(Int32), removalFailed(Int32), rollbackFailed
}

@MainActor
protocol GlobalPanelShortcutRegistering: AnyObject {
    var onPress: ((UInt32) -> Void)? { get set }
    func register(_ shortcut: GlobalPanelShortcut, id: UInt32) throws
    func unregister(id: UInt32) throws
    func shutdown()
}

@Observable @MainActor
final class GlobalPanelShortcutController {
    private(set) var configuredShortcut: GlobalPanelShortcut?
    private(set) var activeShortcut: GlobalPanelShortcut?
    private(set) var failure: GlobalPanelShortcutFailure?
    private(set) var hasStoredShortcut = false
    private(set) var isRecording = false
    private(set) var isActivated = false
    var canClear: Bool { hasStoredShortcut || activeShortcut != nil }
    private let defaults: UserDefaults
    private let backend: any GlobalPanelShortcutRegistering
    private let onInvoke: @MainActor () -> Void
    private var activeID: UInt32?
    private var nextID: UInt32 = 1
    private var pendingCleanup: Set<UInt32> = []
    private var isShutdown = false

    init(defaults: UserDefaults = .standard, backend: (any GlobalPanelShortcutRegistering)? = nil,
         onInvoke: @escaping @MainActor () -> Void = {}) {
        self.defaults = defaults
        self.backend = backend ?? CarbonGlobalPanelShortcutBackend()
        self.onInvoke = onInvoke
        // 构造只读配置；获得单实例所有权后才允许 activate 注册。
        hasStoredShortcut = defaults.object(forKey: GlobalPanelShortcut.storageKey) != nil
        if hasStoredShortcut {
            if let data = defaults.data(forKey: GlobalPanelShortcut.storageKey),
               data.count <= GlobalPanelShortcut.maximumStoredBytes,
               let value = try? JSONDecoder().decode(GlobalPanelShortcut.self, from: data), value.isValid {
                configuredShortcut = value
            } else {
                failure = .invalidStoredShortcut
            }
        }
        self.backend.onPress = { [weak self] id in self?.receive(id: id) }
    }

    func activate() {
        guard !isActivated, !isShutdown else { return }
        isActivated = true
        if let configuredShortcut { _ = replace(with: configuredShortcut, persist: false) }
    }

    @discardableResult
    func apply(_ shortcut: GlobalPanelShortcut) -> Bool { replace(with: shortcut, persist: true) }

    @discardableResult
    func clear() -> Bool {
        guard isActivated, !isShutdown else { failure = .inactive; return false }
        guard cleanUpPending() else { return false }
        if let activeID {
            do { try backend.unregister(id: activeID) }
            catch { failure = removalFailure(error); return false }
        }
        activeID = nil
        activeShortcut = nil
        configuredShortcut = nil
        failure = nil
        isRecording = false
        defaults.removeObject(forKey: GlobalPanelShortcut.storageKey)
        hasStoredShortcut = false
        return true
    }

    func beginRecording() {
        guard isActivated, !isShutdown else { failure = .inactive; return }
        isRecording = true
    }

    func endRecording() { isRecording = false }
    func rejectRecordedInput() { failure = .invalidShortcut }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        isActivated = false
        isRecording = false
        backend.onPress = nil
        backend.shutdown()
        activeID = nil
        activeShortcut = nil
        pendingCleanup.removeAll()
    }

    private func replace(with shortcut: GlobalPanelShortcut, persist: Bool) -> Bool {
        guard isActivated, !isShutdown else { failure = .inactive; return false }
        guard shortcut.isValid, let data = try? JSONEncoder().encode(shortcut),
              data.count <= GlobalPanelShortcut.maximumStoredBytes else {
            failure = .invalidShortcut
            return false
        }
        guard cleanUpPending() else { return false }
        if activeShortcut == shortcut { failure = nil; isRecording = false; return true }
        let candidateID = nextID
        nextID = nextID == UInt32.max ? 1 : nextID + 1
        do { try backend.register(shortcut, id: candidateID) }
        catch { failure = (error as? GlobalPanelShortcutFailure) ?? .registrationFailed(-1); return false }
        if let activeID {
            do { try backend.unregister(id: activeID) }
            catch {
                let oldRemovalFailure = removalFailure(error)
                do { try backend.unregister(id: candidateID); failure = oldRemovalFailure }
                catch { pendingCleanup.insert(candidateID); failure = .rollbackFailed }
                return false
            }
        }
        activeID = candidateID
        activeShortcut = shortcut
        configuredShortcut = shortcut
        failure = nil
        isRecording = false
        if persist {
            defaults.set(data, forKey: GlobalPanelShortcut.storageKey)
            hasStoredShortcut = true
        }
        return true
    }

    private func cleanUpPending() -> Bool {
        for id in pendingCleanup.sorted() {
            do { try backend.unregister(id: id); pendingCleanup.remove(id) }
            catch { failure = .rollbackFailed; return false }
        }
        return true
    }

    private func removalFailure(_ error: Error) -> GlobalPanelShortcutFailure {
        (error as? GlobalPanelShortcutFailure) ?? .removalFailed(-1)
    }

    private func receive(id: UInt32) {
        guard isActivated, !isShutdown, activeID == id else { return }
        // 当前组合在录制时可能仍由 Carbon 接收；保留它并结束录制，不能抢走设置焦点。
        if isRecording { isRecording = false; failure = nil; return }
        onInvoke()
    }
}

@MainActor
private final class GlobalPanelShortcutEventContext {
    let receive: @MainActor (UInt32) -> Void
    init(receive: @escaping @MainActor (UInt32) -> Void) { self.receive = receive }
}

@MainActor
final class CarbonGlobalPanelShortcutBackend: GlobalPanelShortcutRegistering {
    var onPress: ((UInt32) -> Void)?
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var eventContext: GlobalPanelShortcutEventContext?
    private static let signature: UInt32 = 0x584E504C // XNPL

    func register(_ shortcut: GlobalPanelShortcut, id: UInt32) throws {
        guard shortcut.isValid else { throw GlobalPanelShortcutFailure.invalidShortcut }
        if try isSystemShortcut(shortcut) { throw GlobalPanelShortcutFailure.systemConflict }
        try installHandlerIfNeeded()
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
            EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else {
            if status == eventHotKeyExistsErr { throw GlobalPanelShortcutFailure.conflict }
            throw GlobalPanelShortcutFailure.registrationFailed(status)
        }
        references[id] = reference
    }

    func unregister(id: UInt32) throws {
        guard let reference = references[id] else { return }
        let status = UnregisterEventHotKey(reference)
        guard status == noErr else { throw GlobalPanelShortcutFailure.removalFailed(status) }
        references.removeValue(forKey: id)
    }

    func shutdown() {
        onPress = nil
        for (id, reference) in references where UnregisterEventHotKey(reference) == noErr {
            references.removeValue(forKey: id)
        }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        eventContext = nil
    }

    private func isSystemShortcut(_ shortcut: GlobalPanelShortcut) throws -> Bool {
        var copied: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&copied)
        guard status == noErr, let copied else { throw GlobalPanelShortcutFailure.registrationFailed(status) }
        let entries = copied.takeRetainedValue() as NSArray
        return entries.contains { value in
            guard let entry = value as? [String: Any],
                  let enabled = entry[kHISymbolicHotKeyEnabled as String] as? NSNumber,
                  let code = entry[kHISymbolicHotKeyCode as String] as? NSNumber,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? NSNumber else { return false }
            return enabled.boolValue && code.uint32Value == shortcut.keyCode
                && modifiers.uint32Value & GlobalPanelShortcut.allowedModifiers == shortcut.modifiers
        }
    }

    private func installHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }
        let context = GlobalPanelShortcutEventContext { [weak self] id in self?.onPress?(id) }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var handler: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == 0x584E504C else { return OSStatus(eventNotHandledErr) }
            let context = Unmanaged<GlobalPanelShortcutEventContext>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { context.receive(identifier.id) }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(context).toOpaque(), &handler)
        guard status == noErr, let handler else { throw GlobalPanelShortcutFailure.registrationFailed(status) }
        eventContext = context
        eventHandler = handler
    }

    deinit {
        let referenceAddresses = references.values.map { UInt(bitPattern: $0) }
        let handlerAddress = eventHandler.map { UInt(bitPattern: $0) }
        let context = eventContext
        // 析构把独占句柄的清理权交给主线程，只跨队列传递地址值；上下文存活到 handler 移除。
        DispatchQueue.main.async {
            for address in referenceAddresses {
                if let reference = EventHotKeyRef(bitPattern: address) { UnregisterEventHotKey(reference) }
            }
            if let handlerAddress, let handler = EventHandlerRef(bitPattern: handlerAddress) { RemoveEventHandler(handler) }
            withExtendedLifetime(context) {}
        }
    }
}
