import Foundation
import SurfaceControlContracts
import SurfacePluginContracts
import XCTest
@testable import XTouchCompactCore

final class HardwareSharedFixtureTests: XCTestCase {
    func testSharedHardwareFixtureCommonLifecycleAndGap() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shared = root.appendingPathComponent("build/dependencies/SurfacePlugins")
        let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: shared.appendingPathComponent("fixtures/surface-control-hardware-v1.4.json"))) as? [String: Any])
        let mapping = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("examples/surface_hardware/conformance-roles.json"))) as? [String: Any])
        let fixtures = try XCTUnwrap(mapping["fixtures"] as? [String: Any])
        let entry = try XCTUnwrap(fixtures["surface-control-hardware-v1.4"] as? [String: Any])
        let roles = try XCTUnwrap(entry["roles"] as? [String: Any])
        var results: [[String: Any]] = []
        for scene in try XCTUnwrap(document["scenarios"] as? [[String: Any]]) {
            let sceneID = try XCTUnwrap(scene["id"] as? String)
            let steps = try XCTUnwrap(scene["steps"] as? [[String: Any]])
            if sceneID == "unknown_and_observations" {
                // Factory encoders are absolute. Never invent a relative device role or
                // renumber the shared scene's exact sequence assertions after omitting it.
                for index in steps.indices {
                    results.append(["scene": sceneID, "step": index, "status": "skip", "reason": "relative_input absent in factory Standard profile; rich scene exact sequence dependencies cannot be satisfied"])
                }
                continue
            }
            var host = try CompactHardwareSurface(instanceID: "fixture", epoch: "initial", configuration: .init(receiveChannel: 1, lightProtocol: .observed114), hardwareWriterID: "device", remoteWriterID: "remote", eventCapacity: XCTUnwrap(scene["event_capacity"] as? Int))
            try host.transition(epoch: "connected", connected: true, at: 0)
            let initial = host.controls.expected
            for (index, step) in steps.enumerated() {
                let time = try XCTUnwrap(step["at_s"] as? Double)
                let expect = try XCTUnwrap(step["expect"] as? [String: Any])
                let before = try host.controls.snapshot(at: time)
                let role = step["role"] as? String
                let id = role.flatMap { roles[$0] as? String }
                var event: ControlEvent?, page: ControlEventPage?, failure: String?
                do {
                    switch try XCTUnwrap(step["operation"] as? String) {
                    case "snapshot": break
                    case "hardware_input":
                        XCTAssertEqual(id, "b.fader.1")
                        event = try host.receive(.controlChange(channel: 0, number: 28, value: step["value"] as? String == "maximum" ? 127 : 0), disposition: XCTUnwrap(ControlDisposition(rawValue: step["disposition"] as? String ?? "accepted")), reason: step["reason"] as? String, at: time)
                    case "hardware_link": try host.transition(epoch: "transition-\(index)", connected: step["link_state"] as? String == "connected", at: time)
                    case "feedback":
                        let update = try ControlFeedback(expected: host.controls.expected, expectedSequence: host.controls.discovery().latest_sequence, controlID: XCTUnwrap(id), kind: "indicator", value: .string(XCTUnwrap(step["value"] as? String)))
                        let plan = try host.displayPlan(update, allowed: true, at: time)
                        for message in plan {
                            _ = try message.word(configuration: host.configuration)
                        }
                        event = try host.recordFeedback(update, at: time)
                    case "input": try host.controls.validateInput(.init(expected: host.controls.expected, expectedSequence: host.controls.discovery().latest_sequence, controlID: XCTUnwrap(id), encoding: "scalar", value: .number(127)), at: time, writerID: "remote")
                    case "renew": try host.controls.validateRenew(.init(expected: host.controls.expected, controlID: XCTUnwrap(id), holdSeconds: XCTUnwrap(step["hold_s"] as? Double)), at: time)
                    case "reset":
                        var copy = host.controls
                        try copy.reset(expected: host.controls.expected, expectedSequence: host.controls.discovery().latest_sequence, epoch: "forbidden", at: time)
                    case "events": page = try host.controls.events(instanceID: "fixture", epoch: step["expected_scope"] as? String == "initial" ? initial.epoch : host.controls.expected.epoch, afterSequence: step["after_sequence"] as? String ?? "0", at: time)
                    default: XCTFail("Unknown operation")
                    }
                } catch let error as ControlContractError { failure = error.code }
                XCTAssertEqual(failure, expect["error"] as? String, "\(sceneID) / \(index)")
                let after = try host.controls.snapshot(at: time)
                for (key, value) in expect {
                    switch key {
                    case "error": break
                    case "atomic": XCTAssertEqual(before, after)
                    case "unknown_inputs": for role in try XCTUnwrap(value as? [String]) {
                            if let id = roles[role] as? String {
                                XCTAssertNil(after.inputs[id])
                            }
                        }
                    case "sequence": XCTAssertEqual(host.controls.discovery().latest_sequence, value as? String)
                    case "link_state": XCTAssertEqual(after.link?.state.rawValue, value as? String)
                    case "disposition": XCTAssertEqual(event?.disposition.rawValue, value as? String)
                    case "source": XCTAssertEqual(event?.source.rawValue, value as? String)
                    case "origin": XCTAssertEqual(event?.origin.rawValue, value as? String)
                    case "inputs_unchanged": XCTAssertEqual(before.inputs, after.inputs)
                    case "epoch_changed": XCTAssertNotEqual(before.discovery.expected.epoch, after.discovery.expected.epoch)
                    case "event_count": XCTAssertEqual(page?.events.count, value as? Int)
                    default: XCTFail("Unchecked expectation \(key)")
                    }
                }
                results.append(["scene": sceneID, "step": index, "status": "pass"])
            }
        }
        XCTAssertEqual(results.filter { $0["status"] as? String == "pass" }.count, 19)
        XCTAssertEqual(results.filter { $0["status"] as? String == "skip" }.count, 13)
        let output = root.appendingPathComponent("build/e-c/hardware-fixture-report.json")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["source": "hardware", "scope": "inprocess-fake-midi", "pass": 19, "fail": 0, "skip": 13, "steps": results], options: [.prettyPrinted, .sortedKeys]).write(to: output)
    }
}
