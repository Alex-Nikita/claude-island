// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeIsland",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeIsland",
            path: "Sources/ClaudeIsland"
        ),
        .testTarget(
            name: "ClaudeIslandTests",
            dependencies: ["ClaudeIsland"],
            path: "Tests/ClaudeIslandTests"
        )
    ]
)
