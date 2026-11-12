import Foundation
import Testing
import SurfaceControlContracts
import SurfacePluginContracts
@testable import XTouchCompactCore

private enum ScenarioFailure: Error { case assertion(String) }
private func requireScenario(_ value: Bool, _ message: String) throws {
    guard value else { throw ScenarioFailure.assertion(message) }
}
private func commandOutput(_ args: [String], root: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = args
    process.currentDirectoryURL = root
    let pipe = Pipe(); process.standardOutput = pipe
    try process.run(); process.waitUntilExit()
    try requireScenario(process.terminationStatus == 0, "metadata command failed")
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
private let scenarioRoles = ["input_a": "simulation.arm", "input_b": "simulation.start", "input_c": "simulation.pause", "input_d": "simulation.cancel",
    "feedback_state": "simulation.state", "feedback_progress": "simulation.progress", "feedback_link": "simulation.link"]

private func scenarioFingerprint(_ simulator: CompactSurfaceSimulator, at time: Double) throws -> JSONValue {
    let snapshot = try simulator.controls.snapshot(at: time)
    let cursor = UInt64(snapshot.latest_sequence)!
    let first = cursor > UInt64(simulator.controls.eventCapacity) ? cursor - UInt64(simulator.controls.eventCapacity) : 0
    let page = try simulator.controls.events(instanceID: simulator.controls.expected.instance_id, epoch: simulator.controls.expected.epoch,
        afterSequence: String(first), limit: 1024, at: time)
    return .object(["expected": try .encoded(simulator.controls.expected), "sequence": .string(snapshot.latest_sequence),
        "inputs": .object(snapshot.inputs), "feedback": try .encoded(snapshot.feedback), "journal": try .encoded(page.events),
        "parameters": try .encoded(simulator.session.parameters.values), "layer": .string(simulator.session.state.layer.rawValue),
        "faders": try .encoded(simulator.mock.faders), "encoders": try .encoded(simulator.mock.encoders),
        "touches": try .encoded(simulator.mock.touchedFaders.sorted()), "buttons": .array(simulator.mock.buttons.map { .number(Int($0.rawValue)) }),
        "pressed": try .encoded(simulator.mock.pressedButtons.sorted()), "pushed": try .encoded(simulator.mock.pushedEncoders.sorted()),
        "rings": .array(simulator.mock.rings.map { .string(String(describing: $0)) }),
        "pending": .array((1 ... 9).map { .bool(simulator.session.state.isMotorPending($0)) })])
}

@Test func sharedVersionedFixtureDrivesRealXTouchMockAndSession() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = root.appendingPathComponent("build/dependencies/SurfacePlugins/fixtures/surface-control-software-v1.json")
    let document = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixture))
    let scenarios = try #require(document.value(for: "scenarios")?.arrayValue)
    var results: [JSONValue] = []
    var roles: [String: String] = [:]
    for scenario in scenarios {
        let name = try #require(scenario.value(for: "id")?.stringValue)
        let capacity = try #require(scenario.value(for: "event_capacity")?.exactIntValue)
        let names = scenario.value(for: "instances")?.arrayValue?.compactMap(\.stringValue) ?? ["a"]
        var hosts = try Dictionary(uniqueKeysWithValues: names.map { ($0, try CompactSurfaceSimulator(instanceID: "fixture.\($0)", epoch: "\(name).\($0).initial", eventCapacity: capacity)) })
        var initial = hosts.mapValues { $0.controls.expected }
        var lastInput: [String: ControlInput] = [:]
        var accepted = Dictionary(uniqueKeysWithValues: names.map { ($0, 0) })
        let steps = try #require(scenario.value(for: "steps")?.arrayValue)
        for (index, step) in steps.enumerated() {
            let selected = step.value(for: "instance")?.stringValue ?? "a"
            var host = hosts[selected]!
            let scheduled = try #require(step.value(for: "at_s")?.finiteNumber)
            let time = step.value(for: "clock_override_s")?.finiteNumber ?? scheduled
            let operation = try #require(step.value(for: "operation")?.stringValue)
            let expected = try #require(step.value(for: "expect")?.objectValue)
            let before = try scenarioFingerprint(host, at: scheduled)
            let beforeInputs = try host.controls.snapshot(at: scheduled).inputs
            let beforeEpoch = host.controls.expected.epoch
            let beforeInstance = host.controls.expected.instance_id
            let countBefore = accepted[selected]!
            var actualError: String?
            var event: ControlEvent?
            var page: ControlEventPage?
            do {
                switch operation {
                case "snapshot": break
                case "input", "feedback":
                    let role = try #require(step.value(for: "role")?.stringValue)
                    let mappedID = scenarioRoles[role]!
                    let control = try #require(host.controls.profile.controls.first { $0.mapping?.id == mappedID })
                    roles[role] = control.id
                    let suppliedExpected = step.value(for: "expected_scope") == .string("initial") ? initial[selected]! : host.controls.expected
                    let range = operation == "feedback" ? (control.feedback_range ?? control.range) : control.range
                    let value: JSONValue
                    if step.value(for: "invalid_value") == .string("nan") { value = .double(.nan) }
                    else if step.value(for: "value") == .string("maximum") { value = .number(Int(range!.maximum)) }
                    else if step.value(for: "value") == .string("minimum") { value = .number(Int(range!.minimum)) }
                    else { value = step.value(for: "value")! }
                    if operation == "input" {
                        let request = ControlInput(expected: suppliedExpected, expectedSequence: host.controls.discovery().latest_sequence,
                            controlID: control.id, encoding: step.value(for: "encoding")?.stringValue ?? control.encoding.rawValue, value: value)
                        lastInput[selected] = request
                        event = try host.input(request, at: time)
                    } else {
                        let kind = document.value(for: "roles")!.value(for: role)!.value(for: "feedback_kind")!.stringValue!
                        event = try host.feedback(.init(expected: suppliedExpected, expectedSequence: host.controls.discovery().latest_sequence,
                            controlID: control.id, kind: kind, value: value), at: time)
                    }
                case "replay_last_write": event = try host.input(lastInput[selected]!, at: time)
                case "reset":
                    try host.reset(epoch: "\(name).\(selected).reset.\(index)", at: time)
                    accepted[selected] = 0
                case "restart":
                    host = try CompactSurfaceSimulator(instanceID: "fixture.\(selected).replacement", epoch: "\(name).\(selected).restart.\(index)", eventCapacity: capacity)
                    accepted[selected] = 0
                case "events":
                    page = try host.controls.events(instanceID: host.controls.expected.instance_id, epoch: host.controls.expected.epoch,
                        afterSequence: step.value(for: "after_sequence")!.stringValue!, limit: 1024, at: time)
                default: throw ScenarioFailure.assertion("unsupported operation")
                }
            } catch let error as ControlContractError { actualError = error.code }
            if event?.kind == .input, event?.disposition == .accepted { accepted[selected]! += 1 }
            let snapshot = try host.controls.snapshot(at: scheduled)
            let after = try scenarioFingerprint(host, at: scheduled)
            var checks: [Bool] = [actualError == expected["error"]?.stringValue]
            if let disposition = expected["disposition"]?.stringValue { checks.append(event?.disposition.rawValue == disposition) }
            if expected["atomic"] == .bool(true) { checks.append(before == after) }
            if expected["inputs_unchanged"] == .bool(true) { checks.append(beforeInputs == snapshot.inputs) }
            if expected["epoch_changed"] == .bool(true) { checks.append(beforeEpoch != host.controls.expected.epoch) }
            if expected["instance_changed"] == .bool(true) { checks.append(beforeInstance != host.controls.expected.instance_id) }
            if let sequence = expected["sequence"]?.stringValue { checks.append(snapshot.latest_sequence == sequence) }
            if let count = expected["accepted_input_count"]?.exactIntValue { checks.append(accepted[selected] == count) }
            if let delta = expected["accepted_input_delta"]?.exactIntValue { checks.append(accepted[selected]! - countBefore == delta) }
            if let count = expected["event_count"]?.exactIntValue { checks.append(page?.events.count == count) }
            if let latest = expected["latest_sequence"]?.stringValue { checks.append(page?.latest_sequence == latest) }
            if let known = expected["known_inputs"]?.objectValue {
                for (role, endpoint) in known {
                    let control = host.controls.profile.controls.first { $0.mapping?.id == scenarioRoles[role] }!
                    let value = endpoint == .string("minimum") ? control.range!.minimum : control.range!.maximum
                    checks.append(snapshot.inputs[control.id]?.finiteNumber == value)
                }
            }
            let passed = checks.allSatisfy { $0 }
            results.append(.object(["scenario": .string(name), "step": .number(index), "operation": .string(operation),
                "status": .string(passed ? "pass" : "fail"), "actual_error": actualError.map(JSONValue.string) ?? .null,
                "disposition": event.map { .string($0.disposition.rawValue) } ?? .null, "accepted_input_count": .number(accepted[selected]!),
                "sequence": .string(snapshot.latest_sequence), "epoch_changed": .bool(beforeEpoch != host.controls.expected.epoch)]))
            hosts[selected] = host
            #expect(passed, "scenario \(name) step \(index) failed: \(actualError ?? "no error")")
        }
        // Retain initial identity for stale-request checks; it is never auto-refreshed.
        initial.removeAll()
    }
    let hash = try commandOutput(["python3", "-c", "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())", fixture.path], root: root)
    let sharedLock = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("configs/surface_plugins.lock.json")))
    let report: JSONValue = .object(["fixture": document.value(for: "scenario_id")!, "fixture_sha256": .string(hash), "source": .string("simulation"),
        "host_revision": .string(try commandOutput(["git", "rev-parse", "HEAD"], root: root)),
        "host_dirty": .bool(!(try commandOutput(["git", "status", "--porcelain"], root: root)).isEmpty),
        "shared_revision": sharedLock.value(for: "revision")!, "profile_id": .string(CompactSurfaceSimulator.profileID),
        "profile_version": .string(CompactSurfaceSimulator.profileVersion), "roles": try .encoded(roles), "scope": .string("inprocess_real_mock_session"),
        "steps": .array(results), "pass": .bool(results.allSatisfy { $0.value(for: "status") == .string("pass") })])
    try JSONEncoder().encode(report).write(to: root.appendingPathComponent("build/surface-scenario-report.json"))
    #expect(results.count == 40)
}
