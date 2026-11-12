import Foundation
import SurfaceControlContracts
import SurfacePluginContracts
import Testing
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

/// The contract 1.1 `hold_input` role: the first lease-bearing control (fader touch on layer A).
private func holdControl(_ simulator: CompactSurfaceSimulator) -> ControlDescriptor? {
    simulator.controls.profile.controls.first { $0.hold != nil }
}

private func roleControl(_ simulator: CompactSurfaceSimulator, _ role: String) -> ControlDescriptor? {
    if role == "hold_input" {
        return holdControl(simulator)
    }
    if role == "blocked_input" {
        return simulator.controls.profile.controls.first { $0.accepts_input == false }
    }
    return simulator.controls.profile.controls.first { $0.mapping?.id == scenarioRoles[role] }
}

/// Control IDs for a fixture list of role names; unknown roles fail the step.
private func roleIDs(_ simulator: CompactSurfaceSimulator, _ names: [JSONValue]) throws -> [String] {
    try names.map { name in
        guard let role = name.stringValue, let id = roleControl(simulator, role)?.id else { throw ScenarioFailure.assertion("unknown role") }
        return id
    }
}

/// A time at which state can be read without processing a due lease: an atomicity probe must
/// not itself change the host. With a pending lease it is just before the earliest deadline.
private func probeTime(_ simulator: CompactSurfaceSimulator, _ time: Double) -> Double {
    simulator.nextHoldDeadline.map { $0 <= time ? $0.nextDown : time } ?? time
}

private func scenarioFingerprint(_ simulator: CompactSurfaceSimulator, at requested: Double) throws -> JSONValue {
    let time = probeTime(simulator, requested)
    let snapshot = try simulator.controls.snapshot(at: time)
    let cursor = UInt64(snapshot.latest_sequence)!
    let first = cursor > UInt64(simulator.controls.eventCapacity) ? cursor - UInt64(simulator.controls.eventCapacity) : 0
    let page = try simulator.controls.events(instanceID: simulator.controls.expected.instance_id, epoch: simulator.controls.expected.epoch,
                                             afterSequence: String(first), limit: 1024, at: time)
    return try .object(["expected": .encoded(simulator.controls.expected), "sequence": .string(snapshot.latest_sequence),
                        "inputs": .object(snapshot.inputs), "feedback": .encoded(snapshot.feedback), "journal": .encoded(page.events),
                        "parameters": .encoded(simulator.session.parameters.values), "layer": .string(simulator.session.state.layer.rawValue),
                        "faders": .encoded(simulator.mock.faders), "encoders": .encoded(simulator.mock.encoders),
                        "touches": .encoded(simulator.mock.touchedFaders.sorted()), "buttons": .array(simulator.mock.buttons.map { .number(Int($0.rawValue)) }),
                        "pressed": .encoded(simulator.mock.pressedButtons.sorted()), "pushed": .encoded(simulator.mock.pushedEncoders.sorted()),
                        "rings": .array(simulator.mock.rings.map { .string(String(describing: $0)) }),
                        "pending": .array((1 ... 9).map { .bool(simulator.session.state.isMotorPending($0)) }),
                        "holds": .encoded(snapshot.holds ?? [:])])
}

@Test func sharedVersionedFixtureDrivesRealXTouchMockAndSession() throws {
    try runSharedFixture("surface-control-software-v1.json", report: "surface-scenario-report.json", steps: 40)
}

@Test func sharedContract11FixtureDrivesLeasesThroughRealXTouchMockAndSession() throws {
    try runSharedFixture("surface-control-software-v1.1.json", report: "surface-scenario-report-v1.1.json", steps: 65)
}

@Test func sharedContract12FixtureDrivesUnsequencedFeedbackHoldsAndDeclaredInput() throws {
    try runSharedFixture("surface-control-software-v1.2.json", report: "surface-scenario-report-v1.2.json", steps: 83)
}

private func runSharedFixture(_ fixtureName: String, report reportName: String, steps expectedSteps: Int) throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = root.appendingPathComponent("build/dependencies/SurfacePlugins/fixtures/\(fixtureName)")
    let document = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixture))
    let scenarios = try #require(document.value(for: "scenarios")?.arrayValue)
    var results: [JSONValue] = []
    var roles: [String: String] = [:]
    var scenarioMappings: [String: JSONValue] = [:]
    for scenario in scenarios {
        let name = try #require(scenario.value(for: "id")?.stringValue)
        let capacity = try #require(scenario.value(for: "event_capacity")?.exactIntValue)
        let names = scenario.value(for: "instances")?.arrayValue?.compactMap(\.stringValue) ?? ["a"]
        // Only the v1.2 blocked-control scenario has a test-only action binding.
        // The default demonstration profile and the old fixtures remain unchanged.
        var configuration = CompactSurfaceSimulator.demonstrationConfiguration
        if fixtureName == "surface-control-software-v1.2.json", name == "declared_read_only_control" {
            configuration.assignments.append(.init(control: .button(39), layer: .a, action: .set("simulation.arm", 100)))
        }
        scenarioMappings[name] = .object(["mapping_revision": .string(CompactSurfaceSimulator.profile(configuration: configuration).mappingRevision),
                                          "test_only_blocked_binding": .bool(name == "declared_read_only_control")])
        var sequences = Dictionary(uniqueKeysWithValues: names.map { ($0, "0") })
        var hosts = try Dictionary(uniqueKeysWithValues: names.map { try ($0, CompactSurfaceSimulator(instanceID: "fixture.\($0)", epoch: "\(name).\($0).initial", configuration: configuration, eventCapacity: capacity)) })
        var initial = hosts.mapValues { $0.controls.expected }
        var lastInput: [String: ControlInput] = [:]
        var accepted = Dictionary(uniqueKeysWithValues: names.map { ($0, 0) })
        let steps = try #require(scenario.value(for: "steps")?.arrayValue)
        for (index, step) in steps.enumerated() {
            let selected = step.value(for: "instance")?.stringValue ?? "a"
            var host = try #require(hosts[selected])
            let scheduled = try #require(step.value(for: "at_s")?.finiteNumber)
            let time = step.value(for: "clock_override_s")?.finiteNumber ?? scheduled
            let operation = try #require(step.value(for: "operation")?.stringValue)
            let expected = try #require(step.value(for: "expect")?.objectValue)
            let before = try scenarioFingerprint(host, at: scheduled)
            let beforeInputs = try host.controls.snapshot(at: probeTime(host, scheduled)).inputs
            let beforeEpoch = host.controls.expected.epoch
            let beforeInstance = host.controls.expected.instance_id
            let countBefore = try #require(accepted[selected])
            var actualError: String?
            var event: ControlEvent?
            var page: ControlEventPage?
            var renewed: ControlRenewResult?
            var expired: [ControlEvent] = []
            do {
                switch operation {
                case "snapshot", "refresh_sequence":
                    // The real read at the step time: fails closed while a lease is due.
                    sequences[selected] = try host.controls.snapshot(at: time).latest_sequence
                case "input", "feedback":
                    let role = try #require(step.value(for: "role")?.stringValue)
                    let control = try #require(roleControl(host, role))
                    roles[role] = control.id
                    let suppliedExpected = step.value(for: "expected_scope") == .string("initial") ? initial[selected]! : host.controls.expected
                    let range = operation == "feedback" ? (control.feedback_range ?? control.range) : control.range
                    let value: JSONValue = if step.value(for: "invalid_value") == .string("nan") {
                        .double(.nan)
                    } else if step.value(for: "value") == .string("maximum") {
                        try .number(Int(#require(range?.maximum)))
                    } else if step.value(for: "value") == .string("minimum") {
                        range.map { .number(Int($0.minimum)) } ?? .bool(false)
                    } else if step.value(for: "value") == .string("rest") {
                        try #require(control.hold?.rest_value)
                    } else if step.value(for: "value") == .string("active") {
                        // One admissible non-rest value: true for a button lease.
                        try #require(control.hold?.rest_value == .bool(false) ? JSONValue.bool(true) : nil)
                    } else {
                        try #require(step.value(for: "value"))
                    }
                    if operation == "input" {
                        let request = ControlInput(expected: suppliedExpected, expectedSequence: step.value(for: "expected_sequence")?.stringValue ?? sequences[selected]!,
                                                   controlID: control.id, encoding: step.value(for: "encoding")?.stringValue ?? control.encoding.rawValue, value: value,
                                                   holdSeconds: step.value(for: "hold_s")?.finiteNumber)
                        lastInput[selected] = request
                        event = try host.input(request, at: time)
                    } else {
                        let kind = try #require(document.value(for: "roles")?.value(for: role)?.value(for: "feedback_kind")?.stringValue)
                        event = try host.feedback(.init(expected: suppliedExpected, expectedSequence: step.value(for: "omit_sequence") == .bool(true) ? nil : (step.value(for: "expected_sequence")?.stringValue ?? sequences[selected]!),
                                                        controlID: control.id, kind: kind, value: value), at: time)
                    }
                case "replay_last_write": event = try host.input(#require(lastInput[selected]), at: time)
                case "renew":
                    let role = try #require(step.value(for: "role")?.stringValue)
                    let control = try #require(roleControl(host, role))
                    roles[role] = control.id
                    renewed = try host.renew(.init(expected: host.controls.expected, controlID: control.id,
                                                   holdSeconds: #require(step.value(for: "hold_s")?.finiteNumber)), at: time)
                case "advance":
                    // Exactly what the executable's scheduler does on its own clock.
                    expired = try host.processHoldExpiries(at: time)
                    sequences[selected] = host.controls.discovery().latest_sequence
                case "reset":
                    try host.reset(epoch: "\(name).\(selected).reset.\(index)", at: time)
                    accepted[selected] = 0
                    sequences[selected] = "0"
                case "restart":
                    host = try CompactSurfaceSimulator(instanceID: "fixture.\(selected).replacement", epoch: "\(name).\(selected).restart.\(index)", configuration: configuration, eventCapacity: capacity)
                    accepted[selected] = 0
                    sequences[selected] = "0"
                case "events":
                    page = try host.controls.events(instanceID: host.controls.expected.instance_id, epoch: host.controls.expected.epoch,
                                                    afterSequence: #require(step.value(for: "after_sequence")?.stringValue), limit: 1024, at: time)
                default: throw ScenarioFailure.assertion("unsupported operation")
                }
            } catch let error as ControlContractError { actualError = error.code }
            if let event, step.value(for: "omit_sequence") != .bool(true) {
                sequences[selected] = event.sequence
            }
            if event?.kind == .input, event?.disposition == .accepted {
                accepted[selected, default: 0] += 1
            }
            accepted[selected, default: 0] += expired.count(where: { $0.kind == .input && $0.disposition == .accepted })
            let snapshot = try host.controls.snapshot(at: probeTime(host, scheduled))
            let after = try scenarioFingerprint(host, at: scheduled)
            var checks: [Bool] = [actualError == expected["error"]?.stringValue]
            if let disposition = expected["disposition"]?.stringValue {
                checks.append(event?.disposition.rawValue == disposition)
            }
            if expected["atomic"] == .bool(true) {
                checks.append(before == after)
            }
            if expected["inputs_unchanged"] == .bool(true) {
                checks.append(beforeInputs == snapshot.inputs)
            }
            if expected["epoch_changed"] == .bool(true) {
                checks.append(beforeEpoch != host.controls.expected.epoch)
            }
            if expected["instance_changed"] == .bool(true) {
                checks.append(beforeInstance != host.controls.expected.instance_id)
            }
            if let sequence = expected["sequence"]?.stringValue {
                checks.append(snapshot.latest_sequence == sequence)
            }
            if let count = expected["accepted_input_count"]?.exactIntValue {
                checks.append(accepted[selected] == count)
            }
            if let delta = expected["accepted_input_delta"]?.exactIntValue {
                try checks.append(#require(accepted[selected]) - countBefore == delta)
            }
            if let count = expected["event_count"]?.exactIntValue {
                checks.append(page?.events.count == count)
            }
            if let latest = expected["latest_sequence"]?.stringValue {
                checks.append((page?.latest_sequence ?? snapshot.latest_sequence) == latest)
            }
            if let known = expected["known_inputs"]?.objectValue {
                for (role, endpoint) in known {
                    let control = try #require(roleControl(host, role))
                    switch endpoint {
                    case .string("rest"): checks.append(snapshot.inputs[control.id] == control.hold?.rest_value)
                    case .string("active"): checks.append(snapshot.inputs[control.id] != nil && snapshot.inputs[control.id] != control.hold?.rest_value)
                    default:
                        let value = endpoint == .string("minimum") ? control.range!.minimum : control.range!.maximum
                        checks.append(snapshot.inputs[control.id]?.finiteNumber == value)
                    }
                }
            }
            if let deadline = expected["hold_deadline_at_s"]?.finiteNumber {
                let initialTime = document.value(for: "initial_time_s")?.finiteNumber ?? 0
                let actual = renewed?.hold_deadline ?? event?.hold_deadline
                checks.append(actual.map { abs($0 - (initialTime + deadline)) < 1e-9 } ?? false)
            }
            if let held = expected["holds"]?.arrayValue {
                let wanted = try Set(roleIDs(host, held))
                let actualHolds = operation == "events" ? (page?.holds ?? [:]) : (snapshot.holds ?? [:])
                checks.append(Set(actualHolds.keys) == wanted)
            }
            if let deadlines = expected["hold_deadlines_at_s"]?.objectValue {
                let actualHolds = operation == "events" ? (page?.holds ?? [:]) : (snapshot.holds ?? [:])
                var wanted: [String: Double] = [:]
                for (role, deadline) in deadlines {
                    let control = try #require(roleControl(host, role))
                    guard let time = deadline.finiteNumber else { throw ScenarioFailure.assertion("invalid hold deadline") }
                    wanted[control.id] = time
                }
                checks.append(actualHolds == wanted)
            }
            if let roleNames = expected["expired"]?.arrayValue {
                let wanted = try roleIDs(host, roleNames)
                checks.append(expired.map(\.control_id) == wanted && expired.allSatisfy { $0.reason == "hold_expired" && $0.origin == .remote })
            }
            if let reasons = expected["event_reasons"]?.arrayValue {
                checks.append(page?.events.map { $0.reason.map(JSONValue.string) ?? .null } == reasons)
            }
            let passed = checks.allSatisfy(\.self)
            try results.append(.object(["scenario": .string(name), "step": .number(index), "operation": .string(operation),
                                        "status": .string(passed ? "pass" : "fail"), "actual_error": actualError.map(JSONValue.string) ?? .null,
                                        "disposition": event.map { .string($0.disposition.rawValue) } ?? .null, "accepted_input_count": .number(#require(accepted[selected])),
                                        "sequence": .string(snapshot.latest_sequence), "epoch_changed": .bool(beforeEpoch != host.controls.expected.epoch),
                                        "hold_deadline": (renewed?.hold_deadline ?? event?.hold_deadline).map(JSONValue.double) ?? .null,
                                        "expired": .array(expired.map { .string($0.control_id) })]))
            hosts[selected] = host
            #expect(passed, "scenario \(name) step \(index) failed: \(actualError ?? "no error")")
        }
        // Retain initial identity for stale-request checks; it is never auto-refreshed.
        initial.removeAll()
    }
    let hash = try commandOutput(["python3", "-c", "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())", fixture.path], root: root)
    let sharedLock = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("configs/surface_plugins.lock.json")))
    let report: JSONValue = try .object(["fixture": #require(document.value(for: "scenario_id")), "fixture_sha256": .string(hash), "source": .string("simulation"),
                                         "host_revision": .string(commandOutput(["git", "rev-parse", "HEAD"], root: root)),
                                         "host_dirty": .bool(!commandOutput(["git", "status", "--porcelain"], root: root).isEmpty),
                                         "shared_revision": #require(sharedLock.value(for: "revision")), "profile_id": .string(CompactSurfaceSimulator.profileID),
                                         "profile_version": .string(CompactSurfaceSimulator.profileVersion), "contract_version": .string(ControlDiscovery.contractVersion),
                                         "mapping_revision": .string(CompactSurfaceSimulator.profile(configuration: CompactSurfaceSimulator.demonstrationConfiguration).mappingRevision), "scenario_mappings": .object(scenarioMappings), "roles": .encoded(roles), "scope": .string("inprocess_real_mock_session"),
                                         "steps": .array(results), "pass": .bool(results.allSatisfy { $0.value(for: "status") == .string("pass") })])
    try JSONEncoder().encode(report).write(to: root.appendingPathComponent("build/\(reportName)"))
    #expect(results.count == expectedSteps)
}
