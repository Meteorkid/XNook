import Foundation
import CryptoKit
import XNookLicenseCore

// MARK: - 输出辅助

/// 统一的终端输出。检测是否为 TTY 以决定是否着色，重定向到文件时不产生转义序列。
enum Term {
    static let isTTY = isatty(STDOUT_FILENO) == 1

    static func bold(_ text: String) -> String { isTTY ? "\u{1B}[1m\(text)\u{1B}[0m" : text }
    static func dim(_ text: String) -> String { isTTY ? "\u{1B}[2m\(text)\u{1B}[0m" : text }
    static func green(_ text: String) -> String { isTTY ? "\u{1B}[32m\(text)\u{1B}[0m" : text }
    static func red(_ text: String) -> String { isTTY ? "\u{1B}[31m\(text)\u{1B}[0m" : text }
    static func yellow(_ text: String) -> String { isTTY ? "\u{1B}[33m\(text)\u{1B}[0m" : text }
}

/// 向 stderr 输出错误并退出
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// 向 stderr 输出提示（不中断执行）
func warn(_ message: String) {
    FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
}

// MARK: - 参数解析

/// 极简参数解析器。
///
/// 支持 `--key value`、`--key=value` 与 `--flag` 三种形式。
/// 刻意不引入第三方依赖，保持工具可独立编译。
struct Arguments {
    private var options: [String: String] = [:]
    private var flags: Set<String> = []
    private var positionals: [String] = []

    init(_ raw: [String]) {
        var index = 0
        while index < raw.count {
            let token = raw[index]
            if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))
                if let equalsIndex = body.firstIndex(of: "=") {
                    let key = String(body[body.startIndex..<equalsIndex])
                    let value = String(body[body.index(after: equalsIndex)...])
                    options[key] = value
                } else if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                    options[body] = raw[index + 1]
                    index += 1
                } else {
                    flags.insert(body)
                }
            } else if token.hasPrefix("-"), token.count > 1 {
                let body = String(token.dropFirst())
                if index + 1 < raw.count, !raw[index + 1].hasPrefix("-") {
                    options[body] = raw[index + 1]
                    index += 1
                } else {
                    flags.insert(body)
                }
            } else {
                positionals.append(token)
            }
            index += 1
        }
    }

    func value(_ key: String) -> String? { options[key] }
    func has(_ key: String) -> Bool { flags.contains(key) || options[key] != nil }
    func int(_ key: String) -> Int? { options[key].flatMap(Int.init) }
    var positional: [String] { positionals }
}

// MARK: - 私钥载入

/// 从文件载入私钥。
///
/// 文件格式：单行 Base64（32 字节 Ed25519 私钥种子）。
/// 允许注释行（以 `#` 开头）与空行，便于在文件里记录发码批次备注。
func loadPrivateKey(path: String) -> Curve25519.Signing.PrivateKey {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("无法读取私钥文件：\(path)")
    }
    let base64 = content
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { !$0.isEmpty && !$0.hasPrefix("#") }

    guard let base64, let data = Data(base64Encoded: base64) else {
        fail("私钥文件格式不正确，应包含一行 Base64 编码的 32 字节私钥")
    }
    do {
        return try LicenseSigning.privateKey(fromRaw: data)
    } catch {
        fail("私钥解析失败：\(error.localizedDescription)")
    }
}

// MARK: - keygen

/// 生成 Ed25519 密钥对。
///
/// 私钥写入指定文件（权限 600），公钥既打印到终端，也可直接写入 App 源码。
func runKeygen(_ args: Arguments) {
    let outPath = args.value("out")
    let privatePath = args.value("private") ?? "license-private.key"

    // 防止误覆盖既有私钥——私钥丢失意味着已发出的邀请码无法再续发
    if FileManager.default.fileExists(atPath: privatePath), !args.has("force") {
        fail("私钥文件已存在：\(privatePath)\n如需重新生成，请加 --force（注意：旧私钥签发过的码将无法再验证）")
    }

    let privateKey = LicenseSigning.generateKeyPair()
    let publicKey = privateKey.publicKey

    let privateBase64 = privateKey.rawRepresentation.base64EncodedString()
    let publicBase64 = publicKey.rawRepresentation.base64EncodedString()

    // 写入私钥，权限收紧到仅本人可读写
    let header = """
    # XNook 邀请码签名私钥
    # 生成时间：\(ISO8601DateFormatter().string(from: Date()))
    #
    # ⚠️ 此文件等同于「印钞机」——持有它的人可以签发任意数量的有效邀请码。
    # 请离线保管，切勿提交到版本控制，切勿随 App 分发。
    # 建议同时备份到加密介质；私钥一旦丢失，已发出的邀请码将无法继续校验。
    #
    """
    let privateContent = header + "\n" + privateBase64 + "\n"

    do {
        try privateContent.write(toFile: privatePath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: privatePath
        )
    } catch {
        fail("写入私钥失败：\(error.localizedDescription)")
    }

    print(Term.bold("密钥对已生成"))
    print("")
    print("私钥：\(privatePath)  \(Term.dim("(权限 600，请离线保管)"))")
    print("")
    print("公钥（Base64）：")
    print("  \(publicBase64)")
    print("")

    if let outPath {
        // 直接生成可编译的 Swift 文件，避免手工复制粘贴出错
        let swiftSource = """
        import Foundation
        import CryptoKit
        import XNookLicenseCore

        /// 内嵌的 Ed25519 公钥。
        ///
        /// ⚠️ 此文件由 `licensegen keygen` 生成，**不要手工编辑**。
        /// 重新运行 `licensegen keygen` 会覆盖本文件。
        ///
        /// 公钥可以安全地公开——它只能用于验证签名，无法用于生成有效邀请码。
        /// 对应的私钥必须离线保管，绝不进入版本控制。
        enum LicensePublicKey {

            /// Base64 编码的 Ed25519 公钥（32 字节）。
            static let base64 = "\(publicBase64)"

            /// 是否为尚未替换的占位密钥。
            /// 为 `true` 时，App 会拒绝一切激活并给出明确提示，避免把开发密钥误发上线。
            static var isPlaceholder: Bool {
                base64 == "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
            }

            /// 解析后的公钥。占位状态下返回 `nil`。
            static var publicKey: Curve25519.Signing.PublicKey? {
                guard !isPlaceholder else { return nil }
                return try? LicenseSigning.publicKey(base64: base64)
            }
        }

        """
        do {
            try swiftSource.write(toFile: outPath, atomically: true, encoding: .utf8)
            print(Term.green("✓") + " 已写入公钥源码：\(outPath)")
            print(Term.dim("  下一步：重新编译 App（swift build）使新公钥生效。"))
        } catch {
            fail("写入公钥源码失败：\(error.localizedDescription)")
        }
    } else {
        print(Term.dim("提示：加 --out Sources/XNook/Licensing/LicensePublicKey.swift 可直接生成公钥源码文件。"))
    }

    print("")
    print(Term.yellow("安全提醒") + "：请立即将私钥移出项目目录，例如：")
    print("  mv \(privatePath) ~/.xnook-license/license-private.key")
    print("  并在 .gitignore 中确认已忽略 *.key")
}

// MARK: - issue

/// 批量签发邀请码。
func runIssue(_ args: Arguments) {
    let keyPath = args.value("key") ?? "license-private.key"
    let count = args.int("count") ?? 1
    let startSerial = args.int("start").map(UInt32.init) ?? 1
    let csvPath = args.value("csv")
    let plainPath = args.value("out")

    guard count > 0 else { fail("--count 必须大于 0") }
    guard count <= 100_000 else { fail("--count 上限为 100000，如需更多请分批执行") }

    // 序列号溢出检查：载荷中序列号为 UInt32
    let endSerial = UInt64(startSerial) + UInt64(count) - 1
    guard endSerial <= UInt64(UInt32.max) else {
        fail("序列号将超出 UInt32 上限（最大 \(UInt32.max)）")
    }

    var flags: LicenseFlags = [.perpetual]
    if args.has("early-supporter") { flags.insert(.earlySupporter) }
    if args.has("complimentary") { flags.insert(.complimentary) }
    if args.has("no-perpetual") { flags.remove(.perpetual) }

    let privateKey = loadPrivateKey(path: keyPath)
    let issuedAt = ISO8601DateFormatter().string(from: Date())

    var rows: [[String]] = [["serial", "code", "short_id", "flags", "issued_at"]]
    var plainLines: [String] = []

    for offset in 0..<count {
        let serial = startSerial + UInt32(offset)
        let payload = LicensePayload(serial: serial, flags: flags)
        do {
            let code = try LicenseSigning.issue(payload: payload, privateKey: privateKey)
            let encoded = code.encoded
            rows.append([
                String(serial),
                encoded,
                payload.shortIdentifier,
                flags.labels.joined(separator: "|"),
                issuedAt,
            ])
            plainLines.append(encoded)
        } catch {
            fail("签发序列号 \(serial) 失败：\(error.localizedDescription)")
        }
    }

    // 终端预览：数量少时全列，数量多时只列首尾，避免刷屏
    print(Term.bold("已签发 \(count) 个邀请码") + Term.dim("（序列号 \(startSerial)–\(endSerial)，标志：\(flags.labels.joined(separator: ", "))）"))
    print("")
    if count <= 10 {
        for line in plainLines { print(line) }
    } else {
        for line in plainLines.prefix(2) { print(line) }
        print(Term.dim("… 中间省略 \(count - 4) 条 …"))
        for line in plainLines.suffix(2) { print(line) }
    }
    print("")

    if let plainPath {
        do {
            try (plainLines.joined(separator: "\n") + "\n")
                .write(toFile: plainPath, atomically: true, encoding: .utf8)
            print(Term.green("✓") + " 纯文本清单：\(plainPath)")
        } catch {
            fail("写入清单失败：\(error.localizedDescription)")
        }
    }

    if let csvPath {
        let csv = rows.map { row in
            row.map { field -> String in
                // CSV 转义：字段含逗号/引号/换行时加引号并转义内部引号
                if field.contains(",") || field.contains("\"") || field.contains("\n") {
                    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return field
            }.joined(separator: ",")
        }.joined(separator: "\n") + "\n"

        do {
            try csv.write(toFile: csvPath, atomically: true, encoding: .utf8)
            print(Term.green("✓") + " CSV 台账：\(csvPath)  \(Term.dim("(可直接导入发卡网)"))")
        } catch {
            fail("写入 CSV 失败：\(error.localizedDescription)")
        }
    }

    if plainPath == nil && csvPath == nil {
        print(Term.dim("提示：加 --csv codes.csv 导出台账，或 --out codes.txt 导出纯文本清单。"))
    }

    print("")
    print(Term.dim("下一个可用序列号：\(endSerial + 1)"))
}

// MARK: - inspect

/// 解析并校验邀请码。
func runInspect(_ args: Arguments) {
    let inputs = args.positional
    guard !inputs.isEmpty else {
        fail("用法：licensegen inspect <邀请码> [更多邀请码…]")
    }

    // 有公钥则做完整验签，否则仅解析载荷
    let publicKeyPath = args.value("public")
    var publicKey: Curve25519.Signing.PublicKey?
    if let publicKeyPath {
        if let content = try? String(contentsOfFile: publicKeyPath, encoding: .utf8) {
            let base64 = content
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
            publicKey = try? LicenseSigning.publicKey(base64: base64)
            if publicKey == nil {
                warn("无法从 \(publicKeyPath) 解析公钥，将跳过验签")
            }
        } else {
            warn("无法读取公钥文件：\(publicKeyPath)")
        }
    }

    for (index, input) in inputs.enumerated() {
        if index > 0 { print("") }

        do {
            let code = try LicenseCode(parsing: input)
            let payload = code.payload

            let signatureNote: String
            if let publicKey {
                let valid = LicenseSigning.verify(code, using: publicKey)
                signatureNote = valid
                    ? Term.green("有效")
                    : Term.red("无效（签名不匹配，可能被篡改或使用了其他密钥签发）")
            } else {
                signatureNote = Term.yellow("未校验") + Term.dim("（未提供 --public 公钥）")
            }

            print(Term.bold("邀请码") + "  \(code.encoded)")
            print("  序列号    \(payload.serial)  \(Term.dim(payload.shortIdentifier))")
            print("  格式版本  \(payload.version)")
            print("  标志      \(payload.flags.labels.isEmpty ? "—" : payload.flags.labels.joined(separator: ", "))")
            print("  签名      \(signatureNote)")
        } catch let error as LicenseError {
            print(Term.bold("输入") + "  \(Term.dim(input.prefix(40) + (input.count > 40 ? "…" : "")))")
            print("  结果      \(Term.red("解析失败"))")
            print("  原因      \(error.errorDescription ?? "未知错误")")
        } catch {
            print("  结果      \(Term.red("解析失败")) — \(error.localizedDescription)")
        }
    }
}

// MARK: - selfcheck

/// 自检：验证密钥对可用性、编码往返一致性、篡改检测。
/// 用于在正式发码前确认工具链本身没有损坏。
func runSelfCheck(_ args: Arguments) {
    print(Term.bold("licensegen 自检"))
    print("")

    var failures = 0
    func check(_ name: String, _ passed: Bool) {
        print("  \(passed ? Term.green("✓") : Term.red("✗")) \(name)")
        if !passed { failures += 1 }
    }

    // 1. Base32 往返
    let random = (0..<64).map { _ in UInt8.random(in: 0...255) }
    let encoded = CrockfordBase32.encode(random)
    let decoded = (try? CrockfordBase32.decode(encoded)) ?? []
    check("Base32 编解码往返一致", Array(decoded.prefix(random.count)) == random)

    // 2. 容错映射
    check("O→0 / I→1 容错", (try? CrockfordBase32.decode("O0I1")) == (try? CrockfordBase32.decode("0011")))

    // 3. 签发 → 验签
    let privateKey = LicenseSigning.generateKeyPair()
    let payload = LicensePayload(serial: 12345, flags: [.perpetual])
    if let code = try? LicenseSigning.issue(payload: payload, privateKey: privateKey) {
        check("签发 → 验签通过", LicenseSigning.verify(code, using: privateKey.publicKey))

        // 4. 字符串解析往返
        if let reparsed = try? LicenseCode(parsing: code.encoded) {
            check("字符串解析往返一致", reparsed.payload == payload && reparsed.signature == code.signature)
        } else {
            check("字符串解析往返一致", false)
        }

        // 5. 篡改检测：翻转签名中一个 bit 后必须验签失败
        var tampered = code
        tampered.signature[0] ^= 0x01
        check("篡改签名被拒绝", !LicenseSigning.verify(tampered, using: privateKey.publicKey))

        // 6. 错误密钥检测
        let otherKey = LicenseSigning.generateKeyPair()
        check("异密钥签发的码被拒绝", !LicenseSigning.verify(code, using: otherKey.publicKey))

        // 7. 长度校验
        check("截断输入被拒绝", (try? LicenseCode(parsing: String(code.encoded.prefix(20)))) == nil)
    } else {
        check("签发 → 验签通过", false)
    }

    // 8. 码长统计
    let samplePayload = LicensePayload(serial: 1)
    if let sample = try? LicenseSigning.issue(payload: samplePayload, privateKey: privateKey) {
        let bodyLength = sample.encoded.filter { $0 != "-" }.count
        print("")
        print(Term.dim("  码长：\(bodyLength) 字符（含前缀），共 \(bodyLength / LicenseCode.groupSize) 组"))
        check("码长符合预期", bodyLength == 4 + LicenseCode.bodyCharacterCount)
    }

    print("")
    if failures == 0 {
        print(Term.green("全部通过。"))
    } else {
        print(Term.red("\(failures) 项失败。"))
        exit(1)
    }
}

// MARK: - 入口

let usage = """
\(Term.bold("licensegen")) — XNook 邀请码签发工具

\(Term.bold("用法"))
  licensegen <子命令> [选项]

\(Term.bold("子命令"))
  keygen     生成 Ed25519 密钥对
  issue      批量签发邀请码
  inspect    解析并校验邀请码
  selfcheck  验证工具链自身是否正常

\(Term.bold("keygen"))
  --private <路径>   私钥输出路径（默认 license-private.key）
  --out <路径>       直接生成 App 用的公钥源码文件
  --force            允许覆盖已存在的私钥

\(Term.bold("issue"))
  --key <路径>       私钥路径（默认 license-private.key）
  --count <数量>     签发数量（默认 1）
  --start <序列号>   起始序列号（默认 1）
  --csv <路径>       导出 CSV 台账
  --out <路径>       导出纯文本清单
  --early-supporter  标记为早期支持者
  --complimentary    标记为人工赠码

\(Term.bold("inspect"))
  --public <路径>    公钥文件，提供后执行完整验签

\(Term.bold("示例"))
  # 1. 生成密钥对，并直接写入 App 源码
  swift run licensegen keygen --out Sources/XNook/Licensing/LicensePublicKey.swift

  # 2. 签发 100 个码，导出 CSV
  swift run licensegen issue --count 100 --csv batch-001.csv

  # 3. 校验一个码
  swift run licensegen inspect "XNK1-…"
"""

let rawArgs = Array(CommandLine.arguments.dropFirst())
guard let subcommand = rawArgs.first else {
    print(usage)
    exit(0)
}

let args = Arguments(Array(rawArgs.dropFirst()))

switch subcommand {
case "keygen":    runKeygen(args)
case "issue":     runIssue(args)
case "inspect":   runInspect(args)
case "selfcheck": runSelfCheck(args)
case "help", "--help", "-h":
    print(usage)
case "version", "--version":
    print("licensegen 1.0.0")
default:
    FileHandle.standardError.write(Data("未知子命令：\(subcommand)\n\n".utf8))
    print(usage)
    exit(1)
}
