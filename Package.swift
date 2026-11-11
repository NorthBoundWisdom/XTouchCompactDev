// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XTouchCompactDev",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "XTouchCompactCore", targets: ["XTouchCompactCore"]),
        .executable(name: "XTouchCompactApp", targets: ["XTouchCompactApp"])
    ],
    targets: [
        .target(name: "XTouchCompactCore"),
        .executableTarget(name: "XTouchCompactApp", dependencies: ["XTouchCompactCore"],
                          linkerSettings: [.linkedFramework("CoreMIDI", .when(platforms: [.macOS]))]),
        .testTarget(name: "XTouchCompactCoreTests", dependencies: ["XTouchCompactCore"])
    ],
    swiftLanguageModes: [.v6]
)
