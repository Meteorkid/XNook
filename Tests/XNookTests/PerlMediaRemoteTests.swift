import XCTest
@testable import XNook

@MainActor
final class PerlMediaRemoteTests: XCTestCase {
    /// 模拟桥接返回的 B 站快照（微秒时间轴、PID 为字符串、isPlaying 为 Bool）。
    private func bilibiliJSON(title: String = "【Adele】历年演唱会全场合集") -> Data {
        let json = """
        {"type":"data","diff":false,"payload":{
          "playbackRate":1,"timestampEpochMicros":1794906609333302,
          "album":"","elapsedTimeMicros":2646537109,
          "bundleIdentifier":"com.bilibili.bilibiliPC","title":"\(title)",
          "applicationName":"哔哩哔哩","artworkDataBase64":null,"isPlaying":true,
          "shuffleMode":null,"artworkMimeType":null,"repeatMode":null,
          "artist":"","durationMicros":3818866943,"PID":"3144"}}
        """
        return Data(json.utf8)
    }

    func testDecodeBilibiliTrack() throws {
        let payload = try decodePayload(bilibiliJSON())
        XCTAssertEqual(payload?.title, "【Adele】历年演唱会全场合集")
        XCTAssertEqual(payload?.bundleIdentifier, "com.bilibili.bilibiliPC")
        XCTAssertEqual(payload?.applicationName, "哔哩哔哩")
        XCTAssertEqual(payload?.isPlaying, true)
        XCTAssertEqual(payload?.PID, 3144)
        XCTAssertTrue(payload?.hasTrack == true)
    }

    func testNormalizeMapsPerlFieldsToInternalInfo() throws {
        let payload = try XCTUnwrap(decodePayload(bilibiliJSON()))
        let info = MediaRemoteBridge.normalizePerl(payload, now: Date(timeIntervalSince1970: 1794906610))

        XCTAssertEqual(info["title"] as? String, "【Adele】历年演唱会全场合集")
        XCTAssertEqual(info["sourceBundleID"] as? String, "com.bilibili.bilibiliPC")
        XCTAssertEqual(info["sourceName"] as? String, "哔哩哔哩")
        XCTAssertEqual(try XCTUnwrap(info["duration"] as? Double), 3818.866943, accuracy: 0.01)
        XCTAssertEqual(info["playbackRate"] as? Double, 1.0)
        XCTAssertNotNil(info["playerPosition"])
        XCTAssertNotNil(info["positionTimestamp"])
        XCTAssertNil(info["fetchFailed"] as? Bool)
    }

    func testSourceRecognitionFromPerlInfo() throws {
        let payload = try XCTUnwrap(decodePayload(bilibiliJSON()))
        let info = MediaRemoteBridge.normalizePerl(payload)
        let source = MediaSource.from(info: info)
        XCTAssertEqual(source?.bundleIdentifier, "com.bilibili.bilibiliPC")
        XCTAssertEqual(source?.displayName, "哔哩哔哩")
        XCTAssertNil(source?.scriptingApp, "B 站无脚本词典，控制应走系统命令")
    }

    func testElapsedTimeCompensatesForSampleAge() throws {
        let json = """
        {"type":"data","payload":{"title":"t","isPlaying":true,"playbackRate":2,
         "elapsedTimeMicros":1000000,"timestampEpochMicros":1000000000000}}
        """
        let payload = try XCTUnwrap(decodePayload(Data(json.utf8)))
        // 采样时刻 1e6 秒(微秒 1e12)，当前 1e6+5 秒，rate=2 → 1 + 5*2 = 11
        let position = payload.elapsedTime(at: Date(timeIntervalSince1970: 1_000_005))
        XCTAssertEqual(try XCTUnwrap(position), 11.0, accuracy: 0.01)
    }

    func testEmptyTitleIsNotATrack() throws {
        let json = #"{"type":"data","payload":{"title":"","bundleIdentifier":"x"}}"#
        let payload = try decodePayload(Data(json.utf8))
        XCTAssertFalse(payload?.hasTrack == true)
    }

    func testPIDAcceptsNumber() throws {
        let json = #"{"type":"data","payload":{"title":"t","PID":3144,"isPlaying":0}}"#
        let payload = try XCTUnwrap(decodePayload(Data(json.utf8)))
        XCTAssertEqual(payload.PID, 3144)
        XCTAssertEqual(payload.isPlaying, false)
    }

    /// 复用桥接层的解码逻辑（通过反射不可行，这里用同样规则独立解析验证 JSON 契约）。
    private func decodePayload(_ data: Data) throws -> PerlTrackPayload? {
        struct Response: Decodable { let type: String?; let payload: PerlTrackPayload? }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.type == "data", response.payload?.hasTrack == true else { return nil }
        return response.payload
    }
}
