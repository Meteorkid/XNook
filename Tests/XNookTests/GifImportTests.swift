import XCTest
import CryptoKit
@testable import XNook

final class GifImportTests: XCTestCase {
    func testImportCreatesDirectoryAndPreservesValidatedBytes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = makeBudgetGIF()
        try original.write(to: fixture.source)
        let name = try GifResource.importFile(from: fixture.source, to: fixture.destination, existingNames: [])
        XCTAssertEqual(name, "input.gif")
        XCTAssertEqual(try Data(contentsOf: fixture.destination.appendingPathComponent(name)), original)
    }

    func testWriterReceivesValidatedBytesEvenIfSourceChanges() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = makeBudgetGIF()
        try original.write(to: fixture.source)
        let name = try GifResource.importFile(from: fixture.source, to: fixture.destination, existingNames: [], write: { data, destination in
            try Data("source changed after validation".utf8).write(to: fixture.source)
            XCTAssertEqual(data, original)
            try data.write(to: destination, options: .atomic)
        })
        XCTAssertEqual(try Data(contentsOf: fixture.destination.appendingPathComponent(name)), original)
    }

    func testImportAvoidsBothListedAndOnDiskNames() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try makeBudgetGIF().write(to: fixture.source)
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
        let occupied = fixture.destination.appendingPathComponent("input_1.gif")
        let untouched = Data("unlisted existing file".utf8)
        try untouched.write(to: occupied)
        let name = try GifResource.importFile(from: fixture.source, to: fixture.destination, existingNames: ["input.gif"])
        XCTAssertEqual(name, "input_2.gif")
        XCTAssertEqual(try Data(contentsOf: occupied), untouched)
        XCTAssertEqual(try Data(contentsOf: fixture.destination.appendingPathComponent(name)), makeBudgetGIF())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("input.gif").path))
    }

    func testInvalidAndOverLimitInputNeverCreateDestination() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        for data in [Data("invalid".utf8), Data(count: GifResource.maximumEncodedBytes + 1)] {
            try data.write(to: fixture.source)
            XCTAssertThrowsError(try GifResource.importFile(from: fixture.source, to: fixture.destination, existingNames: [], write: { _, _ in
                XCTFail("Rejected data must never reach the writer")
            }))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        }
    }

    func testWriteFailureDoesNotReturnSuccess() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try makeBudgetGIF().write(to: fixture.source)
        var successfulName: String?
        XCTAssertThrowsError(successfulName = try GifResource.importFile(from: fixture.source, to: fixture.destination, existingNames: [], write: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission)
        }
        XCTAssertNil(successfulName)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
    }

    func testSecurityScopeIsBalancedOnSuccessValidationFailureAndWriteFailure() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        for scenario in 0..<3 {
            try (scenario == 1 ? Data("invalid".utf8) : makeBudgetGIF()).write(to: fixture.source)
            var accessEvents: [String] = []
            let operation = {
                try GifResource.importFile(from: fixture.source, to: fixture.destination, existingNames: [],
                    startAccessing: { url in
                        XCTAssertEqual(url, fixture.source)
                        accessEvents.append("start")
                        return true
                    }, stopAccessing: { url in
                        XCTAssertEqual(url, fixture.source)
                        accessEvents.append("stop")
                    }, write: { data, url in
                        XCTAssertEqual(accessEvents, ["start"])
                        if scenario == 2 { throw CocoaError(.fileWriteNoPermission) }
                        try data.write(to: url, options: .atomic)
                    })
            }
            if scenario == 0 { XCTAssertEqual(try operation(), "input.gif") }
            else { XCTAssertThrowsError(try operation()) }
            XCTAssertEqual(accessEvents, ["start", "stop"])
        }
    }

    func testReadableUnscopedFileDoesNotStopAnUnopenedScope() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try makeBudgetGIF().write(to: fixture.source)
        let name = try GifResource.importFile(from: fixture.source, to: fixture.destination, existingNames: [],
            startAccessing: { _ in false }, stopAccessing: { _ in XCTFail("No scope was opened") })
        XCTAssertEqual(name, "input.gif")
    }

    @MainActor
    func testBlockedBackgroundWriterLeavesMainActorAvailableAndCancellationKeepsResult() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try makeBudgetGIF().write(to: fixture.source)
        let writerStarted = expectation(description: "Background writer reached the latch")
        let mainActorProbe = expectation(description: "Main actor runs before writer is released")
        let releaseWriter = DispatchSemaphore(value: 0)
        defer { releaseWriter.signal() }
        var registeredNames: [String] = []
        let importing = Task { @MainActor in
            let name = try await GifResource.performFileIO {
                try GifResource.importFile(from: fixture.source, to: fixture.destination, existingNames: [], write: { data, url in
                    XCTAssertFalse(Thread.isMainThread)
                    writerStarted.fulfill()
                    guard releaseWriter.wait(timeout: .now() + 5) == .success else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try data.write(to: url, options: .atomic)
                })
            }
            registeredNames.append(name)
            return name
        }
        await fulfillment(of: [writerStarted], timeout: 2)
        Task { @MainActor in mainActorProbe.fulfill() }
        await fulfillment(of: [mainActorProbe], timeout: 1)
        XCTAssertTrue(registeredNames.isEmpty)
        importing.cancel()
        releaseWriter.signal()
        let name = try await importing.value
        XCTAssertEqual(registeredNames, [name])
        XCTAssertEqual(try Data(contentsOf: fixture.destination.appendingPathComponent(name)), makeBudgetGIF())
    }

    private struct Fixture {
        let directory: URL
        var source: URL { directory.appendingPathComponent("input.gif") }
        var destination: URL { directory.appendingPathComponent("nested/gifs") }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("GifImport-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func cleanUp() {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Could not clean GIF import fixture: \(error)") }
        }
    }
}

/// warm-cache 对照只记录数据；机器速度不影响普通测试是否通过。
@MainActor
final class GifImportPerformanceTests: XCTestCase {
    func testTenMiBWarmCacheImportOldAndNewPaths() async throws {
        guard ProcessInfo.processInfo.environment["XNOOK_PERFORMANCE"] == "1",
              let outputPath = ProcessInfo.processInfo.environment["XNOOK_PERFORMANCE_OUTPUT"] else {
            throw XCTSkip("Set XNOOK_PERFORMANCE=1 and XNOOK_PERFORMANCE_OUTPUT to record GIF import timings.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GifImportPerformance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Could not clean GIF performance fixture: \(error)") }
        }
        let source = directory.appendingPathComponent("input.gif")
        var input = makeBudgetGIF()
        input.append(Data(count: GifResource.maximumEncodedBytes - input.count))
        try input.write(to: source)
        XCTAssertEqual(input.count, 10 * 1_024 * 1_024)
        let suite = "XNook.GifImportPerformance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var rounds: [[String: Any]] = []
        for round in 0..<3 {
            // 交替先后顺序；每种路径预热两次，每个样本均使用同一输入与空目标目录。
            for backgroundWrite in round.isMultiple(of: 2) ? [false, true] : [true, false] {
                var totalSamples: [Double] = []
                var mainSamples: [Double] = []
                for sample in -2..<20 {
                    _ = try GifResource(contentsOf: source).data
                    defaults.removeObject(forKey: "customGifList")
                    defaults.removeObject(forKey: "selectedGifName")
                    let destination = directory.appendingPathComponent("\(round)-\(backgroundWrite)-\(sample)")
                    let timing = try await measureImport(from: source, to: destination, backgroundWrite: backgroundWrite, defaults: defaults)
                    XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("input.gif")), input)
                    XCTAssertEqual(defaults.stringArray(forKey: "customGifList"), ["input.gif"])
                    if sample >= 0 {
                        totalSamples.append(timing.totalMs)
                        mainSamples.append(timing.mainThreadMs)
                    }
                    try FileManager.default.removeItem(at: destination)
                }
                rounds.append([
                    "round": round + 1, "path": backgroundWrite ? "all-io-background" : "read-background-write-main",
                    "sampleCount": totalSamples.count, "totalElapsed": statistics(totalSamples),
                    "mainThreadOccupied": statistics(mainSamples)
                ])
            }
        }
        let result: [String: Any] = [
            "scenario": "gif-import-10MiB-warm-cache", "inputBytes": input.count,
            "inputSHA256": SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined(),
            "cachePolicy": "same source read immediately before each sample; two excluded warmups per path per round; no cache flush",
            "mainThreadMetric": "wall time in synchronous MainActor spans; excludes suspended await time; includes isolated metadata commit",
            "oldBoundary": "background scoped read and validation; main-thread mkdir, collision checks, atomic write, metadata commit",
            "newBoundary": "background scoped read, validation, mkdir, collision checks, atomic write; main-thread metadata commit",
            "rounds": rounds
        ]
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("gif-import-10MiB-warm-cache.json"), options: .atomic)
    }

    private func measureImport(from source: URL, to destination: URL, backgroundWrite: Bool,
                               defaults: UserDefaults) async throws -> (totalMs: Double, mainThreadMs: Double) {
        let totalStart = DispatchTime.now().uptimeNanoseconds
        var mainStart = totalStart
        var names: [String] = []
        var selectedName = ""
        var mainNanoseconds: UInt64 = 0
        let fileName: String
        if backgroundWrite {
            let existingNames = Set(names)
            mainNanoseconds += DispatchTime.now().uptimeNanoseconds - mainStart
            fileName = try await GifResource.performFileIO {
                try GifResource.importFile(from: source, to: destination, existingNames: existingNames)
            }
            mainStart = DispatchTime.now().uptimeNanoseconds
        } else {
            mainNanoseconds += DispatchTime.now().uptimeNanoseconds - mainStart
            let data = try await GifResource.performFileIO {
                let accessing = source.startAccessingSecurityScopedResource()
                defer { if accessing { source.stopAccessingSecurityScopedResource() } }
                return try GifResource(contentsOf: source).data
            }
            mainStart = DispatchTime.now().uptimeNanoseconds
            // 保留优化前的真实边界作为对照，不能用后台耗时冒充主线程占用。
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let baseName = source.deletingPathExtension().lastPathComponent
            var candidate = "\(baseName).gif"
            var counter = 1
            while names.contains(candidate) || FileManager.default.fileExists(atPath: destination.appendingPathComponent(candidate).path) {
                candidate = "\(baseName)_\(counter).gif"
                counter += 1
            }
            try data.write(to: destination.appendingPathComponent(candidate), options: .atomic)
            fileName = candidate
        }
        names.append(fileName)
        defaults.set(names, forKey: "customGifList")
        if selectedName.isEmpty {
            selectedName = fileName
            defaults.set(fileName, forKey: "selectedGifName")
            NotificationCenter().post(name: .init("GifDidChange"), object: nil)
        }
        let end = DispatchTime.now().uptimeNanoseconds
        mainNanoseconds += end - mainStart
        return (Double(end - totalStart) / 1_000_000, Double(mainNanoseconds) / 1_000_000)
    }

    private func statistics(_ samples: [Double]) -> [String: Any] {
        let sorted = samples.sorted()
        return ["samplesMs": samples, "medianMs": sorted[sorted.count / 2],
                "p95Ms": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1], "maxMs": sorted.last!]
    }
}
