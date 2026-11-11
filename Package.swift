// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XTouchCompactDev",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "XTouchCompactCore", targets: ["XTouchCompactCore"]),
        .executable(name: "XTouchCompactApp", targets: ["XTouchCompactApp"])
    ],
    targets: [
        .target(name: "XTouchCompactCore"),
        .target(name: "XTouchCompactLocalization", resources: [.process("Resources")]),
        .executableTarget(name: "XTouchCompactApp", dependencies: ["XTouchCompactCore", "XTouchCompactLocalization"],
                          linkerSettings: [.linkedFramework("CoreMIDI", .when(platforms: [.macOS]))]),
        .testTarget(name: "XTouchCompactCoreTests", dependencies: ["XTouchCompactCore"]),
        .testTarget(name: "XTouchCompactLocalizationTests", dependencies: ["XTouchCompactLocalization"]),
        .testTarget(name: "XTouchCompactAppTests", dependencies: ["XTouchCompactApp", "XTouchCompactLocalization"])
    ],
    swiftLanguageModes: [.v6]
)
