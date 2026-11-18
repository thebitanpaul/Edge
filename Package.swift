// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Edge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "edge", targets: ["edge"]),
        .library(name: "EdgeCore", targets: ["EdgeCore"]),
    ],
    targets: [
        .target(
            name: "EdgeCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "edge",
            dependencies: ["EdgeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EdgeCoreTests",
            dependencies: ["EdgeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
