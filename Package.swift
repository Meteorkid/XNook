// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "XNook",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "XNook",
            path: "Sources/XNook"
        ),
        .testTarget(
            name: "XNookTests",
            dependencies: ["XNook"],
            path: "Tests/XNookTests"
        )
    ]
)
