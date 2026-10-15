// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Email",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")],
    targets: [
        .target(name: "EmailCore"),
        .executableTarget(name: "Email", dependencies: ["EmailCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "EmailCoreTests", dependencies: ["EmailCore"]),
        .testTarget(name: "EmailTests", dependencies: ["Email"]),
    ]
)
