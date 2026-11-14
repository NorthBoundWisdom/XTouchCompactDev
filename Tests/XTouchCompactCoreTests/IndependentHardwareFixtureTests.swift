import Foundation
import SurfaceControlContracts
import SurfacePluginContracts
import XCTest
@testable import XTouchCompactCore

final class IndependentHardwareFixtureTests: XCTestCase {
    /// A transport failure belongs to the test adapter, never to the public tool catalog.
    private struct DisplayAdapter {
        var words: [UInt32] = []
        mutating func send(_ messages: [HardwareDisplayMessage], configuration: CompactHardwareConfiguration, reject: Bool) throws {
            if reject {
                throw ControlContractError("test_transport_rejected")
            }
            for message in messages {
                try words.append(message.word(configuration: configuration))
            }
        }
    }

    private func symbolic(_ name: String, control: ControlDescriptor, feedback: Bool = false) throws -> JSONValue {
        if control.encoding == .boolean {
            return .bool(name == "maximum")
        }
        let span = try XCTUnwrap(feedback ? control.feedback_range ?? control.range : control.range)
        return SurfaceControlSession.normalized(.double(name == "maximum" ? span.maximum : span.minimum))
    }

    private func inputMessage(id: String, value: JSONValue) throws -> MIDIMessage {
        switch id {
        case "b.button.1": value == .bool(true) ? .noteOn(channel: 0, number: 71, velocity: 127) : .noteOff(channel: 0, number: 71, velocity: 0)
        case "b.fader.1": try .controlChange(channel: 0, number: 28, value: UInt8(XCTUnwrap(value.exactIntValue)))
        case "b.touch.1": .controlChange(channel: 0, number: 111, value: value == .bool(true) ? 127 : 0)
        default: throw ControlContractError("fixture_role_has_no_input_adapter")
        }
    }

    func testIndependentHardwareButtonTouchAndFeedbackFailures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let filename = "surface-control-hardware-independent-v1.4"
        let fixtureURL = root.appendingPathComponent("build/dependencies/SurfacePlugins/fixtures/\(filename).json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        let roleDocument = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("examples/surface_hardware/conformance-roles.json"))) as? [String: Any])
        let fixtures = try XCTUnwrap(roleDocument["fixtures"] as? [String: Any])
        let mapping = try XCTUnwrap(fixtures[filename] as? [String: Any])
        let roles = try XCTUnwrap(mapping["roles"] as? [String: Any])
        var results: [[String: Any]] = []
        var totalDisplayWords = 0
        for scene in try XCTUnwrap(fixture["scenarios"] as? [[String: Any]]) {
            let sceneID = try XCTUnwrap(scene["id"] as? String)
            let steps = try XCTUnwrap(scene["steps"] as? [[String: Any]])
            let required = try XCTUnwrap(scene["required_roles"] as? [String])
            let missing = required.filter { roles[$0] as? String == nil }
            if !missing.isEmpty {
                XCTAssertEqual(missing, ["button_ignored"], "Only genuinely unsupported ignored-input routing may be skipped")
                for index in steps.indices {
                    results.append(["scene": sceneID, "step": index, "status": "skip", "reason": "No natural ignored-button route in this hardware observation service; button_ignored is null"])
                }
                continue
            }
            var host = try CompactHardwareSurface(instanceID: "fixture", epoch: "initial", configuration: .init(receiveChannel: 1, lightProtocol: .observed114), hardwareWriterID: "device", remoteWriterID: "remote", eventCapacity: XCTUnwrap(scene["event_capacity"] as? Int))
            try host.transition(epoch: "connected", connected: true, at: 0)
            let initial = host.controls.expected
            var display = DisplayAdapter()
            for (index, step) in steps.enumerated() {
                let time = try XCTUnwrap(step["at_s"] as? Double)
                let expect = try XCTUnwrap(step["expect"] as? [String: Any])
                let before = try host.controls.snapshot(at: time)
                let beforeLayer = host.observedLayer
                let beforePage = try host.controls.events(instanceID: "fixture", epoch: host.controls.expected.epoch, afterSequence: "0", at: time)
                let beforeWords = display.words
                let id = (step["role"] as? String).flatMap { roles[$0] as? String }
                let control = id.flatMap { id in host.controls.profile.controls.first { $0.id == id } }
                var event: ControlEvent?, page: ControlEventPage?, failure: String?
                do {
                    switch try XCTUnwrap(step["operation"] as? String) {
                    case "snapshot": break
                    case "hardware_input":
                        let row = try XCTUnwrap(control)
                        let value = try symbolic(XCTUnwrap(step["value"] as? String), control: row)
                        event = try host.receive(inputMessage(id: row.id, value: value), at: time)
                    case "hardware_link": try host.transition(epoch: "transition-\(index)", connected: step["link_state"] as? String == "connected", at: time)
                    case "feedback", "feedback_failure":
                        let row = try XCTUnwrap(control)
                        let kind = try XCTUnwrap(step["feedback_kind"] as? String)
                        let value: JSONValue = if step["invalid_value"] as? String == "nan" {
                            .double(.nan)
                        } else if kind == "indicator" {
                            try .string(XCTUnwrap(step["value"] as? String))
                        } else {
                            try symbolic(XCTUnwrap(step["value"] as? String), control: row, feedback: true)
                        }
                        let update = ControlFeedback(expected: host.controls.expected, expectedSequence: host.controls.discovery().latest_sequence, controlID: row.id, kind: kind, value: value)
                        var candidate = host
                        let messages = try candidate.displayPlan(update, allowed: true, at: time)
                        let accepted = try candidate.recordFeedback(update, at: time)
                        try display.send(messages, configuration: host.configuration, reject: step["operation"] as? String == "feedback_failure")
                        host = candidate; event = accepted
                    case "input":
                        let row = try XCTUnwrap(control)
                        try host.controls.validateInput(.init(expected: host.controls.expected, expectedSequence: host.controls.discovery().latest_sequence, controlID: row.id, encoding: row.encoding.rawValue, value: symbolic(XCTUnwrap(step["value"] as? String), control: row)), at: time, writerID: "remote")
                    case "renew": try host.controls.validateRenew(.init(expected: host.controls.expected, controlID: XCTUnwrap(id), holdSeconds: XCTUnwrap(step["hold_s"] as? Double)), at: time)
                    case "reset":
                        var candidate = host.controls
                        try candidate.reset(expected: host.controls.expected, expectedSequence: host.controls.discovery().latest_sequence, epoch: "forbidden", at: time)
                    case "events": page = try host.controls.events(instanceID: "fixture", epoch: step["expected_scope"] as? String == "initial" ? initial.epoch : host.controls.expected.epoch, afterSequence: step["after_sequence"] as? String ?? "0", at: time)
                    default: XCTFail("Unknown independent fixture operation")
                    }
                } catch let error as ControlContractError { failure = error.code }
                XCTAssertEqual(failure, expect["error"] as? String, "\(sceneID) / \(index)")
                let after = try host.controls.snapshot(at: time)
                for (key, value) in expect {
                    switch key {
                    case "error": break
                    case "atomic":
                        XCTAssertEqual(before, after)
                        XCTAssertEqual(beforeLayer, host.observedLayer)
                        let afterPage = try host.controls.events(instanceID: "fixture", epoch: host.controls.expected.epoch, afterSequence: "0", at: time)
                        XCTAssertEqual(beforePage, afterPage)
                        XCTAssertEqual(beforeWords, display.words)
                    case "unknown_inputs": for role in try XCTUnwrap(value as? [String]) {
                            XCTAssertNil(try after.inputs[XCTUnwrap(roles[role] as? String)])
                        }
                    case "known_inputs": for (role, symbolicValue) in try XCTUnwrap(value as? [String: String]) {
                            let roleID = try XCTUnwrap(roles[role] as? String)
                            let row = try XCTUnwrap(host.controls.profile.controls.first { $0.id == roleID })
                            XCTAssertEqual(after.inputs[roleID], try symbolic(symbolicValue, control: row))
                        }
                    case "sequence": XCTAssertEqual(host.controls.discovery().latest_sequence, value as? String)
                    case "link_state": XCTAssertEqual(after.link?.state.rawValue, value as? String)
                    case "disposition": XCTAssertEqual(event?.disposition.rawValue, value as? String)
                    case "source": XCTAssertEqual(event?.source.rawValue, value as? String)
                    case "origin": XCTAssertEqual(event?.origin.rawValue, value as? String)
                    case "inputs_unchanged": XCTAssertEqual(before.inputs, after.inputs)
                    case "epoch_changed": XCTAssertNotEqual(before.discovery.expected.epoch, after.discovery.expected.epoch)
                    case "event_count": XCTAssertEqual(page?.events.count, value as? Int)
                    default: XCTFail("Unchecked independent fixture expectation \(key)")
                    }
                }
                results.append(["scene": sceneID, "step": index, "status": "pass"])
            }
            totalDisplayWords += display.words.count
        }
        let passed = results.filter { $0["status"] as? String == "pass" }.count
        let skipped = results.filter { $0["status"] as? String == "skip" }.count
        XCTAssertEqual(passed, 28)
        XCTAssertEqual(skipped, 4)
        XCTAssertEqual(totalDisplayWords, 2)
        let report = root.appendingPathComponent("build/e-followup/independent-fixture-report.json")
        try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["source": "hardware", "scope": "inprocess-fake-display", "pass": passed, "fail": 0, "skip": skipped, "display_words": totalDisplayWords, "steps": results], options: [.prettyPrinted, .sortedKeys]).write(to: report)
    }
}
