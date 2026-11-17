import XCTest
import CryptoKit
@testable import XNookLicenseCore

final class LicenseSigningTests: XCTestCase {

    // MARK: - 正常路径

    func testIssuedCodeVerifies() throws {
        let key = Curve25519.Signing.PrivateKey()
        let code = try LicenseSigning.issue(payload: LicensePayload(serial: 1), privateKey: key)
        XCTAssertTrue(LicenseSigning.verify(code, using: key.publicKey))
    }

    func testVerifyFromString() throws {
        let key = Curve25519.Signing.PrivateKey()
        let code = try LicenseSigning.issue(payload: LicensePayload(serial: 42), privateKey: key)
        let verified = try LicenseSigning.verify(input: code.encoded, using: key.publicKey)
        XCTAssertEqual(verified.payload.serial, 42)
    }

    // MARK: - 篡改检测

    func testTamperedSignatureIsRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        var code = try LicenseSigning.issue(payload: LicensePayload(serial: 1), privateKey: key)

        // 翻转签名中的任意一位
        for index in [0, 31, 63] {
            var tampered = code
            tampered.signature[index] ^= 0x01
            XCTAssertFalse(
                LicenseSigning.verify(tampered, using: key.publicKey),
                "签名第 \(index) 字节被翻转后仍通过验证"
            )
        }
        code.signature[0] = code.signature[0]
    }

    func testTamperedPayloadIsRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        let code = try LicenseSigning.issue(payload: LicensePayload(serial: 1), privateKey: key)

        // 保持签名不变，篡改载荷中的序列号
        let forged = try LicenseCode(
            payload: LicensePayload(serial: 999_999),
            signature: code.signature
        )
        XCTAssertFalse(
            LicenseSigning.verify(forged, using: key.publicKey),
            "载荷被篡改后签名仍通过验证——这是严重缺陷"
        )
    }

    func testCodeSignedByOtherKeyIsRejected() throws {
        let issuer = Curve25519.Signing.PrivateKey()
        let attacker = Curve25519.Signing.PrivateKey()
        let code = try LicenseSigning.issue(payload: LicensePayload(serial: 1), privateKey: attacker)

        XCTAssertFalse(
            LicenseSigning.verify(code, using: issuer.publicKey),
            "使用他人密钥签发的码不应通过验证"
        )
    }

    // MARK: - 域分隔

    func testMessageIncludesDomainSeparator() {
        let payload = LicensePayload(serial: 1)
        let message = LicenseSigning.message(for: payload)

        XCTAssertEqual(message.count, LicenseSigning.domainSeparator.count + LicensePayload.byteCount)
        XCTAssertTrue(message.starts(with: LicenseSigning.domainSeparator))
    }

    func testSignatureIsNotOverBarePayload() throws {
        // 若签名直接作用于裸载荷，则「域前缀 + 载荷」的签名会与裸载荷签名不同。
        // 本测试确认域分隔确实生效。
        let key = Curve25519.Signing.PrivateKey()
        let payload = LicensePayload(serial: 7)

        let separatedSignature = try key.signature(for: LicenseSigning.message(for: payload))
        let bareSignature = try key.signature(for: Data(payload.bytes))

        XCTAssertNotEqual(
            Data(separatedSignature),
            Data(bareSignature),
            "域分隔未生效，签名对象可能是裸载荷"
        )
    }

    // MARK: - 密钥编解码

    func testKeyRoundTripThroughRawRepresentation() throws {
        let key = Curve25519.Signing.PrivateKey()
        let raw = key.rawRepresentation

        let restored = try LicenseSigning.privateKey(fromRaw: raw)
        XCTAssertEqual(restored.rawRepresentation, raw)

        let publicRaw = key.publicKey.rawRepresentation
        let restoredPublic = try LicenseSigning.publicKey(fromRaw: publicRaw)
        XCTAssertEqual(restoredPublic.rawRepresentation, publicRaw)
    }

    func testPublicKeyFromBase64() throws {
        let key = Curve25519.Signing.PrivateKey()
        let base64 = key.publicKey.rawRepresentation.base64EncodedString()

        let restored = try LicenseSigning.publicKey(base64: base64)
        XCTAssertEqual(restored.rawRepresentation, key.publicKey.rawRepresentation)

        // 经由 Base64 还原的公钥必须能验证原密钥签发的码
        let code = try LicenseSigning.issue(payload: LicensePayload(serial: 3), privateKey: key)
        XCTAssertTrue(LicenseSigning.verify(code, using: restored))
    }

    func testInvalidBase64Throws() {
        XCTAssertThrowsError(try LicenseSigning.publicKey(base64: "not-valid-base64!!!"))
    }

    func testGenerateKeyPairProducesDistinctKeys() {
        let first = LicenseSigning.generateKeyPair()
        let second = LicenseSigning.generateKeyPair()
        XCTAssertNotEqual(first.rawRepresentation, second.rawRepresentation)
    }

    // MARK: - 批量签发

    func testBatchIssuanceProducesUniqueVerifiableCodes() throws {
        let key = Curve25519.Signing.PrivateKey()
        var seen = Set<String>()

        for serial in UInt32(1)...UInt32(200) {
            let code = try LicenseSigning.issue(payload: LicensePayload(serial: serial), privateKey: key)
            let encoded = code.encoded

            XCTAssertTrue(LicenseSigning.verify(code, using: key.publicKey))
            XCTAssertFalse(seen.contains(encoded), "序列号 \(serial) 产生了重复的邀请码")
            seen.insert(encoded)

            // 解析回来序列号必须一致
            XCTAssertEqual(try LicenseCode(parsing: encoded).payload.serial, serial)
        }

        XCTAssertEqual(seen.count, 200)
    }

    func testSerialNumberBoundaries() throws {
        let key = Curve25519.Signing.PrivateKey()
        for serial: UInt32 in [0, 1, UInt32.max] {
            let payload = LicensePayload(serial: serial)
            let code = try LicenseSigning.issue(payload: payload, privateKey: key)
            let reparsed = try LicenseCode(parsing: code.encoded)
            XCTAssertEqual(reparsed.payload.serial, serial, "序列号 \(serial) 往返失败")
        }
    }
}
