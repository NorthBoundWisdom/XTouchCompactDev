#if os(macOS)
    import CryptoKit
    import Foundation
    import SurfaceControlContracts
    import SurfacePluginContracts
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    private let h10Null = NSNull()
    private let h10Features = Set(["absolute_input", "motor", "hardware_context", "global_context_motion", "display_style", "independent_io_addresses"])
    private let h10FixtureSHA = "546fbc2a6f1d20f9e116a91558f4dd67891bfaba797b9778e85d975fe4cd3384"

    private func h10Any(_ value: (some Any)?) -> Any {
        value.map { $0 as Any } ?? h10Null
    }

    private enum H10Error: Error { case malformed(String), missingOwner(String) }
    private func h10Object(_ value: Any?) throws -> [String: Any] {
        guard let result = value as? [String: Any] else { throw H10Error.malformed("object") }
        return result
    }

    private func h10Rows(_ value: Any?) throws -> [[String: Any]] {
        guard let result = value as? [[String: Any]] else { throw H10Error.malformed("rows") }
        return result
    }

    private func h10String(_ object: [String: Any], _ key: String) throws -> String {
        guard let result = object[key] as? String else { throw H10Error.malformed(key) }
        return result
    }

    private func h10Number(_ object: [String: Any], _ key: String) throws -> Double {
        guard let result = object[key] as? NSNumber, CFGetTypeID(result) != CFBooleanGetTypeID() else { throw H10Error.malformed(key) }
        return result.doubleValue
    }

    private func h10EncoderMessage(_ index: Int, value: UInt8, layer: CompactLayer = .a) throws -> MIDIMessage {
        guard let address = try FactoryStandardMap().inputAddress(for: .encoder(index), layer: layer) else { throw H10Error.malformed("encoder address") }
        return .controlChange(channel: address.channel, number: address.number, value: value)
    }

    private func h10Same(_ left: Any, _ right: Any) -> Bool {
        if left is NSNull || right is NSNull {
            return left is NSNull && right is NSNull
        }
        if let a = left as? NSNumber, let b = right as? NSNumber {
            return (CFGetTypeID(a) == CFBooleanGetTypeID()) == (CFGetTypeID(b) == CFBooleanGetTypeID()) && a.doubleValue == b.doubleValue
        }
        return (left as? String) != nil && (left as? String) == (right as? String)
    }

    private func h10Assertion(_ assertion: [String: Any], instance: String, before: [String: [String: Any]], after: [String: [String: Any]]) -> Bool {
        let target = assertion["instance_id"] as? String ?? instance
        guard let metric = assertion["metric"] as? String, let a = after[target]?[metric], let relation = assertion["relation"] as? String else { return false }
        let b = before[target]?[metric]
        switch relation {
        case "equals": return assertion["value"].map { h10Same(a, $0) } ?? false
        case "not_equals": return assertion["value"].map { !h10Same(a, $0) } ?? false
        case "unchanged": return b.map { h10Same(a, $0) } ?? false
        case "increased": return (a as? NSNumber).flatMap { aa in (b as? NSNumber).map { aa.doubleValue > $0.doubleValue } } ?? false
        case "at_least": return (a as? NSNumber).flatMap { aa in (assertion["value"] as? NSNumber).map { aa.doubleValue >= $0.doubleValue } } ?? false
        case "increased_by":
            guard let a = a as? NSNumber, let b = b as? NSNumber, let amount = assertion["value"] as? NSNumber else { return false }
            return a.doubleValue - b.doubleValue == amount.doubleValue
        default: return false
        }
    }

    private func h10SentRingCache(_ state: CompactState, index: Int) throws -> RingDisplay? {
        guard let value = Mirror(reflecting: state).children.first(where: { $0.label == "lastSentRings" })?.value as? [Int: RingDisplay] else {
            throw H10Error.malformed("Actual CompactState.lastSentRings cache is not observable")
        }
        return value[index]
    }

    private func h10RingWireValue(_ display: RingDisplay) -> Int {
        switch display { case .off: 0; case let .position(value): value; case let .blinkingPosition(value): value + 13; case .allOn: 27; case .allBlinking: 28 }
    }

    @MainActor private final class H10Wire: MIDIService {
        var onMessages: (([MIDIMessage]) -> Void)?
        var onConnection: ((CompactMIDIConnection) -> Void)?
        var records: [(MIDIMessage, Bool)] = []
        var connected = false
        var actualInputID: Int32?
        var actualOutputID: Int32?
        var generation: UInt64 = 1
        var reject = false
        var starts = 0
        var device = MockXTouchCompact(map: try! FactoryStandardMap(), lightProtocol: .manual)
        func start() throws {
            starts += 1
        }

        func select(inputID _: Int32?, outputID _: Int32?) {}
        func send(_ message: MIDIMessage) throws {
            records.append((message, !reject))
            if reject {
                throw CompactMIDIError.outputUnavailable
            }
            device.receive(message)
        }

        func sendPinned(_ message: MIDIMessage, inputID: Int32, outputID: Int32, generation: UInt64) throws {
            let valid = connected && inputID == actualInputID && outputID == actualOutputID && generation == self.generation
            records.append((message, valid && !reject))
            guard valid else { throw CompactMIDIError.routeChanged }
            guard !reject else { throw CompactMIDIError.outputUnavailable }
            device.receive(message)
        }

        func connection(_ connected: Bool, generation: UInt64, name: String = "Test Compact", id: Int32 = 1) {
            self.connected = connected; self.generation = generation
            actualInputID = connected ? id : nil; actualOutputID = connected ? id : nil
            let endpoint = CompactMIDIEndpoint(id: id, name: name)
            onConnection?(CompactMIDIConnection(generation: generation, connectedInput: connected ? endpoint : nil, connectedOutput: connected ? endpoint : nil))
        }
    }

    @MainActor private final class H10Instance {
        let id: String
        let source: String
        let scenario: String
        let setup: [String: Any]
        let wire = H10Wire()
        let clock = TestClock()
        var session: CompactSession?
        var model: ConsoleModel?
        var hardware: CompactHardwareSurface?
        var simulator: CompactSurfaceSimulator?
        var styleState: CompactState?
        var plugin = try! CompactPluginHost.agent()
        var nativePlan: [MIDIMessage] = []
        var preparedMotorPlans = 0
        var revokedMotorPlans = 0
        var feedbackPlan: ControlFeedback?
        var guiDisplayValue: UInt8?
        var effects: [[String: Any]] = []
        var raw: [[String: Any]] = []
        var actionDispatches: [Int] = []
        var releases = 0
        var rawInputs: [MIDIMessage] = []
        var time = 1.0
        var wall = 100.0
        var routeGeneration: UInt64 = 1
        var oldAuthorization: Bool?
        var gap: Bool?
        var motionEligible: Bool?
        var continuity: Bool?
        var guiAllowed: Bool?
        var remoteAllowed: Bool?
        var guiSuppressionWitness: Bool?
        var remoteSuppressionWitness: Bool?
        var manualAuthority: Bool?
        var resultCertain: Bool?
        var proxyRequests: Int?
        var authorityMissing = false
        var provenanceChecks: [Bool] = []
        var budget = SurfaceWriteBudgets(aggregateLimit: 1)
        var monotonicResults: [Bool] = []

        init(id: String, source: String, scenario: String, setup: [String: Any]) throws {
            self.id = id; self.source = source; self.scenario = scenario; self.setup = setup
            let config = try configuration(page: "page1")
            if source == "hardware" {
                wire.connection(true, generation: 1)
            }
            let gui = ["T09", "T11", "T13", "T15", "T17", "T18", "T21", "T24", "T25", "T27", "T30"].contains(scenario)
            if gui {
                model = ConsoleModel(startsMIDI: false, midi: wire, now: { [clock] in clock.date }, isolated: true)
                model!.apply { try $0.loadConfiguration(config, resetValues: true) }
                model!.mcpWritesAllowed = true
                if source == "hardware" {
                    wire.connection(true, generation: 1)
                    model!.setConsoleMode(.hardwareSend)
                    try wire.onMessages?([h10EncoderMessage(16, value: 0)])
                }
                let permissions = try h10Object(setup["permissions"])
                model!.mcpMotorWritesAllowed = permissions["motor"] as? Bool ?? false
                if permissions["display"] as? Bool == false {
                    model!.setListenOnly(true)
                }
            } else if source == "simulation" {
                simulator = try CompactSurfaceSimulator(instanceID: id, epoch: "h10.simulation.1", configuration: config, eventCapacity: setup["journal_capacity"] as? Int ?? 16)
            } else if ["T12", "T23"].contains(scenario) {
                try makeHardware()
            } else if scenario == "T14" {
                styleState = try CompactState(map: FactoryStandardMap(), lightProtocol: .manual)
                _ = try styleState!.receive(h10EncoderMessage(16, value: 0))
            } else if scenario != "T26" {
                session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
                try wire.device.receive(session!.loadConfiguration(config, resetValues: true))
                _ = try session!.connect(assertLayer: false)
                try wire.device.receive(session!.receive([h10EncoderMessage(16, value: 0)]).feedback)
            }
            if scenario == "T25" {
                try makeHardware()
                for index in 1 ... 9 {
                    let address = try FactoryStandardMap().inputAddress(for: .faderTouch(index), layer: .a)!
                    let message = MIDIMessage.controlChange(channel: address.channel, number: address.number, value: 0)
                    wire.onMessages?([message])
                    raw.append(["kind": "setup-explicit-touch-release-observation", "message": message.description])
                }
            }
            wire.records.removeAll()
            if scenario == "T26" {
                monotonicResults.append(budget.consume(.feedback, at: time))
            }
        }

        func makeHardware() throws {
            hardware = try CompactHardwareSurface(instanceID: id, epoch: "h10.hardware.1", configuration: .init(receiveChannel: 0, lightProtocol: .manual), hardwareWriterID: "h10.physical", remoteWriterID: "h10.display", eventCapacity: setup["journal_capacity"] as? Int ?? 16)
            try hardware!.transition(epoch: "h10.hardware.connected.1", connected: true, at: time)
            _ = try hardware!.receive(h10EncoderMessage(16, value: 0), at: time)
        }

        func configuration(page: String) throws -> SurfaceConfiguration {
            let parameters = try h10Rows(setup["parameters"]).map { row in
                try ParameterDefinition(id: h10String(row, "id"), name: h10String(row, "id"), minimum: h10Number(row, "minimum"), maximum: h10Number(row, "maximum"), defaultValue: h10Number(row, "initial"))
            }
            let pages = try h10Rows(setup["pages"])
            guard let selected = pages.first(where: { $0["id"] as? String == page }) else { throw H10Error.malformed("page") }
            var assignments: [ControlAssignment] = []
            for binding in try h10Rows(selected["bindings"]) {
                let element = try h10String(binding, "element_id")
                let control: CompactControl
                switch element { case "axis": control = .encoder(1); case "button": control = .button(1); case "fader1": control = .fader(1); case "fader2": control = .fader(2); default: continue }
                let target = try h10String(binding, "target_id")
                let action: ParameterAction = binding["kind"] as? String == "parameter" ? .parameter(target) : .agent(target == "fire2" ? 2 : 1)
                for layer in CompactLayer.allCases {
                    assignments.append(.init(control: control, layer: layer, action: action))
                }
            }
            return SurfaceConfiguration(parameters: parameters, assignments: assignments)
        }

        func endpoint(_ message: MIDIMessage) -> (String, [String], Any) {
            let map = try! FactoryStandardMap()
            switch message {
            case let .programChange(_, value): return ("hardware.context", ["context", "motor"], Int(value))
            case let .controlChange(channel, number, value):
                let matches: (MIDIAddress?) -> Bool = { $0?.messageType == .controlChange && $0?.channel == channel && $0?.number == number }
                for index in 1 ... 9 where matches(map.feedbackAddress(for: .fader(index))) {
                    return ("fader\(index).motor", ["motor"], Int(value))
                }
                for index in 1 ... 16 {
                    if matches(map.feedbackAddress(for: .encoder(index))) {
                        return (index == 1 ? "axis.display" : "encoder\(index).display", ["display", "value_projection"], Int(value))
                    }
                    if matches(map.encoderRingStyleAddress(encoder: index)) {
                        return (index == 1 ? "axis.style" : "encoder\(index).style", ["display"], Int(value))
                    }
                }
                return ("wire.cc\(number)", ["other"], Int(value))
            case let .noteOn(channel, number, value):
                let matches: (MIDIAddress?) -> Bool = { $0?.messageType == .note && $0?.channel == channel && $0?.number == number }
                for index in 1 ... 39 where matches(map.feedbackAddress(for: .button(index))) {
                    return (index == 1 ? "button.display" : "button\(index).display", ["display"], Int(value))
                }
                return ("wire.note\(number)", ["other"], Int(value))
            default: return ("wire.other", ["other"], message.description)
            }
        }

        func collectWire() {
            for (message, accepted) in wire.records {
                let (endpoint, kinds, value) = endpoint(message)
                effects.append(["instance_id": id, "endpoint": endpoint, "kinds": kinds, "value": value, "accepted": accepted])
                raw.append(["kind": "transport", "message": message.description, "ump": String(format: "%08X", MIDI1UMPCodec.encode(message)), "accepted": accepted])
            }
            wire.records.removeAll()
        }

        func send(_ messages: [MIDIMessage], reject: Bool = false) throws {
            wire.reject = reject
            defer { wire.reject = false; collectWire() }
            for message in messages {
                try wire.send(message)
            }
        }

        func receive(_ element: String, value: Any, context: String = "context1") throws {
            let layer: CompactLayer = context == "context2" ? .b : .a
            let map = try FactoryStandardMap()
            let control: CompactControl
            switch element { case "axis": control = .encoder(1); case "button": control = .button(1); case "fader1": control = .fader(1); case "fader2": control = .fader(2); case "pedal": control = .expression; case "meter": control = .encoder(16); default: throw H10Error.malformed("control") }
            guard let address = map.inputAddress(for: control, layer: layer) else { throw H10Error.malformed("input address") }
            raw.append(["kind": "actual-map-witness", "logical_element": element, "input_address": address.description,
                        "feedback_address": h10Any(map.feedbackAddress(for: control)?.description)])
            let pressed = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil } ?? nil
            let byte = pressed.map { $0 ? UInt8(127) : UInt8(0) } ?? UInt8((value as? NSNumber)?.intValue ?? 0)
            let message: MIDIMessage = address.messageType == .note ? (pressed == false ? .noteOff(channel: address.channel, number: address.number, velocity: 0) : .noteOn(channel: address.channel, number: address.number, velocity: byte)) : .controlChange(channel: address.channel, number: address.number, value: byte)
            try input([message])
        }

        func input(_ messages: [MIDIMessage]) throws {
            rawInputs += messages
            raw += messages.map { ["kind": "input", "message": $0.description, "ump": String(format: "%08X", MIDI1UMPCodec.encode($0))] }
            for message in messages {
                _ = try wire.device.applyCapturedInput(message)
            }
            if let model {
                let before = model.agents.slots.map(\.phase)
                wire.onMessages?(messages)
                for (index, slot) in model.agents.slots.enumerated() where slot.phase != before[index] {
                    actionDispatches.append(index + 1)
                }
                collectWire()
            } else if session != nil {
                let update = try session!.receive(messages)
                releases += update.inputs.filter { $0.isPressed == false }.count
                for action in update.actionIntents {
                    _ = try plugin.handle(.invoke(action, origin: .hardware), pluginID: action.pluginID, at: time)
                    if let index = action.index {
                        actionDispatches.append(index)
                    }
                }
                try send(update.feedback)
            } else if hardware != nil {
                for message in messages {
                    _ = try hardware!.receive(message, at: time)
                }
            }
        }

        func touch(_ element: String, state: String, context: String) throws {
            let index = element == "fader2" ? 2 : 1
            let layer: CompactLayer = context == "context2" ? .b : .a
            let address = try FactoryStandardMap().inputAddress(for: .faderTouch(index), layer: layer)!
            try input([.controlChange(channel: address.channel, number: address.number, value: state == "touched" ? 127 : 0)])
        }

        func observations() -> [String: Any] {
            collectWire()
            var result: [String: Any] = ["device_output_count": effects.count, "accepted_transport_count": effects.filter { $0["accepted"] as? Bool == true }.count,
                                         "motor_output_count": effects.filter { ($0["kinds"] as? [String])?.contains("motor") == true }.count,
                                         "value_projection_output_count": effects.filter { $0["accepted"] as? Bool == true && ($0["kinds"] as? [String])?.contains("value_projection") == true }.count,
                                         "display_output_count": effects.filter { ($0["kinds"] as? [String])?.contains("display") == true }.count,
                                         "layer_select_output_count": effects.filter { ($0["kinds"] as? [String])?.contains("context") == true }.count,
                                         "action_fire1_count": actionDispatches.filter { $0 == 1 }.count, "action_fire2_count": actionDispatches.filter { $0 == 2 }.count,
                                         "release_count": releases, "route_generation": Int(routeGeneration),
                                         "prepared_motor_plan_count": preparedMotorPlans, "revoked_motor_plan_count": revokedMotorPlans]
            let profile = try! CompactHardwareConfiguration(receiveChannel: 0, lightProtocol: .manual).profile
            let map = try! FactoryStandardMap()
            let relativeValues = rawInputs.compactMap { message -> Int? in
                guard let decoded = map.decode(message), case let .encoder(index) = decoded.control,
                      profile.controls.first(where: { $0.id == "\(decoded.layer.rawValue).encoder.\(index)" })?.input_kind == .relative else { return nil }
                return Int(decoded.value)
            }
            result["relative_delta_sum"] = relativeValues.reduce(0, +)
            let live = model?.session ?? session
            if let live {
                result["parameter_p1"] = h10Any(live.parameters.values["p1"])
                result["hardware_context"] = h10Any(live.state.observedLayer.map { $0 == .a ? "context1" : "context2" })
                result["software_page"] = live.parameters.assignment(.encoder(1), layer: .a) == .parameter("p2") ? "page2" : "page1"
                result["layer_consistent"] = !live.state.layerMismatch
                result["pending_motor_count"] = (1 ... 9).filter { live.state.isMotorPending($0) }.count
                result["observed_value"] = h10Any(live.state.observedFader(1).map(Int.init))
                result["enable_binding_count"] = live.parameters.configuration.assignments.filter {
                    if case .parameter("enable") = $0.action {
                        true
                    } else {
                        false
                    }
                }.count
                result["rendered_value"] = h10Any(model?.panelSnapshot.parameterValues["p1"] ?? live.parameters.values["p1"])
            }
            if let model {
                result["motor_permission"] = model.mcpMotorWritesAllowed
                result["touch_continuity_trusted"] = continuity ?? (model.reportedHardwarePresses[.faderTouch(1)] != nil)
                result["authority_error_visible"] = model.error.map { String(describing: $0).contains("authority_denied") } ?? false
                if let guiAllowed, let remoteAllowed {
                    result["authorization_rules_equal"] = guiAllowed == remoteAllowed && guiSuppressionWitness == true && remoteSuppressionWitness == true
                }
            }
            if scenario == "T15", let model {
                do { result["sent_value"] = try h10Any(h10SentRingCache(model.session.state, index: 1).map(h10RingWireValue)) }
                catch { result["sent_value"] = "actual cache unavailable" }
            } else if let hardware, let snapshot = try? hardware.controls.snapshot(at: time) {
                result["sent_value"] = h10Any(snapshot.feedback["a.encoder.1"]?["value"].flatMap(\.exactIntValue))
            } else {
                result["sent_value"] = effects.last(where: { $0["endpoint"] as? String == "axis.display" && $0["accepted"] as? Bool == true })?["value"] ?? h10Null
            }
            result["raw_input_echo_count"] = raw.filter { row in row["kind"] as? String == "transport" && rawInputs.contains(where: { $0.description == row["message"] as? String }) }.count
            result["feedback_endpoint"] = effects.last(where: { ($0["kinds"] as? [String])?.contains("display") == true })?["endpoint"] ?? h10Null
            if let oldAuthorization {
                result["old_authorization_valid"] = oldAuthorization
            }
            if let gap {
                result["journal_gap"] = gap
            }
            if let motionEligible {
                result["motion_eligible"] = motionEligible
            }
            if let continuity {
                result["touch_continuity_trusted"] = continuity
            }
            if let manualAuthority {
                result["manual_authority_granted"] = manualAuthority
            }
            if let resultCertain {
                result["result_certain"] = resultCertain
            }
            if let proxyRequests {
                result["automatic_action_replay_count"] = max(0, proxyRequests - 1)
            }
            result["automatic_echo_replay_count"] = raw.last?["echo_replay_count"] ?? 0
            if !provenanceChecks.isEmpty {
                result["provenance_preserved"] = provenanceChecks.allSatisfy(\.self)
                result["qualification_upgraded"] = h10Null
            }
            if let preview = raw.last(where: { $0["kind"] as? String == "actual-page-display-plan-and-real-Mock-projection" }) {
                result["display_plan_valid"] = preview["valid"]
            }
            if !monotonicResults.isEmpty {
                result["monotonic_policy_preserved"] = monotonicResults.first == true && monotonicResults.dropFirst().allSatisfy { !$0 }
            }
            return result
        }
    }

    @MainActor private func h10Process(_ command: [String], input: Data? = nil, environment: [String: String]? = nil, timeout: Double = 15) async throws -> (Int32, Data, Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        let incoming = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : incoming
        try process.run()
        if let input {
            try incoming.fileHandleForWriting.write(contentsOf: input)
            try incoming.fileHandleForWriting.close()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        if process.isRunning {
            process.terminate(); throw H10Error.malformed("owned subprocess timeout")
        }
        return (process.terminationStatus, output.fileHandleForReading.readDataToEndOfFile(), errors.fileHandleForReading.readDataToEndOfFile())
    }

    @MainActor private extension H10Instance {
        func execute(_ action: [String: Any], repo: URL) async throws -> String? {
            let operation = try h10String(action, "operation"), arguments = try h10Object(action["arguments"])
            if operation != "advance_time" {
                time += 0.1
            }
            switch operation {
            case "receive_input":
                try receive(h10String(arguments, "element_id"), value: arguments["value"]!, context: h10String(arguments, "context"))
            case "turn_absolute":
                let index = 1
                let messages = try wire.device.turnEncoder(index, delta: Int(h10Number(arguments, "delta")))
                try input(messages)
            case "receive_batch":
                var messages: [MIDIMessage] = []
                for event in try h10Rows(arguments["events"]) {
                    let layer: CompactLayer = event["context"] as? String == "context2" ? .b : .a
                    let index = event["element_id"] as? String == "fader2" ? 2 : 1
                    let address = try FactoryStandardMap().inputAddress(for: .faderTouch(index), layer: layer)!
                    messages.append(.controlChange(channel: address.channel, number: address.number, value: event["state"] as? String == "touched" ? 127 : 0))
                }
                try input(messages)
            case "touch":
                try touch(h10String(arguments, "element_id"), state: h10String(arguments, "state"), context: h10String(arguments, "context"))
            case "publish_display":
                let value = try UInt8(h10Number(arguments, "value"))
                if styleState != nil {
                    let style: RingStyle = arguments["style"] as? String == "alternate" ? .pan : .single
                    var messages = try styleState!.setRingStyle(1, style: style)
                    messages += try styleState!.setRing(1, display: .position(CompactSession.ringSegment(for: value)))
                    raw.append(["kind": "semantic-display-request", "value": Int(value), "style": style.rawValue])
                    try send(messages)
                } else {
                    guard session != nil else { throw H10Error.missingOwner(operation) }
                    try send(session!.setDisplayRing(1, value: value))
                }
            case "prepare_display":
                let semantic = try UInt8(h10Number(arguments, "value"))
                if let model {
                    let actualBefore = try h10SentRingCache(model.session.state, index: 1)
                    var preview = model.session
                    let plan = try preview.setDisplayRing(1, value: semantic)
                    let target = RingDisplay.position(CompactSession.ringSegment(for: semantic))
                    guard actualBefore != target, plan.contains(where: { endpoint($0).0 == "axis.display" }) else { return "T15 precondition must have a nonmatching real sent cache and nonempty actual numeric plan" }
                    guiDisplayValue = semantic
                    raw.append(["kind": "real-GUI-display-plan-preparation-not-IO", "semantic_value": Int(semantic), "actual_cache_field": "CompactState.lastSentRings",
                                "actual_cache_before": h10Any(actualBefore.map { String(describing: $0) }), "native_preview": plan.map(\.description),
                                "actual_desired_before": h10Any(model.session.state.desiredRing(1).map { String(describing: $0) })])
                } else {
                    guard let hardware else { throw H10Error.missingOwner(operation) }
                    let request = ControlFeedback(expected: hardware.controls.expected, controlID: "a.encoder.1", kind: "value", value: .number(CompactSession.ringSegment(for: semantic)))
                    let prepared = try hardware.displayPlan(request, allowed: true, at: time)
                    feedbackPlan = request
                    try raw.append(["kind": "validated-current-display-plan", "semantic_value": Int(semantic), "expected_epoch": request.expected.epoch,
                                    "mapped_wire_value": CompactSession.ringSegment(for: semantic), "messages": prepared.map { try String(format: "%08X", $0.word(configuration: hardware.configuration)) }])
                }
            case "prepare_motor":
                guard session != nil else { throw H10Error.missingOwner(operation) }
                nativePlan = try session!.setFader(arguments["element_id"] as? String == "fader2" ? 2 : 1, value: UInt8(h10Number(arguments, "value")))
                let preparedMotors = nativePlan.filter { endpoint($0).1.contains("motor") }
                preparedMotorPlans += preparedMotors.count
                raw.append(["kind": "native-plan", "messages": nativePlan.map(\.description), "actual_motor_plan_multiset": preparedMotors.map(\.description)])
            case "flush":
                let reject = arguments["transport_result"] as? String == "rejected"
                if let value = guiDisplayValue, let model {
                    let before = try h10SentRingCache(model.session.state, index: 1)
                    let oldEvents = Set(model.events.map(\.id))
                    let effectOffset = effects.count
                    wire.reject = reject
                    model.apply { try $0.setDisplayRing(1, value: value) }
                    wire.reject = false
                    collectWire()
                    let after = try h10SentRingCache(model.session.state, index: 1)
                    let failures = model.events.filter { !oldEvents.contains($0.id) && $0.direction == .output && $0.delivery == .failed }
                    let actualAttempts = Array(effects.dropFirst(effectOffset))
                    raw.append(["kind": "actual-Model-apply-send-failure-and-cache-invalidation", "actual_cache_field": "CompactState.lastSentRings",
                                "actual_cache_before": h10Any(before.map { String(describing: $0) }), "actual_cache_after": h10Any(after.map { String(describing: $0) }),
                                "actual_desired_after": h10Any(model.session.state.desiredRing(1).map { String(describing: $0) }),
                                "product_error": model.error.map { String(describing: $0) } ?? "none", "actual_transport_attempts": actualAttempts,
                                "product_failed_output_events": failures.map { ["delivery": h10Any($0.delivery?.rawValue), "message": h10Any($0.message?.description)] }])
                    guiDisplayValue = nil
                    if reject, actualAttempts.isEmpty || failures.isEmpty || actualAttempts.contains(where: { $0["accepted"] as? Bool == true }) || after != nil {
                        return "Actual product failure path did not prove a rejected send and real sent-cache invalidation"
                    }
                } else if let request = feedbackPlan {
                    guard hardware != nil else { throw H10Error.missingOwner(operation) }
                    do {
                        let plan = try hardware!.displayPlan(request, allowed: true, at: time)
                        oldAuthorization = true
                        var native: [MIDIMessage] = []
                        for message in plan {
                            let word = try message.word(configuration: hardware!.configuration)
                            raw.append(["kind": "hardware-plan-word", "word": String(format: "%08X", word)])
                            guard let decoded = MIDI1UMPCodec.decode(word) else { throw H10Error.malformed("typed plan produced invalid UMP") }
                            native.append(decoded)
                        }
                        do {
                            try send(native, reject: reject)
                            _ = try hardware!.recordFeedback(request, at: time)
                        } catch {
                            raw.append(["kind": "transport-rejection", "error": String(describing: error)])
                            if !reject {
                                return "Unexpected transport failure"
                            }
                        }
                    } catch let error as ControlContractError {
                        raw.append(["kind": "old-pin-validation", "error": error.code, "old_epoch": request.expected.epoch, "current_epoch": hardware!.controls.expected.epoch])
                        if error.code == "stale_epoch" {
                            oldAuthorization = false
                        } else {
                            return "Unexpected old-pin rejection: " + error.code
                        }
                    }
                    feedbackPlan = nil
                } else if session != nil {
                    let original = nativePlan
                    let filtered = session!.filterFeedbackForDelivery(original)
                    var remaining = filtered.filter { endpoint($0).1.contains("motor") }
                    var revoked: [MIDIMessage] = []
                    for message in original where endpoint(message).1.contains("motor") {
                        if let index = remaining.firstIndex(of: message) {
                            remaining.remove(at: index)
                        } else {
                            revoked.append(message)
                        }
                    }
                    revokedMotorPlans += revoked.count
                    nativePlan = []
                    raw.append(["kind": "actual-filter-plan-observation-not-IO", "before": original.map(\.description), "after": filtered.map(\.description),
                                "revoked_native_motor_multiset": revoked.map(\.description), "driver_retained_native_plan_count": nativePlan.count,
                                "real_deferred_desired_pending_count": (1 ... 9).filter { session!.state.isMotorPending($0) }.count])
                    try send(filtered, reject: reject)
                } else if model != nil {
                    collectWire() // Model writes traverse its real synchronous boundary already.
                } else {
                    throw H10Error.missingOwner(operation)
                }
            case "select_software_page":
                let configuration = try configuration(page: h10String(arguments, "page"))
                let contextBefore = model?.session.state.observedLayer ?? session?.state.observedLayer
                let ringBefore = wire.device.rings[0]
                var produced: [MIDIMessage] = []
                if let model {
                    model.apply { live in
                        let plan = try live.loadConfiguration(configuration, resetValues: false)
                        produced = plan
                        return plan
                    }
                    collectWire()
                } else if session != nil {
                    produced = try session!.loadConfiguration(configuration, resetValues: false)
                    try send(produced)
                } else {
                    throw H10Error.missingOwner(operation)
                }
                let live = model?.session ?? session!
                guard case let .parameter(parameter)? = live.parameters.assignment(.encoder(1), layer: .a),
                      let definition = live.parameters.definition(parameter), let actual = live.parameters.values[parameter]
                else {
                    return "New page has no actual axis parameter binding/value"
                }
                let targetByte = try definition.midiValue(actual)
                let targetDisplay = RingDisplay.position(CompactSession.ringSegment(for: targetByte))
                let expectedValueMessage = try live.state.map.encoderRingValue(encoder: 1, display: targetDisplay)
                let numeric = produced.filter { endpoint($0).0 == "axis.display" }
                let pageID = try h10String(arguments, "page")
                guard let dataPage = try h10Rows(setup["pages"]).first(where: { $0["id"] as? String == pageID }),
                      let dataAxis = try h10Rows(dataPage["bindings"]).first(where: { $0["element_id"] as? String == "axis" && $0["kind"] as? String == "parameter" })
                else {
                    return "Fixture page has no parameter binding for the logical axis"
                }
                let dataTarget = try h10String(dataAxis, "target_id")
                guard let dataParameter = try h10Rows(setup["parameters"]).first(where: { $0["id"] as? String == dataTarget }) else {
                    return "Fixture page target has no setup parameter"
                }
                let dataInitial = try h10Number(dataParameter, "initial")
                let valid = parameter == dataTarget && actual == dataInitial && live.parameters.assignment(.encoder(1), layer: .a) == .parameter(dataTarget)
                    && !numeric.isEmpty && numeric.contains(expectedValueMessage) && wire.device.rings[0] == targetDisplay && live.state.observedLayer == contextBefore
                raw.append(["kind": "actual-page-display-plan-and-real-Mock-projection", "valid": valid, "actual_parameter_id": parameter, "actual_parameter_value": actual, "data_page_target": dataTarget, "data_parameter_initial": dataInitial,
                            "numeric_plan": numeric.map(\.description), "numeric_UMP": numeric.map { String(format: "%08X", MIDI1UMPCodec.encode($0)) },
                            "all_actual_product_plan": produced.map(\.description), "actual_Mock_ring_before": String(describing: ringBefore),
                            "actual_Mock_ring_after": String(describing: wire.device.rings[0]), "actual_codec_projection": expectedValueMessage.description,
                            "observed_layer_before": h10Any(contextBefore?.rawValue), "observed_layer_after": h10Any(live.state.observedLayer?.rawValue)])
            case "write_parameter":
                guard let model else { throw H10Error.missingOwner(operation) }
                let parameter = try h10String(arguments, "parameter_id"), value = try h10Number(arguments, "value"), origin = try h10String(arguments, "origin")
                let start = effects.count
                let existingEvents = Set(model.events.map(\.id))
                if origin == "remote" {
                    _ = try model.routeMCP(["method": "tools/call", "params": ["name": "set_parameter", "arguments": ["id": parameter, "value": value]]])
                } else if origin == "agent" {
                    try model.applyAgentParameter(parameter, value: value)
                } else {
                    model.setParameter(parameter, value: value)
                }
                collectWire()
                let outputAllowed = effects.count > start
                let outputEvents = model.events.filter { !existingEvents.contains($0.id) && $0.direction == .output }
                let suppressed = !outputEvents.isEmpty && outputEvents.allSatisfy { $0.delivery == .suppressed } && !outputAllowed && model.listenOnly
                if origin == "remote" {
                    remoteAllowed = outputAllowed; remoteSuppressionWitness = suppressed
                } else if origin == "gui" {
                    guiAllowed = outputAllowed; guiSuppressionWitness = suppressed
                }
                raw.append(["kind": "actual-GUI-MCP-gate-observations", "origin": origin, "listen_only": model.listenOnly,
                            "actual_transport_calls": effects.count - start, "all_planned_output_suppressed": suppressed,
                            "model_output_events": outputEvents.map { ["source": $0.source.rawValue, "delivery": h10Any($0.delivery?.rawValue), "message": h10Any($0.message?.description), "ignored": $0.ignored] }])
                if authorityMissing {
                    return "No external authority-to-UI entry point: actual GUI write/value/error retained"
                }
            case "configure_permissions":
                guard let model else { throw H10Error.missingOwner(operation) }
                model.mcpMotorWritesAllowed = arguments["motor"] as? Bool ?? false
                model.setListenOnly(!(arguments["display"] as? Bool ?? false))
                raw.append(["kind": "existing-permission-entrypoints", "listen_only": model.listenOnly, "agent_motor_permission": model.mcpMotorWritesAllowed,
                            "note": "Agent motor permission is not a new universal GUI permission"])
            case "select_hardware_context":
                guard let model else { throw H10Error.missingOwner(operation) }
                model.setLayer(arguments["context"] as? String == "context2" ? .b : .a)
                collectWire()
                raw.append(["kind": "actual-layer-intent", "error": model.error.map { String(describing: $0) } ?? "none"])
            case "disconnect":
                wire.connection(false, generation: routeGeneration)
                collectWire()
            case "reconnect", "replace_route":
                routeGeneration = try UInt64(h10Number(arguments, "route_generation"))
                if hardware != nil {
                    let previous = hardware!.controls.expected.epoch
                    try hardware!.transition(epoch: "h10.route.\(routeGeneration)", connected: true, at: time)
                    raw.append(["kind": "actual-hardware-transition", "old_epoch": previous, "new_epoch": hardware!.controls.expected.epoch])
                } else {
                    wire.connection(true, generation: routeGeneration)
                    collectWire()
                    if scenario == "T11" {
                        guard let model else { throw H10Error.missingOwner(operation) }
                        continuity = model.reportedHardwarePresses[.faderTouch(1)] != nil
                        model.setConsoleMode(.hardwareSend)
                        model.mcpMotorWritesAllowed = true
                        try wire.onMessages?([h10EncoderMessage(16, value: 0)]) // Existing unbound E16: restores layer evidence without writing p1.
                        collectWire()
                        let start = effects.count
                        model.apply { try $0.setDisplayFader(1, value: 100) }
                        collectWire()
                        motionEligible = effects[start...].contains { ($0["kinds"] as? [String])?.contains("motor") == true }
                        raw.append(["kind": "connected-authorized-motor-probe", "connected": model.connection.isConnected, "generation": model.connection.generation,
                                    "listen_only": model.listenOnly, "agent_motor_permission": model.mcpMotorWritesAllowed, "layer_evidence": model.session.state.observedLayer?.rawValue ?? "unknown",
                                    "actual_safety_touch": model.session.state.isTouched(1), "motor_attempt_allowed": motionEligible!])
                    }
                }
            case "receive_motor_echo":
                let start = effects.count
                try receive(h10String(arguments, "element_id"), value: arguments["value"]!)
                let count = effects[start...].filter { ($0["kinds"] as? [String])?.contains("motor") == true }.count
                raw.append(["kind": "motor-progress-observation", "echo_replay_count": count])
            case "save_restore":
                guard arguments["verb"] as? String == "undo", let model else { throw H10Error.missingOwner(operation) }
                let before = effects.count
                model.undo(); collectWire()
                raw.append(["kind": "actual-local-undo-under-Agent-specific-permission", "agent_motor_permission": model.mcpMotorWritesAllowed,
                            "actual_new_transport_calls": effects.count - before, "scope": "Existing Agent-specific permission does not express a universal GUI motor revocation"])
                if !model.mcpMotorWritesAllowed {
                    return "Neutral global GUI/undo motor-revocation target has no common product gate: actual mcpMotorWritesAllowed is Agent-specific; explicit local undo follows existing local authorization. Not a published permission-contract violation or H safety regression"
                }
            case "simulation_feedback":
                guard simulator != nil else { throw H10Error.missingOwner(operation) }
                let value = try UInt8(h10Number(arguments, "value"))
                var preview = simulator!.session
                let native = try preview.setDisplayRing(1, value: value)
                let event = try simulator!.feedback(.init(expected: simulator!.controls.expected, controlID: "a.encoder.1", kind: "value", value: .number(Int(value))), at: time)
                guard event.disposition == .accepted, simulator!.mock.rings[0] == preview.state.desiredRing(1) else { return "Simulator feedback did not match its public native projection witness" }
                raw.append(["kind": "isolated-real-simulator-feedback", "profile": simulator!.controls.profile.id, "projection_witness_is_not_IO_receipt": true, "native_public_projection_witness": native.map(\.description), "actual_feedback_event_disposition": event.disposition.rawValue, "actual_mock_ring": String(describing: simulator!.mock.rings[0])])
            case "simulation_reset":
                guard simulator != nil else { throw H10Error.missingOwner(operation) }
                try simulator!.reset(epoch: "h10.simulation.reset.2", at: time)
            case "remote_input":
                if source == "hardware" {
                    guard let hardware else { throw H10Error.missingOwner(operation) }
                    let input = ControlInput(expected: hardware.controls.expected, expectedInputSequence: hardware.controls.discovery().latest_input_sequence,
                                             controlID: "a.button.1", encoding: "boolean", value: .bool(true))
                    var encoded = try JSONEncoder().encode(input)
                    var object = try h10Object(JSONSerialization.jsonObject(with: encoded))
                    object["origin"] = arguments["claimed_origin"]
                    encoded = try JSONSerialization.data(withJSONObject: object)
                    do { _ = try SurfaceControlTools.parse("surface_control_input", arguments: JSONDecoder().decode(JSONValue.self, from: encoded)); return "Claimed origin unexpectedly passed strict parser" }
                    catch let error as ControlContractError { raw.append(["kind": "untrusted-origin-parser", "error": error.code]) }
                    do { _ = try hardware.controls.validateInput(input, at: time, writerID: "h10.display"); manualAuthority = true
                        return "Hardware accepted remote input"
                    } catch let error as ControlContractError {
                        guard error.code == "permission_denied" else { return "Unexpected hardware input error: " + error.code }
                        manualAuthority = false
                        raw.append(["kind": "hardware-input-permission", "error": error.code])
                    }
                } else {
                    try await lostActionResponse(repo: repo)
                }
            case "overflow_journal":
                guard hardware != nil else { throw H10Error.missingOwner(operation) }
                let old = hardware!.controls.discovery().latest_sequence
                for index in try 0 ..< Int(h10Number(arguments, "count")) {
                    _ = try hardware!.receive(h10EncoderMessage(1, value: UInt8(index % 128)), at: time)
                }
                do { _ = try hardware!.controls.events(instanceID: id, epoch: hardware!.controls.expected.epoch, afterSequence: old, at: time); gap = false }
                catch let error as ControlContractError { gap = error.code == "event_gap"; raw.append(["kind": "real-journal-gap", "error": error.code, "capacity": hardware!.controls.eventCapacity]) }
            case "lose_touch_continuity":
                guard let model else { throw H10Error.missingOwner(operation) }
                routeGeneration += 1
                wire.connection(true, generation: routeGeneration)
                continuity = (1 ... 9).allSatisfy { model.reportedHardwarePresses[.faderTouch($0)] != nil }
                let start = effects.count
                model.apply { try $0.setDisplayFader(1, value: 100) }
                collectWire()
                motionEligible = effects[start...].contains { ($0["kinds"] as? [String])?.contains("motor") == true }
                raw.append(["kind": "GUI-route-continuity-invalidation-not-journal-glue", "connected": model.connection.isConnected, "generation": model.connection.generation,
                            "touch_reports": model.reportedHardwarePresses.count, "error": model.error.map { String(describing: $0) } ?? "none"])
            case "advance_time":
                time += try h10Number(arguments, "monotonic_delta_s")
                wall += try h10Number(arguments, "wall_delta_s")
                let accepted = budget.consume(.feedback, at: time)
                monotonicResults.append(accepted)
                raw.append(["kind": "actual-budget-monotonic-input", "monotonic": time, "wall": wall, "accepted": accepted])
            case "authority_reply":
                guard let model else { throw H10Error.missingOwner(operation) }
                authorityMissing = true
                raw.append(["kind": "missing-product-authority-entrypoint", "requested_reply": arguments, "actual_gui_value": model.panelSnapshot.parameterValues["p1"] ?? 0,
                            "actual_error": model.error.map { String(describing: $0) } ?? "none"])
                return "Product has no external-authority reply-to-GUI integration; no fixture reducer added"
            case "receive_unconfigured":
                try receive(h10String(arguments, "element_id"), value: arguments["value"]!)
            case "attach_endpoint":
                guard let model else { throw H10Error.missingOwner(operation) }
                let provenance = try h10String(arguments, "provenance"), name = try h10String(arguments, "name")
                routeGeneration += 1
                wire.connection(true, generation: routeGeneration, name: name, id: provenance == "remote_virtual" ? 1001 : 1002)
                let recorded = model.connection.connectedInput
                let retained = provenance == "remote_virtual" ? recorded?.remoteBridgeHost != nil : recorded?.remoteBridgeHost == nil
                provenanceChecks.append(retained)
                raw.append(["kind": "actual-endpoint-model", "supplied_provenance": provenance, "actual_name": recorded?.name ?? "none", "actual_id": recorded?.id ?? 0,
                            "actual_remote_bridge_host": h10Any(recorded?.remoteBridgeHost), "qualification_field": "absent in current endpoint model"])
                collectWire()
                return "Endpoint model stores ID/name and name-derived bridge host, with no explicit supplied provenance/qualification field"
            case "inspect": break
            default: throw H10Error.missingOwner(operation)
            }
            return nil
        }

        func lostActionResponse(repo: URL) async throws {
            guard let model, !model.hardwareMode else { throw H10Error.malformed("lost response must use isolated GUI Mock") }
            let token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let server = LocalMCPServer(authenticationToken: token, now: { [clock] in clock.date })
            var dispatches = 0
            server.handler = { request in
                let before = model.agents.slots[0].phase
                let response = try model.routeMCP(request)
                if (request["params"] as? [String: Any])?["name"] as? String == "agent_primary", model.agents.slots[0].phase != before {
                    dispatches += 1
                }
                return response
            }
            try server.start(port: 0, token: token)
            defer { server.stop() }
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while server.boundPort == nil, ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let port = server.boundPort else { throw H10Error.malformed("owned MCP did not become ready") }
            let payload = try JSONSerialization.data(withJSONObject: ["port": port, "token": token, "sdk": repo.appendingPathComponent("build/dependencies/SurfacePlugins/clients/python").path])
            let before = model.agents.slots[0].phase.rawValue
            let (status, output, errors) = try await h10Process(["python3", "-B", repo.appendingPathComponent("Tests/H10Support/response_drop.py").path], input: payload)
            guard !String(decoding: output + errors, as: UTF8.self).contains(token) else { throw H10Error.malformed("credential leak") }
            guard status == 0 else { throw H10Error.malformed("drop proxy failed: " + String(decoding: errors, as: UTF8.self)) }
            let report = try h10Object(JSONSerialization.jsonObject(with: output))
            raw.append(["kind": "actual-action-proxy-admission-observation", "proxy_report": report, "real_successful_dispatches": dispatches,
                        "before_phase": before, "after_phase": model.agents.slots[0].phase.rawValue])
            guard report["upstream_successes"] as? Int == 1, dispatches == 1, model.agents.slots[0].phase.rawValue != before else { throw H10Error.malformed("action was not really dispatched before loss") }
            resultCertain = report["client_code"] as? String != "transport_unknown"
            proxyRequests = report["proxy_requests"] as? Int
            actionDispatches += Array(repeating: 1, count: dispatches)
            raw.append(["kind": "actual-retained-GUI-action-response-loss", "actual_tool": "agent_primary", "before_phase": before, "after_phase": model.agents.slots[0].phase.rawValue,
                        "real_successful_dispatches": dispatches, "transport": report])
        }
    }

    @Test @MainActor func controllerRegressionExecutorProducesThirtyValidatedResultsWithoutChangingProductPolicy() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let environment = ProcessInfo.processInfo.environment
        let shared = URL(fileURLWithPath: environment["XTOUCH_H10_SCHEMA_ROOT"] ?? repo.appendingPathComponent("build/dependencies/SurfacePlugins").path)
        let fixture = URL(fileURLWithPath: environment["XTOUCH_H10_FIXTURE_PATH"] ?? shared.appendingPathComponent("fixtures/controller-regression-v1.json").path)
        let destination = URL(fileURLWithPath: environment["XTOUCH_H10_REPORT_ROOT"] ?? repo.appendingPathComponent("build/h/h10/final").path)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let bytes = try Data(contentsOf: fixture)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(digest == h10FixtureSHA)
        guard digest == h10FixtureSHA else { throw H10Error.malformed("candidate fixture changed; coordinate instead of learning new oracle") }
        let document = try h10Object(JSONSerialization.jsonObject(with: bytes))
        let scenes = try h10Rows(document["scenarios"])
        #expect(scenes.count == 30)
        var results: [[String: Any]] = [], traces: [[String: Any]] = []
        for scene in scenes {
            let scenarioID = try h10String(scene, "id")
            let missing = Set(scene["requires_features"] as? [String] ?? []).subtracting(h10Features)
            if !missing.isEmpty {
                results.append(["id": scenarioID, "status": "not_applicable", "reason": "Factory Standard supported protocol lacks: " + missing.sorted().joined(separator: ","), "steps": []])
                continue
            }
            let setup = try h10Object(scene["setup"])
            var instances: [String: H10Instance] = [:]
            for instance in try h10Rows(setup["instances"]) {
                let id = try h10String(instance, "id")
                instances[id] = try H10Instance(id: id, source: h10String(instance, "source"), scenario: scenarioID, setup: setup)
            }
            let setupEvidence = instances.mapValues { $0.raw }
            var records: [[String: Any]] = [], stepTraces: [[String: Any]] = []
            for (index, action) in try h10Rows(scene["steps"]).enumerated() {
                let operation = try h10String(action, "operation"), instanceID = try h10String(action, "instance_id")
                let missing = Set(action["requires_features"] as? [String] ?? []).subtracting(h10Features)
                if !missing.isEmpty {
                    records.append(["index": index, "operation": operation, "status": "not_applicable", "reason": "Unsupported physical/protocol feature: " + missing.sorted().joined(separator: ","), "before": [:], "after": [:], "effects": []])
                    continue
                }
                let before = instances.mapValues { $0.observations() }
                let offsets = instances.mapValues { ($0.effects.count, $0.raw.count) }
                var failure: String?
                guard let instance = instances[instanceID] else { throw H10Error.malformed("instance identity") }
                do { failure = try await instance.execute(action, repo: repo) }
                catch { failure = "Actual operation error: " + String(describing: error) }
                let after = instances.mapValues { $0.observations() }
                let effects = instances.flatMap { id, value in Array(value.effects.dropFirst(offsets[id]!.0)) }
                let unmet = try h10Rows(action["expect"]).filter { !h10Assertion($0, instance: instanceID, before: before, after: after) }
                if !unmet.isEmpty {
                    failure = (failure.map { $0 + "; " } ?? "") + "Real observations do not meet: " + unmet.compactMap { $0["metric"] as? String }.joined(separator: ",")
                }
                let reason: Any = failure.map { String($0.prefix(512)) } ?? h10Null
                records.append(["index": index, "operation": operation, "status": failure == nil ? "pass" : "fail", "reason": reason, "before": before, "after": after, "effects": effects])
                try stepTraces.append(["index": index, "operation": operation, "instance_id": instanceID, "arguments": #require(action["arguments"]),
                                       "real_trace": instances.mapValues { value in Array(value.raw.dropFirst(offsets[value.id]!.1)) }])
            }
            let failures = records.filter { $0["status"] as? String == "fail" }
            results.append(["id": scenarioID, "status": failures.isEmpty ? "pass" : "fail", "reason": failures.isEmpty ? h10Null : String(failures.compactMap { $0["reason"] as? String }.joined(separator: "; ").prefix(512)), "steps": records])
            traces.append(["id": scenarioID, "setup_evidence": setupEvidence, "steps": stepTraces, "owners": instances.mapValues { value in ["gui": value.model != nil, "core": value.session != nil, "hardware_contract": value.hardware != nil, "simulation_contract": value.simulator != nil, "device_style": value.styleState != nil] }])
            #expect(instances.values.allSatisfy { $0.wire.starts == 0 })
        }
        let (gitStatus, gitOutput, _) = try await h10Process(["git", "-C", repo.path, "rev-parse", "HEAD"])
        guard gitStatus == 0 else { throw H10Error.malformed("revision") }
        let report: [String: Any] = ["schema_version": 1, "artifact": "neutral-controller-regression-results", "fixture_sha256": digest,
                                     "host_revision": String(decoding: gitOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                                     "host_id": "xtouch.compact", "qualification": "test-only-fake-device", "features": h10Features.sorted(), "results": results]
        let reportPath = destination.appendingPathComponent("controller-regression-results.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportPath)
        try JSONSerialization.data(withJSONObject: ["fixture_sha256": digest, "hardware_accessed": false, "traces": traces], options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("controller-regression-raw.json"))
        let (status, output, errors) = try await h10Process(["python3", "-B", shared.appendingPathComponent("scripts/validate_controller_regression.py").path, "--fixture", fixture.path, "--report", reportPath.path])
        print("H10_REPORT_VALIDATION " + String(decoding: output, as: UTF8.self))
        #expect(status == 0, "Report validity is distinct from scenario conformance: \(String(decoding: errors, as: UTF8.self))")
    }
#endif
