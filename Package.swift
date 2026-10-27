// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "XNook",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MeteorLicenseCore", path: "Sources/MeteorLicenseCore"),
        .executableTarget(
            name: "XNook",
            dependencies: ["MeteorLicenseCore"],
            path: "Sources/XNook"
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
        )
    ]
)
