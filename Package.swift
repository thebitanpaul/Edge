// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Edge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "edge", targets: ["edge"]),
        .library(name: "EdgeCore", targets: ["EdgeCore"]),
        // The Control Center controls. Scripts/build.sh wraps this in an .appex inside Edge.app.
        .executable(name: "EdgeControls", targets: ["EdgeControls"]),
    ],
    targets: [
        .target(
            name: "EdgeCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // What the controls show, shared by the app that writes it and the extension that
        // reads it. Foundation only, so it is safe inside an app extension.
        .target(
            name: "EdgeControlState",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "edge",
            dependencies: ["EdgeCore", "EdgeControlState"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "EdgeControls",
            dependencies: ["EdgeControlState"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // An app extension may only use extension-safe API; this has the compiler and
                // linker hold it to that, as Xcode would for an extension target.
                .unsafeFlags(["-application-extension"]),
            ],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-application_extension",
                // The process has to start in the system's extension main, as Xcode arranges
                // for every app extension. It reads the arguments launchd passes an extension
                // and sets up the extension runtime, then calls this target's own entry point.
                // Started straight at that entry point instead, WidgetKit finds no extension
                // runtime and traps before drawing anything — which is a control that never
                // appears in Control Center, with nothing but a crash report to say why.
                "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
            ])]
        ),
        .testTarget(
            name: "EdgeCoreTests",
            dependencies: ["EdgeCore", "EdgeControlState"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
