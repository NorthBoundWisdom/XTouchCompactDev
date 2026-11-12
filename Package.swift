// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Acquisition is explicit and outside SwiftPM. Even direct Swift invocations validate
// the locked clean materialization; this read-only verification never contacts a remote.
let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let dependencyCheck = Process()
dependencyCheck.executableURL = URL(fileURLWithPath: "/usr/bin/env")
dependencyCheck.arguments = ["python3", repositoryRoot.appendingPathComponent("configs/surface_plugins_dependency.py").path, "verify"]
dependencyCheck.currentDirectoryURL = repositoryRoot
let dependencyOutput = Pipe()
dependencyCheck.standardOutput = dependencyOutput
dependencyCheck.standardError = dependencyOutput
do {
    try dependencyCheck.run()
    dependencyCheck.waitUntilExit()
    if dependencyCheck.terminationStatus != 0 {
        let message = String(decoding: dependencyOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        fatalError(message + "\nRun python3 configs/surface_plugins_dependency.py ensure first.")
    }
} catch { fatalError("Cannot verify locked SurfacePlugins dependency: \(error)") }
let surfacePlugins: Package.Dependency = .package(path: "build/dependencies/SurfacePlugins")

let package = Package(
    name: "XTouchCompactDev",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "XTouchCompactCore", targets: ["XTouchCompactCore"]),
        .executable(name: "XTouchCompactApp", targets: ["XTouchCompactApp"]),
        .executable(name: "XTouchSurfaceSimulator", targets: ["XTouchSurfaceSimulator"])
    ],
    dependencies: [surfacePlugins],
    targets: [
        .target(name: "XTouchCompactCore", dependencies: [.product(name: "SurfaceControlContracts", package: "SurfacePlugins"), .product(name: "SurfacePluginContracts", package: "SurfacePlugins"), .product(name: "AgentPlugin", package: "SurfacePlugins"), .product(name: "RemoteToolContracts", package: "SurfacePlugins"), .product(name: "AgentRemoteBinding", package: "SurfacePlugins"), .product(name: "RobotPlugin", package: "SurfacePlugins"), .product(name: "RobotRemoteBinding", package: "SurfacePlugins"), .product(name: "ChassisPlugin", package: "SurfacePlugins"), .product(name: "ChassisRemoteBinding", package: "SurfacePlugins"), .product(name: "ParameterOutputPlugin", package: "SurfacePlugins"), .product(name: "OutputRemoteBinding", package: "SurfacePlugins"), .product(name: "ExampleParameterSets", package: "SurfacePlugins")]),
        .target(name: "CompactSimulatorTransport"),
        .executableTarget(name: "XTouchSurfaceSimulator", dependencies: ["XTouchCompactCore", "CompactSimulatorTransport"]),
        .target(name: "XTouchCompactLocalization", resources: [.process("Resources")]),
        .executableTarget(name: "XTouchCompactApp", dependencies: ["XTouchCompactCore", "XTouchCompactLocalization"],
                          linkerSettings: [.linkedFramework("CoreMIDI", .when(platforms: [.macOS]))]),
        .testTarget(name: "XTouchCompactCoreTests", dependencies: ["XTouchCompactCore"]),
        .testTarget(name: "XTouchCompactLocalizationTests", dependencies: ["XTouchCompactLocalization"]),
        .testTarget(name: "XTouchCompactAppTests", dependencies: ["XTouchCompactApp", "XTouchCompactLocalization"])
    ],
    swiftLanguageModes: [.v6]
)
