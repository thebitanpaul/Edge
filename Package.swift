// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Continuous",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "continuous", targets: ["continuous"]),
        .library(name: "ContinuousCore", targets: ["ContinuousCore"]),
    ],
    targets: [
        .target(
            name: "ContinuousCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "continuous",
            dependencies: ["ContinuousCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ContinuousCoreTests",
            dependencies: ["ContinuousCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
