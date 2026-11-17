// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Acquisition is explicit and outside SwiftPM. Even direct Swift invocations validate
// the locked clean materialization; this read-only verification never contacts a remote.
let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
func verifyDependency(_ script: String) {
    let check = Process()
    check.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    check.arguments = ["python3", repositoryRoot.appendingPathComponent("configs/" + script).path, "verify"]
    check.currentDirectoryURL = repositoryRoot
    let output = Pipe(); check.standardOutput = output; check.standardError = output
    do {
        try check.run(); check.waitUntilExit()
        guard check.terminationStatus == 0 else {
            fatalError(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) + "\nRun python3 configs/" + script + " ensure first.")
        }
    } catch { fatalError("Cannot verify locked dependency: \(error)") }
}
verifyDependency("surface_plugins_dependency.py")
verifyDependency("control_surface_kit_dependency.py")
let surfacePlugins: Package.Dependency = .package(path: "build/dependencies/SurfacePlugins")
let controlSurfaceKit: Package.Dependency = .package(path: "build/dependencies/ControlSurfaceKit")

#if os(macOS)
let hardwareProducts: [Product] = [.executable(name: "XTouchSurfaceHardware", targets: ["XTouchSurfaceHardware"])]
let hardwareTargets: [Target] = [
    .executableTarget(name: "XTouchSurfaceHardware", dependencies: ["XTouchCompactCore", "CompactSimulatorTransport", .product(name: "SurfaceDeviceContracts", package: "ControlSurfaceKit"), .product(name: "SurfaceFeedbackPlanning", package: "ControlSurfaceKit")], linkerSettings: [.linkedFramework("CoreMIDI")]),
    .testTarget(name: "XTouchSurfaceHardwareTests", dependencies: ["XTouchSurfaceHardware", "XTouchCompactCore"]),
]
#else
let hardwareProducts: [Product] = []
let hardwareTargets: [Target] = []
#endif

let package = Package(
    name: "XTouchCompactDev",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "XTouchCompactCore", targets: ["XTouchCompactCore"]),
        .executable(name: "XTouchCompactApp", targets: ["XTouchCompactApp"]),
        .executable(name: "XTouchSurfaceSimulator", targets: ["XTouchSurfaceSimulator"]),
        .executable(name: "XTouchRemoteMIDI", targets: ["XTouchRemoteMIDI"]),
    ] + hardwareProducts,
    dependencies: [surfacePlugins, controlSurfaceKit],
    targets: [
        .target(name: "XTouchCompactCore", dependencies: [.product(name: "SurfaceFeedbackPlanning", package: "ControlSurfaceKit"), .product(name: "SurfaceDeviceContracts", package: "ControlSurfaceKit"), .product(name: "SurfaceBindingContext", package: "ControlSurfaceKit"), .product(name: "SurfaceControlContracts", package: "SurfacePlugins"), .product(name: "SurfacePluginContracts", package: "SurfacePlugins"), .product(name: "AgentPlugin", package: "SurfacePlugins"), .product(name: "RemoteToolContracts", package: "SurfacePlugins"), .product(name: "AgentRemoteBinding", package: "SurfacePlugins"), .product(name: "RobotPlugin", package: "SurfacePlugins"), .product(name: "RobotRemoteBinding", package: "SurfacePlugins"), .product(name: "ChassisPlugin", package: "SurfacePlugins"), .product(name: "ChassisRemoteBinding", package: "SurfacePlugins"), .product(name: "ParameterOutputPlugin", package: "SurfacePlugins"), .product(name: "OutputRemoteBinding", package: "SurfacePlugins"), .product(name: "ExampleParameterSets", package: "SurfacePlugins")]),
        .target(name: "CompactSimulatorTransport"),
        .target(name: "CompactRemoteMIDI"),
        .executableTarget(name: "XTouchRemoteMIDI", dependencies: ["CompactRemoteMIDI"],
                          linkerSettings: [.linkedFramework("CoreMIDI", .when(platforms: [.macOS]))]),
        .executableTarget(name: "XTouchSurfaceSimulator", dependencies: ["XTouchCompactCore", "CompactSimulatorTransport"]),
        .target(name: "XTouchCompactLocalization", resources: [.process("Resources")]),
        .executableTarget(name: "XTouchCompactApp", dependencies: ["XTouchCompactCore", "XTouchCompactLocalization", "CompactRemoteMIDI", .product(name: "SurfaceFeedbackPlanning", package: "ControlSurfaceKit"), .product(name: "SurfaceDeviceContracts", package: "ControlSurfaceKit"), .product(name: "SurfaceConnectionState", package: "ControlSurfaceKit")],
                          linkerSettings: [.linkedFramework("CoreMIDI", .when(platforms: [.macOS]))]),
        .testTarget(name: "XTouchCompactCoreTests", dependencies: ["XTouchCompactCore", .product(name: "SurfaceFeedbackPlanning", package: "ControlSurfaceKit"), .product(name: "SurfaceDeviceContracts", package: "ControlSurfaceKit"), .product(name: "SurfaceBindingContext", package: "ControlSurfaceKit"), .product(name: "SurfaceConnectionState", package: "ControlSurfaceKit"), .product(name: "SurfaceDeviceConformance", package: "ControlSurfaceKit")]),
        .testTarget(name: "CompactRemoteMIDITests", dependencies: ["CompactRemoteMIDI"]),
        .testTarget(name: "XTouchCompactLocalizationTests", dependencies: ["XTouchCompactLocalization"]),
        .testTarget(name: "XTouchCompactAppTests", dependencies: ["XTouchCompactApp", "XTouchCompactLocalization", .product(name: "SurfaceFeedbackPlanning", package: "ControlSurfaceKit"), .product(name: "SurfaceDeviceContracts", package: "ControlSurfaceKit"), .product(name: "SurfaceBindingContext", package: "ControlSurfaceKit"), .product(name: "SurfaceConnectionState", package: "ControlSurfaceKit"), .product(name: "SurfaceDeviceConformance", package: "ControlSurfaceKit")]),
    ] + hardwareTargets,
    swiftLanguageModes: [.v6]
)
