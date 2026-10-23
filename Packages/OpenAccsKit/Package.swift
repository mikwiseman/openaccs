// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenAccsKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OpenAccsCore", targets: ["OpenAccsCore"]),
        .library(name: "ClaudeKit", targets: ["ClaudeKit"]),
        .library(name: "CodexKit", targets: ["CodexKit"]),
        .library(name: "LimitsKit", targets: ["LimitsKit"]),
        .library(name: "SetupKit", targets: ["SetupKit"]),
    ],
    targets: [
        .target(name: "OpenAccsCore"),
        .target(name: "ClaudeKit", dependencies: ["OpenAccsCore"]),
        .target(name: "CodexKit", dependencies: ["OpenAccsCore"]),
        .target(name: "LimitsKit", dependencies: ["OpenAccsCore"]),
        .target(name: "SetupKit", dependencies: ["OpenAccsCore"]),
        .testTarget(name: "OpenAccsCoreTests", dependencies: ["OpenAccsCore"]),
        .testTarget(name: "ClaudeKitTests", dependencies: ["ClaudeKit"]),
        .testTarget(name: "CodexKitTests", dependencies: ["CodexKit"]),
        .testTarget(name: "LimitsKitTests", dependencies: ["LimitsKit"]),
        .testTarget(name: "SetupKitTests", dependencies: ["SetupKit"]),
    ]
)
