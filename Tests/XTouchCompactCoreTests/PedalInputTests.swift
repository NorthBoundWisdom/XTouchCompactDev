import Testing
@testable import XTouchCompactCore

/// Factory table: expression CC 26 / 63, footswitch CC 27 / 64 (layer A / B).
/// On RX, CC 26 / 27 are encoder 1 / 2 ring displays — pedals have no feedback address.
@Test func pedalInputsDecodeOnBothLayersWithoutFeedbackAddress() throws {
    for tx: UInt8 in [0, 9, 15] {
        let map = try FactoryStandardMap(transmitChannel: tx, globalReceiveChannel: 4)
        for (layer, expression, footswitch) in [(CompactLayer.a, UInt8(26), UInt8(27)), (.b, 63, 64)] {
            #expect(map.inputAddress(for: .expression, layer: layer) == MIDIAddress(messageType: .controlChange, channel: tx, number: expression))
            #expect(map.inputAddress(for: .footswitch, layer: layer) == MIDIAddress(messageType: .controlChange, channel: tx, number: footswitch))
            let exp = try #require(map.decode(.controlChange(channel: tx, number: expression, value: 77)))
            #expect(exp == CompactInput(control: .expression, layer: layer, value: 77))
            #expect(map.decode(.controlChange(channel: tx, number: footswitch, value: 127)) ==
                CompactInput(control: .footswitch, layer: layer, value: 127, isPressed: true))
            #expect(map.decode(.controlChange(channel: tx, number: footswitch, value: 0))?.isPressed == false)
            #expect(map.decode(.controlChange(channel: (tx + 1) % 16, number: expression, value: 1)) == nil)
        }
        #expect(map.feedbackAddress(for: .expression) == nil)
        #expect(map.feedbackAddress(for: .footswitch) == nil)
        // Ring displays on the same CC numbers are a separate RX address on the Global channel.
        #expect(try map.encoderRingValue(encoder: 1, display: .position(3)) == .controlChange(channel: 4, number: 26, value: 3))
    }
}

@Test func pedalsStayOutsideTheBuiltInBringUpCoverage() {
    let all = CompactInputGroup.allCases.flatMap(\.controls)
    #expect(all.count == CompactGeometry.totalInputActions)
    #expect(!all.contains(.expression) && !all.contains(.footswitch))
}

@Test func mockPedalsUseTXChannelAndPhysicalLayer() throws {
    let map = try FactoryStandardMap(transmitChannel: 2, globalReceiveChannel: 5)
    var mock = MockXTouchCompact(map: map, lightProtocol: .manual)
    #expect(try mock.moveExpression(90) == [.controlChange(channel: 2, number: 26, value: 90)])
    #expect(mock.pressFootswitch(isDown: true) == [.controlChange(channel: 2, number: 27, value: 127)])
    #expect(mock.expression == 90 && mock.footswitchDown)
    mock.selectPhysicalLayer(.b)
    #expect(try mock.moveExpression(0) == [.controlChange(channel: 2, number: 63, value: 0)])
    #expect(mock.pressFootswitch(isDown: false) == [.controlChange(channel: 2, number: 64, value: 0)])
    #expect(throws: CompactError.self) { _ = try mock.moveExpression(128) }
}

@Test func pedalAssignmentsDriveParametersWithoutMotorsOrLights() throws {
    var config = SurfaceConfiguration.neutral
    config.assignments.append(.init(control: .expression, layer: .a, action: .parameter("a.Encoder.3")))
    config.assignments.append(.init(control: .footswitch, layer: .a, action: .set("a.Encoder.4", 100)))
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.loadConfiguration(config)
    _ = try session.connect()
    let expression = try session.receive([.controlChange(channel: 0, number: 26, value: 127)])
    #expect(expression.inputs.first?.control == .expression)
    #expect(session.parameters.values["a.Encoder.3"] == 127)
    // Only the bound encoder's ring follows; no motor or LED is a pedal echo.
    #expect(expression.feedback == [.controlChange(channel: 0, number: 28, value: 13)])
    let press = try session.receive([.controlChange(channel: 0, number: 27, value: 127)])
    #expect(session.parameters.values["a.Encoder.4"] == 100)
    #expect(press.feedback.allSatisfy {
        if case let .controlChange(_, number, _) = $0 {
            return number == 29
        }
        return false
    })
    // Other-layer pedal input is evidence only, never an active-bank edit.
    _ = try session.receive([.controlChange(channel: 0, number: 63, value: 0)])
    #expect(session.parameters.values["a.Encoder.3"] == 127)
    #expect(session.state.observedLayer == .b)

    var invalid = SurfaceConfiguration.neutral
    invalid.assignments.append(.init(control: .expression, layer: .a, action: .agent(1)))
    #expect(throws: ParameterError.self) { try invalid.validate() }
}

@Test func observerRecordsPedalsSeparatelyFromCoverage() throws {
    let map = try FactoryStandardMap()
    var observer = CompactInputObserver()
    #expect(observer.expressionValue == nil && observer.footswitchDown == nil)
    observer.receive(.controlChange(channel: 0, number: 63, value: 12), map: map, at: .init(timeIntervalSince1970: 1))
    observer.receive(.controlChange(channel: 0, number: 27, value: 127), map: map, at: .init(timeIntervalSince1970: 2))
    #expect(observer.expressionValue == 12)
    #expect(observer.footswitchDown == true)
    #expect(observer.seenControls == [.expression, .footswitch])
}
