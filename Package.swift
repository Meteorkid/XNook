// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "XNook",
    platforms: [.macOS(.v14)],
    targets: [
        // 授权核心逻辑：App 与发码工具共用。
        // 不依赖 AppKit/SwiftUI，便于单元测试与命令行复用。
        .target(
            name: "XNookLicenseCore",
            path: "Sources/XNookLicenseCore"
        ),
        .executableTarget(
            name: "XNook",
            dependencies: ["XNookLicenseCore"],
            path: "Sources/XNook"
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
            name: "LicenseCoreTests",
            dependencies: ["XNookLicenseCore"],
            path: "Tests/LicenseCoreTests"
        )
    ]
)
