import Darwin
import Foundation
import Security

private struct RegressionFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw RegressionFailure(message: message) }
}

private func verifySigning() throws {
    let flags = SecCSFlags(rawValue: 0)
    var code: SecCode?
    let selfStatus = SecCodeCopySelf(flags, &code)
    try require(selfStatus == errSecSuccess, "SecCodeCopySelf failed: \(selfStatus)")
    guard let code else { throw RegressionFailure(message: "Missing self code") }
    let validityStatus = SecCodeCheckValidity(code, flags, nil)
    try require(validityStatus == errSecSuccess, "SecCodeCheckValidity failed: \(validityStatus)")

    var staticCode: SecStaticCode?
    let staticStatus = SecCodeCopyStaticCode(code, flags, &staticCode)
    try require(staticStatus == errSecSuccess, "SecCodeCopyStaticCode failed: \(staticStatus)")
    guard let staticCode else { throw RegressionFailure(message: "Missing static code") }
    var information: CFDictionary?
    let infoStatus = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
    try require(infoStatus == errSecSuccess, "SecCodeCopySigningInformation failed: \(infoStatus)")
    guard let info = information as? [String: Any],
          let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else {
        throw RegressionFailure(message: "Missing embedded entitlements")
    }
    try require(entitlements["com.apple.security.files.bookmarks.app-scope"] as? Bool == true,
                "Missing bookmarks.app-scope entitlement")
    let signatureFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
    try require(signatureFlags & SecCodeSignatureFlags.runtime.rawValue != 0, "Hardened Runtime is not enabled")
}

private func makeGIF(width: Int = 1, height: Int = 1, frameCount: Int = 1) -> Data {
    var data = Data("GIF89a".utf8)
    data.append(contentsOf: [UInt8(width & 0xff), UInt8(width >> 8), UInt8(height & 0xff), UInt8(height >> 8), 0x80, 0, 0])
    data.append(contentsOf: [0, 0, 0, 255, 255, 255])
    for _ in 0..<frameCount {
        data.append(contentsOf: [0x21, 0xf9, 4, 1, 10, 0, 0, 0])
        data.append(contentsOf: [0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 1, 0])
    }
    data.append(0x3b)
    return data
}

private func run(command: String, directory: URL) throws -> [String: Any] {
    try verifySigning()
    try require(try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
                "Fixture directory does not exist")
    let target = directory.appendingPathComponent("bookmark.gif")
    let bookmarkURL = directory.appendingPathComponent("bookmark.data")
    let creatorURL = directory.appendingPathComponent("creator.pid")
    var result: [String: Any] = ["ok": true, "command": command, "pid": getpid(),
                                 "entitlement": true, "hardenedRuntime": true]

    switch command {
    case "create":
        for url in [target, bookmarkURL, creatorURL] {
            try require(!FileManager.default.fileExists(atPath: url.path), "Fixture already exists: \(url.lastPathComponent)")
        }
        let valid = makeGIF()
        _ = try GifResource(data: valid)
        try valid.write(to: target)
        let bookmark = try target.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil, relativeTo: nil)
        try require(!bookmark.isEmpty, "Created an empty bookmark")
        try bookmark.write(to: bookmarkURL)
        try Data(String(getpid()).utf8).write(to: creatorURL)
        result["bookmarkBytes"] = bookmark.count
    case "resolve":
        guard let creatorPID = Int32(try String(contentsOf: creatorURL, encoding: .utf8)) else {
            throw RegressionFailure(message: "Invalid creator PID")
        }
        try require(creatorPID > 0 && creatorPID != getpid(), "Bookmark must be resolved by a different process")
        let bookmark = try Data(contentsOf: bookmarkURL)
        let valid = makeGIF()
        let selected = try GifResource.selectedData(selectedName: nil, appSupport: nil, bookmarkData: bookmark)
        try require(selected == valid, "Resolved bytes differ from the original GIF")
        result["creatorPID"] = creatorPID
        result["validDataMatches"] = true

        let cases: [(String, GifResource.ValidationError, Data)] = [
            ("invalidData", .invalidData, Data("not a GIF".utf8)),
            ("frameCount", .frameCount, makeGIF(frameCount: 501)),
            ("encodedSize", .encodedSize, Data(count: 10 * 1_024 * 1_024 + 1)),
            ("dimensions", .dimensions, makeGIF(width: 2_049)),
            ("totalPixels", .totalPixels, makeGIF(width: 2_048, height: 2_048, frameCount: 17))
        ]
        var rejections: [String] = []
        for (name, expected, data) in cases {
            // 原位写入以保留书签指向的文件；所有读取都经过生产 selectedData。
            try data.write(to: target)
            do {
                _ = try GifResource.selectedData(selectedName: nil, appSupport: nil, bookmarkData: bookmark)
                throw RegressionFailure(message: "\(name) was unexpectedly accepted")
            } catch let error as GifResource.ValidationError {
                try require(error == expected, "\(name) returned \(error) instead of \(expected)")
            }
            rejections.append(name)
        }
        try require(try Data(contentsOf: bookmarkURL) == bookmark, "Bookmark changed during validation")
        try valid.write(to: target)
        try require(try GifResource.selectedData(selectedName: nil, appSupport: nil, bookmarkData: bookmark) == valid,
                    "Original GIF no longer resolves after rejected replacements")
        result["rejections"] = rejections
        result["bookmarkUnchanged"] = true
    default:
        throw RegressionFailure(message: "Usage: BookmarkRegression create|resolve <fixture-directory>")
    }
    return result
}

private func emit(_ result: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    data.append(0x0a)
    FileHandle.standardOutput.write(data)
}

do {
    try require(CommandLine.arguments.count == 3, "Usage: BookmarkRegression create|resolve <fixture-directory>")
    let result = try run(command: CommandLine.arguments[1],
                         directory: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
    try emit(result)
} catch {
    // 即使签名查询或书签 API 出现意外错误，也输出可解析结果并以非零状态结束。
    try? emit(["ok": false, "command": CommandLine.arguments.dropFirst().first ?? "", "pid": getpid(),
               "error": error.localizedDescription])
    exit(EXIT_FAILURE)
}
