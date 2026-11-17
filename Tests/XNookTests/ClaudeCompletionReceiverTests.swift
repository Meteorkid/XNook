import Darwin
import Foundation
import XCTest
@testable import XNook

@MainActor
final class ClaudeCompletionReceiverTests: XCTestCase {
    func testStartsDisabledWithoutCreatingAnyEndpoint() throws {
        let fixture = try ReceiverFixture()
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.receiver.state, .disabled)
        XCTAssertNil(fixture.receiver.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
        fixture.receiver.setEnabled(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    func testEnablingCreatesPrivateOwnedSocketAndDeliversCompletion() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.cleanup() }
        await fixture.start()
        var directory = stat()
        var endpoint = stat()
        XCTAssertEqual(lstat(fixture.directory.path, &directory), 0)
        XCTAssertEqual(lstat(fixture.socketURL.path, &endpoint), 0)
        XCTAssertEqual(directory.st_mode & 0o7777, 0o700)
        XCTAssertEqual(endpoint.st_mode & 0o7777, 0o600)
        XCTAssertEqual(endpoint.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(endpoint.st_uid, geteuid())
        try await fixture.send(fixture.payload())
        await fixture.waitUntil { fixture.events.count == 1 }
        XCTAssertEqual(fixture.events.first?.source, "claude-code")
        XCTAssertEqual(fixture.events.first?.kind, .completion)
        XCTAssertEqual(fixture.events.first?.action, PanelActivityEvent.Action.none)
    }

    func testDisablingDisconnectsClientsAndKeepsPrivateDirectory() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.cleanup() }
        await fixture.start()
        let client = try fixture.connect()
        defer { close(client) }
        fixture.receiver.setEnabled(false)
        XCTAssertEqual(fixture.receiver.state, .disabled)
        await fixture.waitUntil { !fixture.endpointExists && fixture.peerClosed(client) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.path))
        XCTAssertTrue(fixture.events.isEmpty)
    }

    func testRapidDisableAndRestartRejectsOldConnectionAndAcceptsNewGeneration() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.cleanup() }
        await fixture.start()
        let oldClient = try fixture.connect()
        defer { close(oldClient) }
        try fixture.write(fixture.payload(["id": "old"]), to: oldClient)
        fixture.receiver.setEnabled(false)
        fixture.receiver.setEnabled(true)
        await fixture.waitUntil { fixture.receiver.state == .listening }
        await fixture.waitUntil { fixture.peerClosed(oldClient) }
        try await fixture.send(fixture.payload(["id": "new"]))
        await fixture.waitUntil { fixture.events.count == 1 }
        XCTAssertEqual(fixture.events.map(\.id), ["new"])
    }

    func testShutdownRejectsQueuedCallbacksAndCannotBeReenabled() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.cleanup() }
        await fixture.start()
        let client = try fixture.connect()
        defer { close(client) }
        try fixture.write(fixture.payload(), to: client)
        Darwin.shutdown(client, SHUT_WR)
        // 当前主 actor 尚未让出执行权，已排队的投递也必须被代次检查丢弃。
        fixture.receiver.shutdown()
        fixture.receiver.setEnabled(true)
        await fixture.waitUntil { !fixture.endpointExists && fixture.peerClosed(client) }
        await fixture.settle()
        XCTAssertEqual(fixture.receiver.state, .disabled)
        XCTAssertTrue(fixture.events.isEmpty)
    }

    func testDuplicateEventsReachCoordinatorWhichOwnsDeduplication() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.cleanup() }
        let coordinator = PanelActivityCoordinator()
        defer { coordinator.shutdown() }
        fixture.forward = { _ = coordinator.enqueue($0) }
        await fixture.start()
        let payload = try fixture.payload()
        try await fixture.send(payload)
        try await fixture.send(payload)
        await fixture.waitUntil { fixture.events.count == 2 }
        XCTAssertEqual(coordinator.pendingCount, 1)
    }

    func testRejectsWrongSourceFailureExpiredUnknownFieldsAndMalformedPayloads() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.cleanup() }
        await fixture.start()
        let overrides: [[String: Any]] = [
            ["source": "local-agent"], ["result": "failure"],
            ["createdAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-120))],
            ["action": "openCalendar"], ["command": "touch /tmp/not-executed"], ["version": 2]
        ]
        for values in overrides { try await fixture.send(fixture.payload(values)) }
        for payload in [Data(), Data("not json".utf8), Data("{}".utf8)] {
            try await fixture.send(payload)
        }
        XCTAssertTrue(fixture.events.isEmpty)
        try await fixture.send(fixture.payload(["id": "valid-after-rejections"]))
        await fixture.waitUntil { fixture.events.count == 1 }
        XCTAssertEqual(fixture.events.first?.id, "valid-after-rejections")
    }

    func testAcceptsExactly64KiBAndRejectsOneAdditionalByte() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.cleanup() }
        await fixture.start()
        let payload = try fixture.payload()
        let limit = payload + Data(repeating: 0x20, count: 64 * 1_024 - payload.count)
        try await fixture.send(limit)
        await fixture.waitUntil { fixture.events.count == 1 }
        try await fixture.send(limit + Data([0x20]))
        XCTAssertEqual(fixture.events.count, 1)
    }

    func testExistingRegularFileAndSymlinkRemainUntouchedAndFailureCanRetry() async throws {
        for useSymlink in [false, true] {
            let fixture = try ReceiverFixture()
            defer { fixture.cleanup() }
            try fixture.makePrivateDirectory()
            let target = fixture.root.appendingPathComponent("keep.txt")
            try Data("keep".utf8).write(to: target)
            if useSymlink {
                try FileManager.default.createSymbolicLink(at: fixture.socketURL, withDestinationURL: target)
            } else {
                try Data("keep".utf8).write(to: fixture.socketURL)
            }
            fixture.receiver.setEnabled(true)
            await fixture.waitUntil { fixture.receiver.state == .failed }
            XCTAssertNotNil(fixture.receiver.lastError)
            XCTAssertEqual(try String(contentsOf: fixture.socketURL), "keep")
            XCTAssertEqual(try String(contentsOf: target), "keep")
            if useSymlink {
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.socketURL.path), target.path)
            }
            try FileManager.default.removeItem(at: fixture.socketURL)
            await fixture.start()
            XCTAssertNil(fixture.receiver.lastError)
        }
    }

    func testRejectsSharedPermissionsAndSymlinkedDirectoryWithoutChangingThem() async throws {
        for useSymlink in [false, true] {
            let fixture = try ReceiverFixture()
            defer { fixture.cleanup() }
            if useSymlink {
                let target = fixture.root.appendingPathComponent("real-directory")
                XCTAssertEqual(mkdir(target.path, 0o700), 0)
                try FileManager.default.createSymbolicLink(at: fixture.directory, withDestinationURL: target)
            } else {
                try fixture.makePrivateDirectory()
                XCTAssertEqual(chmod(fixture.directory.path, 0o755), 0)
            }
            fixture.receiver.setEnabled(true)
            await fixture.waitUntil { fixture.receiver.state == .failed }
            XCTAssertFalse(fixture.endpointExists)
            var info = stat()
            XCTAssertEqual(lstat(fixture.directory.path, &info), 0)
            XCTAssertEqual(info.st_mode & S_IFMT, useSymlink ? S_IFLNK : S_IFDIR)
            if !useSymlink { XCTAssertEqual(info.st_mode & 0o777, 0o755) }
        }
    }

    func testActiveEndpointIsNotReplacedByAnotherReceiver() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.cleanup() }
        await fixture.start()
        var before = stat()
        XCTAssertEqual(lstat(fixture.socketURL.path, &before), 0)
        let other = ClaudeCompletionReceiver(socketURL: fixture.socketURL) { _ in XCTFail("Second receiver must not listen") }
        defer { other.shutdown() }
        other.setEnabled(true)
        await fixture.waitUntil { other.state == .failed }
        var after = stat()
        XCTAssertEqual(lstat(fixture.socketURL.path, &after), 0)
        XCTAssertEqual(after.st_ino, before.st_ino)
        try await fixture.send(fixture.payload())
        await fixture.waitUntil { fixture.events.count == 1 }
    }

    func testReclaimsOnlySafeStaleSocket() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.cleanup() }
        try fixture.makePrivateDirectory()
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(stale, 0)
        XCTAssertEqual(fixture.withAddress { Darwin.bind(stale, $0, $1) }, 0)
        XCTAssertEqual(chmod(fixture.socketURL.path, 0o600), 0)
        close(stale)
        await fixture.start()
        try await fixture.send(fixture.payload())
        await fixture.waitUntil { fixture.events.count == 1 }
    }

    func testSlowConnectionsExpireAndFifthActiveClientIsRejected() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.cleanup() }
        await fixture.start()
        var clients: [Int32] = []
        defer { clients.forEach { close($0) } }
        for _ in 0..<4 {
            let descriptor = try fixture.connect()
            clients.append(descriptor)
            try fixture.write(Data("{".utf8), to: descriptor)
        }
        await fixture.settle()
        let overflow = try fixture.connect()
        defer { close(overflow) }
        await fixture.waitUntil(timeout: 0.5) { fixture.peerClosed(overflow) }
        await fixture.waitUntil(timeout: 1.5) { clients.allSatisfy { fixture.peerClosed($0) } }
        XCTAssertTrue(fixture.events.isEmpty)
        try await fixture.send(fixture.payload(["id": "after-timeouts"]))
        await fixture.waitUntil { fixture.events.count == 1 }
    }

    func testBlockedMainActorKeepsAtMostFivePendingDeliveriesAndReturnsBudget() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.cleanup() }
        await fixture.start()
        let socketURL = fixture.socketURL
        let payloads = try (0..<24).map { try fixture.payload(["id": "burst-\($0)"]) }
        let senderFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { senderFinished.signal() }
            do {
                // 无效末条充当 I/O 屏障，避免最后一次 EOF 早于其 onEvent 调用。
                try sendReceiverBurstSynchronously(payloads + [Data("{}".utf8)], to: socketURL)
            } catch {
                XCTFail("Background sender failed: \(error)")
            }
        }
        // 故意阻塞主 actor：每条 socket 消息已读完，但投递 Task 尚不能执行。
        XCTAssertEqual(senderFinished.wait(timeout: .now() + .seconds(5)), .success)
        XCTAssertTrue(fixture.events.isEmpty)
        await fixture.waitUntil { !fixture.events.isEmpty }
        await fixture.settle()
        XCTAssertLessThanOrEqual(fixture.events.count, 5, "Socket completion must not create an unbounded main-actor backlog")
        try await fixture.send(fixture.payload(["id": "after-burst"]))
        await fixture.waitUntil { fixture.events.contains { $0.id == "after-burst" } }
    }

    func testShutdownPreservesReplacementAtSocketPath() async throws {
        for replaceWithSocket in [false, true] {
            let fixture = try ReceiverFixture()
            defer { fixture.cleanup() }
            await fixture.start()
            let client = try fixture.connect()
            defer { close(client) }
            XCTAssertEqual(unlink(fixture.socketURL.path), 0)
            var replacement: Int32 = -1
            defer { if replacement >= 0 { close(replacement) } }
            if replaceWithSocket {
                replacement = socket(AF_UNIX, SOCK_STREAM, 0)
                XCTAssertGreaterThanOrEqual(replacement, 0)
                XCTAssertEqual(fixture.withAddress { Darwin.bind(replacement, $0, $1) }, 0)
                XCTAssertEqual(chmod(fixture.socketURL.path, 0o600), 0)
            } else {
                try Data("replacement".utf8).write(to: fixture.socketURL)
            }
            var before = stat()
            XCTAssertEqual(lstat(fixture.socketURL.path, &before), 0)
            fixture.receiver.shutdown()
            await fixture.waitUntil { fixture.peerClosed(client) }
            var after = stat()
            XCTAssertEqual(lstat(fixture.socketURL.path, &after), 0)
            XCTAssertEqual(after.st_ino, before.st_ino)
            if !replaceWithSocket { XCTAssertEqual(try String(contentsOf: fixture.socketURL), "replacement") }
        }
    }
}

/// 每次等待接收端关闭连接，确保突发消息已经经过 I/O 队列而非留在内核 backlog。
private func sendReceiverBurstSynchronously(_ payloads: [Data], to socketURL: URL) throws {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: socketURL.path.utf8) }
    for payload in payloads {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        var noSignal: Int32 = 1
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        try payload.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                offset += count
            }
        }
        Darwin.shutdown(descriptor, SHUT_WR)
        var byte: UInt8 = 0
        guard recv(descriptor, &byte, 1, 0) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

@MainActor
private final class ReceiverFixture {
    let root: URL
    let directory: URL
    let socketURL: URL
    var events: [PanelActivityEvent] = []
    var forward: ((PanelActivityEvent) -> Void)?
    lazy var receiver = ClaudeCompletionReceiver(socketURL: socketURL) { [weak self] event in
        self?.events.append(event)
        self?.forward?(event)
    }

    init() throws {
        // macOS 的 NSTemporaryDirectory 路径可能超过 sockaddr_un 的 104 字节上限。
        root = URL(fileURLWithPath: "/tmp/xnook-test-\(UUID().uuidString)")
        directory = root.appendingPathComponent("private")
        socketURL = directory.appendingPathComponent("claude.sock")
        guard mkdir(root.path, 0o700) == 0 else { throw posixError() }
    }

    var endpointExists: Bool {
        var info = stat()
        return lstat(socketURL.path, &info) == 0
    }

    func makePrivateDirectory() throws {
        guard mkdir(directory.path, 0o700) == 0 else { throw posixError() }
    }

    func start(file: StaticString = #filePath, line: UInt = #line) async {
        receiver.setEnabled(true)
        await waitUntil(file: file, line: line) { self.receiver.state != .starting }
        XCTAssertEqual(receiver.state, .listening, receiver.lastError ?? "", file: file, line: line)
    }

    func payload(_ overrides: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = [
            "version": 1, "source": "claude-code", "id": "turn-1",
            "title": "Claude Code 本轮响应已结束", "result": "success",
            "createdAt": ISO8601DateFormatter().string(from: Date())
        ]
        value.merge(overrides) { _, replacement in replacement }
        return try JSONSerialization.data(withJSONObject: value)
    }

    func connect() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError() }
        var noSignal: Int32 = 1
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        guard withAddress({ Darwin.connect(descriptor, $0, $1) }) == 0 else {
            let error = posixError()
            close(descriptor)
            throw error
        }
        return descriptor
    }

    func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.send(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                guard written > 0 else { throw posixError() }
                offset += written
            }
        }
    }

    func send(_ payload: Data) async throws {
        let descriptor = try connect()
        defer { close(descriptor) }
        try write(payload, to: descriptor)
        Darwin.shutdown(descriptor, SHUT_WR)
        await waitUntil { self.peerClosed(descriptor) }
        // EOF 是 I/O 完成点；让主 actor 消费随后的投递。
        await settle()
    }

    func peerClosed(_ descriptor: Int32) -> Bool {
        var byte: UInt8 = 0
        let count = recv(descriptor, &byte, 1, MSG_DONTWAIT)
        return count == 0 || (count < 0 && errno == ECONNRESET)
    }

    func withAddress<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: socketURL.path.utf8) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    func waitUntil(timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line,
                   _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Timed out waiting for local receiver", file: file, line: line)
    }

    func settle() async { try? await Task.sleep(for: .milliseconds(50)) }

    func cleanup() {
        receiver.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
