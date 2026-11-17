import Darwin
import Foundation
import Observation

/// 本地 hook 只投递数据；展示、去重和动作仍由活动协调器负责。
@Observable @MainActor
final class ClaudeCompletionReceiver {
    enum State: Equatable { case disabled, starting, listening, failed }

    nonisolated static let defaultSocketURL = URL(fileURLWithPath: "/tmp/xnook-activity-\(geteuid())/claude.sock")

    private(set) var state: State = .disabled
    private(set) var lastError: String?
    @ObservationIgnored private let server: ClaudeCompletionSocketServer
    @ObservationIgnored private let deliver: @MainActor (PanelActivityEvent) -> Void
    private var generation: UInt64 = 0
    private var isShutdown = false

    init(socketURL: URL = defaultSocketURL, deliver: @escaping @MainActor (PanelActivityEvent) -> Void) {
        server = ClaudeCompletionSocketServer(socketURL: socketURL)
        self.deliver = deliver
    }

    func setEnabled(_ enabled: Bool) {
        guard !isShutdown else { return }
        if enabled, state == .starting || state == .listening { return }
        generation &+= 1
        let expectedGeneration = generation
        lastError = nil
        guard enabled else {
            state = .disabled
            server.stop()
            return
        }
        state = .starting
        server.start(onReady: { [weak self] error in
            Task { @MainActor in
                guard let self, self.generation == expectedGeneration, !self.isShutdown else { return }
                self.lastError = error
                self.state = error == nil ? .listening : .failed
            }
        }, onEvent: { [weak self] event, acknowledge in
            Task { @MainActor in
                defer { acknowledge() }
                guard let self, self.generation == expectedGeneration,
                      !self.isShutdown, self.state == .starting || self.state == .listening else { return }
                self.deliver(event)
            }
        })
    }

    func shutdown() {
        setEnabled(false)
        isShutdown = true
    }

    deinit { server.stop() }
}

/// 所有描述符和取消回调均在同一队列运行，取消后由 source 唯一负责 close。
private final class ClaudeCompletionSocketServer: @unchecked Sendable {
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t

        init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
    }

    private final class Client {
        let descriptor: Int32
        let source: DispatchSourceRead
        let timer: DispatchSourceTimer
        let deadline = DispatchTime.now() + .seconds(1)
        var data = Data()

        init(descriptor: Int32, queue: DispatchQueue) {
            self.descriptor = descriptor
            source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            timer = DispatchSource.makeTimerSource(queue: queue)
        }
    }

    private enum Failure: String, Error {
        case unsafeDirectory = "The local activity directory is not private or safe."
        case unsafeEndpoint = "The local activity endpoint is not a safe socket."
        case endpointInUse = "The local activity endpoint is already in use."
        case socketUnavailable = "The local activity socket could not be opened."
    }

    private let socketURL: URL
    private let queue = DispatchQueue(label: "com.xnook.claude-completion", qos: .utility)
    private var listener: DispatchSourceRead?
    private var directoryDescriptor: Int32 = -1
    private var socketIdentity: Identity?
    private var clients: [Int32: Client] = [:]
    private var generation: UInt64 = 0
    private var onEvent: ((PanelActivityEvent, @escaping () -> Void) -> Void)?
    private var pendingDeliveries = 0
    private static let maximumPayloadSize = 64 * 1_024

    init(socketURL: URL) { self.socketURL = socketURL }

    func start(onReady: @escaping (String?) -> Void,
               onEvent: @escaping (PanelActivityEvent, @escaping () -> Void) -> Void) {
        queue.async { [self] in
            stopOnQueue()
            var directory: Int32 = -1
            var descriptor: Int32 = -1
            var identity: Identity?
            do {
                var address = try socketAddress()
                directory = try openPrivateDirectory()
                try removeStaleEndpoint(in: directory, address: &address)
                descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
                guard descriptor >= 0, configure(descriptor) else { throw Failure.socketUnavailable }
                guard withAddress(&address, { Darwin.bind(descriptor, $0, $1) }) == 0 else {
                    throw Failure.endpointInUse
                }
                var info = stat()
                guard fstatat(directory, socketURL.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      isOwned(info, type: S_IFSOCK) else { throw Failure.unsafeEndpoint }
                identity = Identity(info)
                guard fchmodat(directory, socketURL.lastPathComponent, 0o600, AT_SYMLINK_NOFOLLOW) == 0,
                      fstatat(directory, socketURL.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      Identity(info) == identity, isOwned(info, type: S_IFSOCK, mode: 0o600),
                      directoryStillMatches(directory), listen(descriptor, 4) == 0 else {
                    throw Failure.socketUnavailable
                }
                let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
                let listenerDescriptor = descriptor
                let expectedGeneration = generation
                source.setEventHandler { [weak self] in
                    guard let self, self.generation == expectedGeneration else { return }
                    self.acceptClients(listenerDescriptor)
                }
                source.setCancelHandler { close(listenerDescriptor) }
                listener = source
                directoryDescriptor = directory
                socketIdentity = identity
                self.onEvent = onEvent
                source.resume()
                onReady(nil)
            } catch {
                if descriptor >= 0 { close(descriptor) }
                removeEndpoint(in: directory, matching: identity)
                if directory >= 0 { close(directory) }
                onReady((error as? Failure)?.rawValue ?? Failure.socketUnavailable.rawValue)
            }
        }
    }

    func stop() { queue.async { [self] in stopOnQueue() } }

    private func stopOnQueue() {
        generation &+= 1
        onEvent = nil
        pendingDeliveries = 0
        listener?.cancel()
        listener = nil
        for client in Array(clients.values) { finish(client) }
        removeEndpoint(in: directoryDescriptor, matching: socketIdentity)
        if directoryDescriptor >= 0 { close(directoryDescriptor) }
        directoryDescriptor = -1
        socketIdentity = nil
    }

    private func acceptClients(_ descriptor: Int32) {
        // 连接洪峰不能饿死 stop、已接入客户端或超时回调。
        for _ in 0..<8 {
            let accepted = accept(descriptor, nil, nil)
            guard accepted >= 0 else { return }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard clients.count < 4, getpeereid(accepted, &uid, &gid) == 0,
                  uid == geteuid(), configure(accepted) else {
                close(accepted)
                continue
            }
            let client = Client(descriptor: accepted, queue: queue)
            clients[accepted] = client
            client.source.setEventHandler { [weak self, weak client] in
                guard let self, let client else { return }
                self.read(client)
            }
            client.source.setCancelHandler { close(accepted) }
            client.timer.schedule(deadline: client.deadline, leeway: .nanoseconds(0))
            client.timer.setEventHandler { [weak self, weak client] in
                guard let self, let client else { return }
                self.finish(client)
            }
            client.source.resume()
            client.timer.resume()
        }
    }

    private func read(_ client: Client) {
        guard clients[client.descriptor] === client else { return }
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        for _ in 0..<8 {
            guard DispatchTime.now() < client.deadline else { finish(client); return }
            let count = recv(client.descriptor, &buffer, buffer.count, 0)
            if count > 0 {
                guard client.data.count + count <= Self.maximumPayloadSize else { finish(client); return }
                client.data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                let event = try? PanelActivityEnvelope.decode(client.data, allowedSources: ["claude-code"], now: Date())
                finish(client)
                if let event, event.kind == .completion { queueDelivery(event) }
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else if errno != EINTR {
                finish(client)
                return
            }
        }
    }

    private func queueDelivery(_ event: PanelActivityEvent) {
        guard pendingDeliveries < 5, let onEvent else { return }
        pendingDeliveries += 1
        let expectedGeneration = generation
        onEvent(event) { [weak self] in
            guard let self else { return }
            self.queue.async { [self] in
                // 旧 Task 的完成通知不能归还新一轮监听的投递预算。
                guard self.generation == expectedGeneration else { return }
                self.pendingDeliveries -= 1
            }
        }
    }

    private func finish(_ client: Client) {
        guard clients[client.descriptor] === client else { return }
        clients.removeValue(forKey: client.descriptor)
        // shutdown 先让对端读写结束；close 留给取消处理器，防止 fd 复用。
        Darwin.shutdown(client.descriptor, SHUT_RDWR)
        client.timer.cancel()
        client.source.cancel()
    }

    private func openPrivateDirectory() throws -> Int32 {
        let path = socketURL.deletingLastPathComponent().path
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT, mkdir(path, 0o700) == 0 || errno == EEXIST else {
                throw Failure.unsafeDirectory
            }
        }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unsafeDirectory }
        guard fstat(descriptor, &info) == 0, isOwned(info, type: S_IFDIR, mode: 0o700),
              directoryStillMatches(descriptor) else {
            close(descriptor)
            throw Failure.unsafeDirectory
        }
        return descriptor
    }

    private func directoryStillMatches(_ descriptor: Int32) -> Bool {
        var opened = stat()
        var current = stat()
        return fstat(descriptor, &opened) == 0
            && lstat(socketURL.deletingLastPathComponent().path, &current) == 0
            && Identity(opened) == Identity(current)
            && isOwned(current, type: S_IFDIR, mode: 0o700)
    }

    private func removeStaleEndpoint(in directory: Int32, address: inout sockaddr_un) throws {
        var info = stat()
        if fstatat(directory, socketURL.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw Failure.unsafeEndpoint }
            return
        }
        guard isOwned(info, type: S_IFSOCK, mode: 0o600) else { throw Failure.unsafeEndpoint }
        let identity = Identity(info)
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw Failure.socketUnavailable }
        defer { close(probe) }
        guard configure(probe) else { throw Failure.socketUnavailable }
        let result = withAddress(&address) { connect(probe, $0, $1) }
        let failure = errno
        guard result != 0, failure == ECONNREFUSED else { throw Failure.endpointInUse }
        guard directoryStillMatches(directory),
              fstatat(directory, socketURL.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0,
              Identity(info) == identity, isOwned(info, type: S_IFSOCK, mode: 0o600),
              unlinkat(directory, socketURL.lastPathComponent, 0) == 0 else { throw Failure.unsafeEndpoint }
    }

    private func removeEndpoint(in directory: Int32, matching identity: Identity?) {
        guard directory >= 0, let identity else { return }
        var info = stat()
        guard fstatat(directory, socketURL.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0,
              Identity(info) == identity, isOwned(info, type: S_IFSOCK) else { return }
        unlinkat(directory, socketURL.lastPathComponent, 0)
    }

    private func isOwned(_ info: stat, type: mode_t, mode: mode_t? = nil) -> Bool {
        info.st_uid == geteuid() && info.st_mode & S_IFMT == type
            && (mode == nil || info.st_mode & 0o7777 == mode)
    }

    private func configure(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
            && fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0
    }

    private func socketAddress() throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(socketURL.path.utf8)
        guard socketURL.isFileURL, !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw Failure.socketUnavailable
        }
        withUnsafeMutableBytes(of: &address.sun_path) { storage in
            storage.copyBytes(from: bytes)
        }
        return address
    }

    private func withAddress<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}
