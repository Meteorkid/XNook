import AppKit
import Darwin
import Foundation

/// 单实例锁 - 防止多个 XNook 实例同时运行
enum SingleInstanceLock {
    private static var lockFDs: [Int32] = []

    /// 尝试获取单实例锁，失败则退出
    @discardableResult
    static func acquire(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        if !lockFDs.isEmpty { return true }
        guard let dir = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first else {
            print("[XNook] Unable to locate the shared data lock; startup stopped.")
            NSApp.terminate(nil)
            return false
        }
        do {
            if let descriptors = try acquireFiles(in: URL(fileURLWithPath: dir), bundleURL: bundleURL) {
                lockFDs = descriptors
                return true
            }
            print("[XNook] Another instance owns the shared data; startup stopped.")
        } catch {
            print("[XNook] Unable to acquire the shared data lock; startup stopped.")
        }
        NSApp.terminate(nil)
        return false
    }

    static func lockFilename(for bundleURL: URL) -> String {
        // 开发包和安装包共用业务数据，不能仅凭 bundle 位置划分写入锁。
        return "xnook_instance.lock"
    }

    static func acquireFiles(in directory: URL, bundleURL: URL) throws -> [Int32]? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 也占用旧开发锁，防止与尚未升级的开发实例同时写同一份数据。
        let names = [lockFilename(for: bundleURL), "xnook_dev_instance.lock"]
        var descriptors: [Int32] = []
        var completed = false
        defer { if !completed { descriptors.forEach { close($0) } } }
        for name in names {
            let descriptor = open(directory.appendingPathComponent(name).path,
                                  O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            descriptors.append(descriptor)
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let failure = errno
                if failure == EWOULDBLOCK || failure == EAGAIN { return nil }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
            }
        }
        completed = true
        return descriptors
    }

    static func isDevelopmentBundle(_ bundleURL: URL) -> Bool {
        bundleURL.standardizedFileURL.pathComponents.contains(".build")
    }
}
