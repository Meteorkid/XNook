// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "XNook",
    platforms: [.macOS(.v14)],
    products: [
        // 动态库：由 /usr/bin/perl 通过 DynaLoader 加载，用于读写系统 MediaRemote。
        // Apple 平台签名的 perl 具备 ad-hoc 签名 app 不具备的 MediaRemote 访问权。
        .library(name: "CMediaRemote", type: .dynamic, targets: ["CMediaRemote"]),
    ],
    targets: [
        // MediaRemote C 桥接（BSD 3-Clause，见 Sources/CMediaRemote/LICENSE）。
        .target(
            name: "CMediaRemote",
            path: "Sources/CMediaRemote",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [
                .unsafeFlags(["-framework", "Foundation"]),
                .unsafeFlags(["-framework", "AppKit"]),
            ]
        ),
        // 远端主线授权核心：App 运行时使用，经 1.3.26–1.3.30 正式发布验证。
        .target(name: "MeteorLicenseCore", path: "Sources/MeteorLicenseCore"),
        // 本地授权核心：仅供 licensegen 发码工具使用，不参与 App 运行时。
        .target(
            name: "XNookLicenseCore",
            path: "Sources/XNookLicenseCore"
        ),
        .executableTarget(
            name: "XNook",
            dependencies: ["MeteorLicenseCore", "CMediaRemote"],
            path: "Sources/XNook",
            resources: [
                .copy("Resources/MediaRemoteBridge/run.pl")
            ]
        ),
        // 发码工具：持有私钥，仅作者本人使用，不随 App 分发。
        .executableTarget(
            name: "licensegen",
            dependencies: ["XNookLicenseCore"],
            path: "Sources/LicenseGen"
        ),
        .testTarget(
            name: "XNookTests",
            dependencies: ["XNook"],
            path: "Tests/XNookTests"
        ),
        .testTarget(
            name: "MeteorLicenseCoreTests",
            dependencies: ["MeteorLicenseCore"],
            path: "Tests/MeteorLicenseCoreTests"
        ),
        .testTarget(
            name: "LicenseCoreTests",
            dependencies: ["XNookLicenseCore"],
            path: "Tests/LicenseCoreTests"
        )
    ]
)
