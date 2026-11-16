import Foundation

/// Illustrative reference-arm pose from reported software parameter values, never physical telemetry.
public struct ArmPreviewSnapshot: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) {
            self.x = x; self.y = y
        }
    }

    public let joints: [Double]
    public let wristRoll: Double?
    public let toolRoll: Double?
    public let gripper: Double?
    public let speed: Double?
    public let enabled: Bool?

    public init?(configuration: SurfaceConfiguration, values: [String: Double]) {
        let ids = (1 ... 4).map { "arm.j\($0)" }
        guard ids.allSatisfy({ id in
            configuration.parameters.contains(where: { $0.id == id && $0.unit == "°" }) && values[id]?.isFinite == true
        }) else { return nil }
        joints = ids.map { values[$0]! }
        func optional(_ id: String) -> Double? {
            guard configuration.parameters.contains(where: { $0.id == id }), let value = values[id], value.isFinite else { return nil }
            return value
        }
        wristRoll = optional("arm.j5"); toolRoll = optional("arm.j6")
        gripper = optional("arm.gripper"); speed = optional("arm.speed")
        enabled = optional("arm.enabled").map { $0 >= 0.5 }
    }

    public static func radians(_ degrees: Double) -> Double {
        degrees.truncatingRemainder(dividingBy: 360) / 180 * .pi
    }

    public var topDirection: Point {
        .init(x: sin(Self.radians(joints[0])), y: cos(Self.radians(joints[0])))
    }

    public var sidePoints: [Point] {
        var result = [Point(x: 0, y: 0)]
        var angle = 0.0
        for (degrees, length) in zip(joints.dropFirst(), [1.0, 0.85, 0.35]) {
            angle += Self.radians(degrees)
            let previous = result.last!
            result.append(.init(x: previous.x + sin(angle) * length, y: previous.y + cos(angle) * length))
        }
        return result
    }
}

public struct WorkspacePanelSettings: Codable, Equatable, Sendable {
    public var version = 1
    public var enabled: [String] = []
    public init() {}
    public var armVisible: Bool {
        enabled.contains("arm")
    }

    public mutating func setArmVisible(_ visible: Bool) {
        enabled = visible ? ["arm"] : []
    }

    public func validate() throws {
        guard version == 1, Set(enabled).count == enabled.count, enabled.allSatisfy({ $0 == "arm" }) else { throw ParameterError.invalidAssignment }
    }
}
