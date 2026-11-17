import Foundation

/// Crockford Base32 编解码。
///
/// 选用 Crockford 变体的原因：字母表刻意排除了 `I`、`L`、`O`、`U` 四个字符，
/// 避免手抄时的形近混淆（1/I/L、0/O）与意外拼出冒犯性单词。
/// 解码时对易混字符做容错映射（I/L → 1，O → 0），并接受小写输入。
public enum CrockfordBase32 {

    /// Crockford Base32 字母表（32 个字符，无 I / L / O / U）
    public static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// 字符 → 5 位值。含容错映射。
    private static let decodeTable: [Character: UInt8] = {
        var table: [Character: UInt8] = [:]
        for (index, character) in alphabet.enumerated() {
            table[character] = UInt8(index)
            table[Character(character.lowercased())] = UInt8(index)
        }
        // 形近字符容错：这些字符不在字母表中，但用户可能误写
        let tolerance: [Character: UInt8] = [
            "I": 1, "i": 1,   // I 误认为 1
            "L": 1, "l": 1,   // L 误认为 1
            "O": 0, "o": 0,   // O 误认为 0
        ]
        for (character, value) in tolerance {
            table[character] = value
        }
        return table
    }()

    /// 每 8 位输入产生的输出字符数（向上取整到 5 位对齐）
    public static func encodedLength(forByteCount byteCount: Int) -> Int {
        (byteCount * 8 + 4) / 5
    }

    /// 编码：按大端序每 5 位取一个字符，末组右侧补零对齐。
    public static func encode(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "" }

        var output = ""
        output.reserveCapacity(encodedLength(forByteCount: bytes.count))

        var buffer: UInt32 = 0
        var bitCount = 0

        for byte in bytes {
            buffer = (buffer << 8) | UInt32(byte)
            bitCount += 8

            while bitCount >= 5 {
                bitCount -= 5
                let index = Int((buffer >> UInt32(bitCount)) & 0x1F)
                output.append(alphabet[index])
            }

            // 丢弃已消费的高位，防止 buffer 溢出
            buffer &= bitCount == 0 ? 0 : (UInt32(1) << UInt32(bitCount)) - 1
        }

        if bitCount > 0 {
            let index = Int((buffer << UInt32(5 - bitCount)) & 0x1F)
            output.append(alphabet[index])
        }

        return output
    }

    /// 解码：忽略分隔符与空白，大小写不敏感。
    /// - Throws: `LicenseError.invalidCharacter` 当遇到字母表外的字符。
    public static func decode(_ string: String) throws -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(string.count * 5 / 8)

        var buffer: UInt32 = 0
        var bitCount = 0

        for character in string {
            // 允许用户粘贴带分隔符/换行/空格的文本
            if character == "-" || character == " " || character == "\n"
                || character == "\r" || character == "\t" {
                continue
            }
            guard let value = decodeTable[character] else {
                throw LicenseError.invalidCharacter(character)
            }
            buffer = (buffer << 5) | UInt32(value)
            bitCount += 5

            if bitCount >= 8 {
                bitCount -= 8
                output.append(UInt8((buffer >> UInt32(bitCount)) & 0xFF))
            }

            buffer &= bitCount == 0 ? 0 : (UInt32(1) << UInt32(bitCount)) - 1
        }

        return output
    }
}
