import Foundation

/// 以文件保存授权记录的默认实现。
///
/// 为什么不用登录钥匙串：这份记录里存的是**已签名**的租约（真伪由内置 Ed25519
/// 公钥校验，本地改不动）与一枚设备令牌。钥匙串在这里唯一多出来的作用是 ACL
/// 授权框——而它在应用重新签名后会对不上旧条目，于是每次启动都弹「输入登录钥匙串
/// 密码」，读取被阻塞还会连带把启动流程卡死。用 0600 权限的文件没有任何收益损失：
/// 同用户的进程本来就能读到应用自己的数据目录，而租约的完整性不依赖保密。
public struct FileLicenseStore: LicenseCredentialStore {
    private let url: URL

    public init(directory: URL? = nil, name: String) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XNook", isDirectory: true)
        self.url = base
            .appendingPathComponent("License", isDirectory: true)
            .appendingPathComponent("\(name).json", isDirectory: false)
    }

    public var fileURL: URL { url }

    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            // 文件读不出来（权限损坏、被替换成目录等）按「没有凭据」处理，
            // 让上层走联网校验，而不是把应用锁在错误页。
            NSLog("[license] file store read failed at %@: %@", url.path, String(describing: error))
            return nil
        }
    }

    public func save(_ data: Data) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw SoftwareLicenseError.storage(-1)
        }
    }

    public func delete() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw SoftwareLicenseError.storage(-1)
        }
    }
}
