import XCTest
@testable import XNookLicenseCore

final class CrockfordBase32Tests: XCTestCase {

    func testEncodeDecodeRoundTrip() throws {
        for length in [1, 2, 3, 5, 6, 7, 8, 16, 32, 64, 70] {
            let original = (0..<length).map { _ in UInt8.random(in: 0...255) }
            let encoded = CrockfordBase32.encode(original)
            let decoded = try CrockfordBase32.decode(encoded)
            XCTAssertEqual(
                Array(decoded.prefix(length)),
                original,
                "长度为 \(length) 的字节序列往返不一致"
            )
        }
    }

    func testEncodeUsesOnlyAlphabetCharacters() {
        let bytes = (0..<64).map { _ in UInt8.random(in: 0...255) }
        let encoded = CrockfordBase32.encode(bytes)
        for character in encoded {
            XCTAssertTrue(
                CrockfordBase32.alphabet.contains(character),
                "编码结果出现字母表外字符：\(character)"
            )
        }
    }

    func testAlphabetExcludesAmbiguousCharacters() {
        // Crockford 变体的核心特征：排除 I / L / O / U
        let excluded: [Character] = ["I", "L", "O", "U"]
        for character in excluded {
            XCTAssertFalse(
                CrockfordBase32.alphabet.contains(character),
                "字母表不应包含易混字符 \(character)"
            )
        }
    }

    func testDecodeToleranceForLookalikes() throws {
        // I 与 L 视为 1，O 视为 0
        let canonical = try CrockfordBase32.decode("1111")
        XCTAssertEqual(try CrockfordBase32.decode("IIII"), canonical)
        XCTAssertEqual(try CrockfordBase32.decode("LLLL"), canonical)
        XCTAssertEqual(try CrockfordBase32.decode("lili"), canonical)

        let zero = try CrockfordBase32.decode("0000")
        XCTAssertEqual(try CrockfordBase32.decode("OOOO"), zero)
        XCTAssertEqual(try CrockfordBase32.decode("oooo"), zero)
    }

    func testDecodeIsCaseInsensitive() throws {
        XCTAssertEqual(
            try CrockfordBase32.decode("abcdefghjkmnpqrstvwxyz"),
            try CrockfordBase32.decode("ABCDEFGHJKMNPQRSTVWXYZ")
        )
    }

    func testDecodeIgnoresSeparatorsAndWhitespace() throws {
        let compact = try CrockfordBase32.decode("ABCD1234")
        XCTAssertEqual(try CrockfordBase32.decode("ABCD-1234"), compact)
        XCTAssertEqual(try CrockfordBase32.decode("ABCD 1234"), compact)
        XCTAssertEqual(try CrockfordBase32.decode("AB\nCD\t12\r34"), compact)
        XCTAssertEqual(try CrockfordBase32.decode("  ABCD1234  "), compact)
    }

    func testDecodeRejectsInvalidCharacter() {
        // U 与 I/L/O 不同——它不在字母表中，也不做容错映射
        XCTAssertThrowsError(try CrockfordBase32.decode("ABCU")) { error in
            XCTAssertEqual(error as? LicenseError, .invalidCharacter("U"))
        }
    }

    func testEmptyInputProducesEmptyOutput() throws {
        XCTAssertEqual(CrockfordBase32.encode([]), "")
        XCTAssertEqual(try CrockfordBase32.decode(""), [])
    }

    func testEncodedLengthMatchesActualOutput() {
        for byteCount in 1...80 {
            let bytes = (0..<byteCount).map { _ in UInt8.random(in: 0...255) }
            let encoded = CrockfordBase32.encode(bytes)
            XCTAssertEqual(
                encoded.count,
                CrockfordBase32.encodedLength(forByteCount: byteCount),
                "字节数 \(byteCount) 的预估长度与实际不符"
            )
        }
    }

    func testKnownVector() {
        // 全零 6 字节 → 编码为 10 个 '0'（6×8=48 位，48/5=9.6 → 10 字符）
        XCTAssertEqual(CrockfordBase32.encode([0, 0, 0, 0, 0, 0]), "0000000000")
    }
}
