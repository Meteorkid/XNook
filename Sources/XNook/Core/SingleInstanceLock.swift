import AppKit
import Darwin
import Foundation

/// 单实例锁 - 防止多个 XNook 实例同时运行
enum SingleInstanceLock {
    private static var lockFD: Int32 = -1

    /// 尝试获取单实例锁，失败则退出
    static func acquire(bundleURL: URL = Bundle.main.bundleURL) {
        guard let dir = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first else {
            print("[XNook] Unable to locate application support directory, skipping instance lock.")
            return
        }
        let lockPath = (dir as NSString).appendingPathComponent(lockFilename(for: bundleURL))

        // 确保目录存在
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let fd = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            // 另一个实例正在运行，退出
            close(fd)
            print("[XNook] Another instance is already running, exiting.")
            NSApp.terminate(nil)
            return
        }

        lockFD = fd
        // 锁会在进程退出时自动释放
    }

    static func lockFilename(for bundleURL: URL) -> String {
        if isDevelopmentBundle(bundleURL) {
            return "xnook_dev_instance.lock"
        }
        return "xnook_instance.lock"
    }

    static func isDevelopmentBundle(_ bundleURL: URL) -> Bool {
        bundleURL.standardizedFileURL.pathComponents.contains(".build")
    }
}
