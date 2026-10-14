// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Email",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "EmailCore"),
        .executableTarget(name: "Email", dependencies: ["EmailCore"]),
        .testTarget(name: "EmailCoreTests", dependencies: ["EmailCore"]),
    ]
)
