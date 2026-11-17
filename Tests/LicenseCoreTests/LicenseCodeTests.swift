import XCTest
import CryptoKit
@testable import XNookLicenseCore

final class LicenseCodeTests: XCTestCase {

    private func makeKey() -> Curve25519.Signing.PrivateKey {
        Curve25519.Signing.PrivateKey()
    }

    // MARK: - 载荷序列化

    func testPayloadByteLayout() {
        let payload = LicensePayload(version: 1, serial: 0x01020304, flags: [.perpetual])
        XCTAssertEqual(payload.bytes, [1, 1, 2, 3, 4, 1])
    }

    func testPayloadRoundTrip() throws {
        for serial: UInt32 in [0, 1, 255, 256, 65535, 1_000_000, UInt32.max] {
            let payload = LicensePayload(serial: serial, flags: [.perpetual, .earlySupporter])
            let restored = try LicensePayload(bytes: payload.bytes)
            XCTAssertEqual(restored, payload)
        }
    }

    func testPayloadRejectsWrongByteCount() {
        XCTAssertThrowsError(try LicensePayload(bytes: [1, 2, 3]))
        XCTAssertThrowsError(try LicensePayload(bytes: [1, 2, 3, 4, 5, 6, 7]))
    }

    func testFlagsOptionSet() {
        let flags: LicenseFlags = [.perpetual, .complimentary]
        XCTAssertTrue(flags.contains(.perpetual))
        XCTAssertTrue(flags.contains(.complimentary))
        XCTAssertFalse(flags.contains(.earlySupporter))
        XCTAssertEqual(flags.rawValue, 1 | 4)
    }

    func testFlagsLabels() {
        XCTAssertEqual(LicenseFlags([.perpetual]).labels, ["perpetual"])
        XCTAssertEqual(
            LicenseFlags([.perpetual, .earlySupporter]).labels,
            ["perpetual", "early-supporter"]
        )
        XCTAssertEqual(LicenseFlags([]).labels, [])
    }

    func testShortIdentifierFormat() {
        XCTAssertEqual(LicensePayload(serial: 42).shortIdentifier, "XN-000042")
        XCTAssertEqual(LicensePayload(serial: 1_234_567).shortIdentifier, "XN-1234567")
    }

    // MARK: - 码长度

    func testCodeLengthIsAsExpected() throws {
        let key = makeKey()
        let code = try LicenseSigning.issue(payload: LicensePayload(serial: 1), privateKey: key)

        // 6 字节载荷 + 64 字节签名 = 70 字节
        XCTAssertEqual(LicenseCode.totalByteCount, 70)
        // 70 × 8 = 560 位，560 / 5 = 112 字符
        XCTAssertEqual(LicenseCode.bodyCharacterCount, 112)

        let body = code.encoded.filter { $0 != "-" }
        XCTAssertEqual(body.count, 4 + 112, "含前缀的总字符数应为 116")
    }

    func testEncodedHasPrefixAndGrouping() throws {
        let key = makeKey()
        let code = try LicenseSigning.issue(payload: LicensePayload(serial: 7), privateKey: key)
        let encoded = code.encoded

        XCTAssertTrue(encoded.hasPrefix("XNK1-"), "应带品牌前缀")

        let groups = encoded.split(separator: "-")
        XCTAssertEqual(groups.first, "XNK1")
        // 除前缀外共 28 组，每组 4 字符
        XCTAssertEqual(groups.count - 1, 28)
        for group in groups.dropFirst() {
            XCTAssertEqual(group.count, LicenseCode.groupSize)
        }
    }

    // MARK: - 解析

    func testParseRoundTrip() throws {
        let key = makeKey()
        let payload = LicensePayload(serial: 999, flags: [.perpetual, .earlySupporter])
        let code = try LicenseSigning.issue(payload: payload, privateKey: key)

        let reparsed = try LicenseCode(parsing: code.encoded)
        XCTAssertEqual(reparsed.payload, payload)
        XCTAssertEqual(reparsed.signature, code.signature)
    }

    func testParseToleratesCaseAndSeparators() throws {
        let key = makeKey()
        let code = try LicenseSigning.issue(payload: LicensePayload(serial: 5), privateKey: key)

        let lowercase = code.encoded.lowercased()
        let noSeparators = code.encoded.replacingOccurrences(of: "-", with: "")
        let spaced = code.encoded.replacingOccurrences(of: "-", with: " ")
        let withNewlines = code.encoded.replacingOccurrences(of: "-", with: "\n")

        XCTAssertEqual(try LicenseCode(parsing: lowercase).payload, code.payload)
        XCTAssertEqual(try LicenseCode(parsing: noSeparators).payload, code.payload)
        XCTAssertEqual(try LicenseCode(parsing: spaced).payload, code.payload)
        XCTAssertEqual(try LicenseCode(parsing: withNewlines).payload, code.payload)
    }

    func testParseRejectsEmptyInput() {
        XCTAssertThrowsError(try LicenseCode(parsing: "")) { error in
            XCTAssertEqual(error as? LicenseError, .emptyInput)
        }
        XCTAssertThrowsError(try LicenseCode(parsing: "   \n  ")) { error in
            XCTAssertEqual(error as? LicenseError, .emptyInput)
        }
    }

    func testParseRejectsTruncatedCode() throws {
        let key = makeKey()
        let code = try LicenseSigning.issue(payload: LicensePayload(serial: 1), privateKey: key)
        let truncated = String(code.encoded.prefix(30))

        XCTAssertThrowsError(try LicenseCode(parsing: truncated)) { error in
            guard case .wrongLength = error as? LicenseError else {
                return XCTFail("应抛出长度错误，实际为 \(error)")
            }
        }
    }

    func testParseRejectsGarbageInput() {
        XCTAssertThrowsError(try LicenseCode(parsing: "hello world"))
    }

    func testParseRejectsUnsupportedVersion() throws {
        // 构造一个版本号为 99 的载荷并正确签名——模拟「未来版本生成的码」
        let key = makeKey()
        let future = LicensePayload(version: 99, serial: 1, flags: [.perpetual])
        let code = try LicenseSigning.issue(payload: future, privateKey: key)

        XCTAssertThrowsError(try LicenseCode(parsing: code.encoded)) { error in
            XCTAssertEqual(error as? LicenseError, .unsupportedVersion(99))
        }
    }

    // MARK: - 激活链接

    func testActivationURLUsesCompactForm() throws {
        let key = makeKey()
        let code = try LicenseSigning.issue(payload: LicensePayload(serial: 1), privateKey: key)
        let url = code.activationURL

        XCTAssertTrue(url.hasPrefix("xnook://activate?code=XNK1"))
        XCTAssertFalse(url.contains("-"), "紧凑形式不应包含分隔符")
        XCTAssertEqual(try LicenseCode(parsing: code.compactEncoded).payload, code.payload)
    }
}
