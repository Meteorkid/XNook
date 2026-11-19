import Foundation
import Security
import IOKit
import CryptoKit

public protocol LicenseCredentialStore {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

public struct KeychainLicenseStore: LicenseCredentialStore {
    /// 钥匙串读取会经过 securityd 的解密与授权弹窗。系统提示框是串行排队的：
    /// 只要有一个模态授权窗口没人处理，这里的 `SecItemCopyMatching` 就会无限期
    /// 停在 mach_msg 上。若它发生在启动路径，应用连窗口都建不出来，表现为
    /// 「点了图标没有任何反应」。所以任何一次钥匙串调用都必须有上限。
    public static var callTimeout: TimeInterval = 3

    private static let queue = DispatchQueue(
        label: "com.meteorkid.license.keychain", qos: .userInitiated, attributes: .concurrent
    )

    private let service: String
    private let account: String

    public init(service: String, account: String = "session") {
        self.service = service
        self.account = account
    }

    /// 在独立队列上执行并在超时后放弃等待。超时的那次调用会继续挂着，
    /// 结果直接被丢弃；调用方按「暂时读不到」处理，稍后由恢复流程重试。
    private static func bounded<T>(_ timeout: TimeInterval, _ body: @escaping () -> T) -> T? {
        let box = ResultBox<T>()
        let group = DispatchGroup()
        group.enter()
        queue.async {
            box.store(body())
            group.leave()
        }
        guard group.wait(timeout: .now() + max(0.1, timeout)) == .success else { return nil }
        return box.value
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    public func load() throws -> Data? {
        try load(timeout: Self.callTimeout)
    }

    /// 迁移旧条目时值得给更长的上限：那一次读取决定用户已激活的授权能不能留下来。
    public func load(timeout: TimeInterval) throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let outcome: Result<Data?, Error>? = Self.bounded(timeout) {
            var result: CFTypeRef?
            let started = Date()
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return .success(nil) }
            if status == errSecSuccess, let data = result as? Data { return .success(data) }
            if Date().timeIntervalSince(started) > 1 {
                NSLog("[license] keychain read slow: status=%d after %.1fs", status, Date().timeIntervalSince(started))
            }
            return .failure(SoftwareLicenseError.storage(status))
        }
        guard let outcome else {
            NSLog("[license] keychain read timed out after %.1fs (授权弹窗未处理或钥匙串不可达)", timeout)
            throw SoftwareLicenseError.storage(errSecInteractionNotAllowed)
        }
        return try outcome.get()
    }

    public func save(_ data: Data) throws {
        let outcome: Result<Void, Error>? = Self.bounded(Self.callTimeout) {
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                let result = SecItemAdd(item as CFDictionary, nil)
                guard result == errSecSuccess else { return .failure(SoftwareLicenseError.storage(result)) }
            } else if status != errSecSuccess {
                return .failure(SoftwareLicenseError.storage(status))
            }
            return .success(())
        }
        guard let outcome else {
            NSLog("[license] keychain write timed out after %.1fs", Self.callTimeout)
            throw SoftwareLicenseError.storage(errSecInteractionNotAllowed)
        }
        try outcome.get()
    }

    public func delete() throws {
        let outcome: Result<Void, Error>? = Self.bounded(Self.callTimeout) {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                return .failure(SoftwareLicenseError.storage(status))
            }
            return .success(())
        }
        guard let outcome else {
            NSLog("[license] keychain delete timed out after %.1fs", Self.callTimeout)
            throw SoftwareLicenseError.storage(errSecInteractionNotAllowed)
        }
        try outcome.get()
    }
}

/// 跨队列传递钥匙串调用结果。
private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    func store(_ value: T) {
        lock.lock(); stored = value; lock.unlock()
    }

    var value: T? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

public enum LicenseDeviceIdentity {
    /// 只将硬件 UUID 的哈希发往服务端；硬件信息不可得时保存随机身份。
    public static func resolve(store: any LicenseCredentialStore, hardwareUUID: () -> String? = platformUUID) throws -> String {
        if let raw = hardwareUUID(), !raw.isEmpty { return hash(raw.lowercased()) }
        if let data = try store.load(), let raw = String(data: data, encoding: .utf8), !raw.isEmpty { return hash(raw) }
        let raw = UUID().uuidString.lowercased()
        try store.save(Data(raw.utf8))
        return hash(raw)
    }

    public static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
