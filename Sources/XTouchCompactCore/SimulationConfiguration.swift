import Foundation

/// Strict, read-only loading for the standalone simulator. Saved hardware profiles retain
/// their existing Codable compatibility; only this opt-in input rejects unknown keys.
public enum SimulationConfiguration {
    public static let rootKeys: Set<String> = ["version", "device", "parameters", "assignments", "links", "scenes"]
    public static let parameterKeys: Set<String> = ["id", "name", "group", "unit", "minimum", "maximum", "defaultValue", "step", "isSwitch", "agentWritable", "externallyProtected", "color"]
    public static let assignmentKeys: Set<String> = ["control", "layer", "action"]
    public static let linkKeys: Set<String> = ["id", "name", "leader", "members"]
    public static let sceneKeys: Set<String> = ["id", "name", "values"]

    public struct Invalid: Error, CustomStringConvertible {
        public let description: String
        init(_ message: String) {
            description = "simulation configuration: " + message
        }
    }

    private static func object(_ value: Any, allowed: Set<String>, path: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw Invalid("\(path) must be an object") }
        let unknown = Set(object.keys).subtracting(allowed)
        guard unknown.isEmpty else { throw Invalid("unknown fields at \(path): \(unknown.sorted().joined(separator: ", "))") }
        return object
    }

    public static func decode(_ data: Data) throws -> SurfaceConfiguration {
        let root = try object(JSONSerialization.jsonObject(with: data), allowed: rootKeys, path: "root")
        for (name, keys) in [("parameters", parameterKeys), ("assignments", assignmentKeys), ("links", linkKeys), ("scenes", sceneKeys)] {
            guard let value = root[name] else { continue }
            guard let rows = value as? [Any] else { throw Invalid("\(name) must be an array") }
            for (index, row) in rows.enumerated() {
                let path = "\(name)[\(index)]"
                let fields = try object(row, allowed: keys, path: path)
                if name == "assignments" {
                    let action = try object(fields["action"] as Any, allowed: ["parameter"], path: path + ".action")
                    guard action.count == 1, let parameter = action["parameter"] else { throw Invalid("\(path) must bind a parameter") }
                    _ = try object(parameter, allowed: ["_0"], path: path + ".action.parameter")
                    let control = try object(fields["control"] as Any, allowed: ["fader", "faderTouch", "encoder", "encoderPush", "button", "expression", "footswitch"], path: path + ".control")
                    guard control.count == 1, let (kind, payload) = control.first else { throw Invalid("\(path) must identify one control") }
                    _ = try object(payload, allowed: ["expression", "footswitch"].contains(kind) ? [] : ["_0"], path: path + ".control." + kind)
                }
            }
        }
        let configuration = try JSONDecoder().decode(SurfaceConfiguration.self, from: data)
        try configuration.validate()
        for parameter in configuration.parameters {
            guard parameter.agentWritable, parameter.externallyProtected != true else {
                throw Invalid("parameter \(parameter.id) must be writable and unprotected")
            }
        }
        return configuration
    }
}
