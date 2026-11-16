import Testing
@testable import XTouchCompactCore

private func authorizedSession() throws -> CompactSession {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.loadConfiguration(.init(parameters: [.init(id: "value", name: "Value", minimum: 0, maximum: 127, defaultValue: 0)],
                                            assignments: [.init(control: .fader(1), layer: .a, action: .parameter("value")),
                                                          .init(control: .encoder(1), layer: .a, action: .parameter("value"))]), resetValues: true)
    return session
}

@Test func dynamicMotorRevocationAppliesToUndoAndNeverGrantsAgentAuthority() throws {
    var session = try authorizedSession()
    _ = try session.setParameter("value", value: 100)
    var context = session.writeAuthorization; context.allowsMechanisms = false
    session.configureWriteAuthorization(context)
    let messages = try session.undo()
    #expect(session.parameters.values["value"] == 0)
    #expect(messages.allSatisfy {
        if case .controlChange(_, 1 ... 9, _) = $0 {
            false
        } else {
            true
        }
    })
    #expect(!session.state.isMotorPending(1))
}

@Test func dynamicWriteGateChecksEveryTrustedIdentityAndHistoryAtomically() throws {
    var session = try authorizedSession()
    _ = try session.setParameter("value", value: 100)
    var context = session.writeAuthorization; context.allowsValues = false
    session.configureWriteAuthorization(context)
    #expect(throws: ParameterWriteAuthorizationError.writesDenied) { try session.setParameter("value", value: 10) }
    #expect(throws: ParameterWriteAuthorizationError.writesDenied) { try session.setParameter("value", value: 10, fromAgent: true) }
    #expect(throws: ParameterWriteAuthorizationError.writesDenied) { try session.undo() }
    #expect(session.canUndo)
    #expect(session.parameters.values["value"] == 100)
    context.allowsValues = true; context.allowedWriters = [.history]
    session.configureWriteAuthorization(context)
    #expect(throws: ParameterWriteAuthorizationError.identityDenied) { try session.setParameter("value", value: 10) }
    _ = try session.undo()
    #expect(session.parameters.values["value"] == 0)
}

@Test func dynamicAuthorizationPinsRouteBindingAndParameterIdentity() throws {
    let context = ParameterWriteAuthorization(routeGeneration: 2, bindingGeneration: 3, allowedParameters: ["allowed"])
    #expect(throws: ParameterWriteAuthorizationError.staleContext) { try context.validate(parameterID: "allowed", writer: .interface, routeGeneration: 1, bindingGeneration: 3) }
    #expect(throws: ParameterWriteAuthorizationError.staleContext) { try context.validate(parameterID: "allowed", writer: .interface, routeGeneration: 2, bindingGeneration: 2) }
    #expect(throws: ParameterWriteAuthorizationError.parameterDenied("other")) { try context.validate(parameterID: "other", writer: .interface, routeGeneration: 2, bindingGeneration: 3) }
}

@Test func externalAuthorityCorrectionUsesOneOwnerRejectsStaleAndNeverProducesMotors() throws {
    var session = try authorizedSession()
    _ = try session.setParameter("value", value: 100)
    let context = session.writeAuthorization
    let messages = try session.receiveAuthority("value", accepted: false, actualValue: 10, routeGeneration: context.routeGeneration, bindingGeneration: context.bindingGeneration)
    #expect(session.parameters.values["value"] == 10)
    #expect(session.canUndo)
    #expect(messages.allSatisfy {
        if case .controlChange(_, 1 ... 9, _) = $0 {
            false
        } else {
            true
        }
    })
    #expect(throws: ParameterWriteAuthorizationError.invalidAuthorityValue) { try session.receiveAuthority("value", accepted: true, actualValue: .nan, routeGeneration: context.routeGeneration, bindingGeneration: context.bindingGeneration) }
    #expect(throws: ParameterWriteAuthorizationError.staleContext) { try session.receiveAuthority("value", accepted: true, actualValue: 90, routeGeneration: context.routeGeneration + 1, bindingGeneration: context.bindingGeneration) }
    #expect(throws: ParameterWriteAuthorizationError.invalidAuthorityValue) { try session.receiveAuthority("value", accepted: false, actualValue: 128, routeGeneration: context.routeGeneration, bindingGeneration: context.bindingGeneration) }
    #expect(session.parameters.values["value"] == 10)
    _ = try session.receiveAuthority("value", accepted: true, actualValue: 10, routeGeneration: context.routeGeneration, bindingGeneration: context.bindingGeneration)
    _ = try session.setParameter("value", value: 20)
    #expect(session.parameters.values["value"] == 20)
}

@Test func deviceInputIdentityCannotBorrowInterfacePermission() throws {
    var session = try authorizedSession()
    var context = session.writeAuthorization; context.allowedWriters = [.interface]
    session.configureWriteAuthorization(context)
    let message = MIDIMessage.controlChange(channel: 0, number: 10, value: 100)
    #expect(throws: ParameterWriteAuthorizationError.identityDenied) { try session.receive([message]) }
    #expect(session.parameters.values["value"] == 0)
    context.allowedWriters = [.hardware]
    session.configureWriteAuthorization(context)
    _ = try session.receive([message])
    #expect(session.parameters.values["value"] == 100)
    #expect(throws: ParameterWriteAuthorizationError.identityDenied) { try session.setParameter("value", value: 20) }
}

private func historyValues(_ session: CompactSession, _ key: String) throws -> [[String: Double]] {
    try #require(Mirror(reflecting: session).children.first { $0.label == key }?.value as? [[String: Double]])
}

@Test func restrictedHistoryWritesOnlyChangedParametersAndPreservesStacksOnRefusal() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.loadConfiguration(.init(parameters: [
        .init(id: "first", name: "First", minimum: 0, maximum: 127, defaultValue: 0),
        .init(id: "second", name: "Second", minimum: 0, maximum: 127, defaultValue: 0),
    ], assignments: []), resetValues: true)
    _ = try session.setParameter("first", value: 100)
    var context = session.writeAuthorization; context.allowedParameters = ["first"]
    session.configureWriteAuthorization(context)
    _ = try session.undo() // Unchanged `second` is not an attempted write.
    #expect(session.parameters.values == ["first": 0, "second": 0])
    _ = try session.redo()
    #expect(session.parameters.values == ["first": 100, "second": 0])
    context.allowedParameters = []
    session.configureWriteAuthorization(context)
    let before = session.parameters.values
    let undo = try historyValues(session, "undoStack"), redo = try historyValues(session, "redoStack")
    #expect(throws: ParameterWriteAuthorizationError.parameterDenied("first")) { try session.undo() }
    #expect(session.parameters.values == before)
    #expect(try historyValues(session, "undoStack") == undo)
    #expect(try historyValues(session, "redoStack") == redo)
    context.allowedParameters = ["first"]; session.configureWriteAuthorization(context)
    _ = try session.undo()
    context.allowedParameters = []; session.configureWriteAuthorization(context)
    let beforeRedo = session.parameters.values
    let undoAfter = try historyValues(session, "undoStack"), redoAfter = try historyValues(session, "redoStack")
    #expect(throws: ParameterWriteAuthorizationError.parameterDenied("first")) { try session.redo() }
    #expect(session.parameters.values == beforeRedo)
    #expect(try historyValues(session, "undoStack") == undoAfter)
    #expect(try historyValues(session, "redoStack") == redoAfter)
}

@Test func sceneRefusalCannotPartiallyCommitValuesOrHistory() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.loadConfiguration(.init(parameters: [
        .init(id: "first", name: "First", minimum: 0, maximum: 127, defaultValue: 0),
        .init(id: "second", name: "Second", minimum: 0, maximum: 127, defaultValue: 0),
    ], assignments: [], scenes: [.init(id: "scene", name: "Scene", values: ["first": 100, "second": 100])]), resetValues: true)
    var context = session.writeAuthorization; context.allowedParameters = ["first"]
    session.configureWriteAuthorization(context)
    let before = session.parameters.values
    #expect(throws: ParameterWriteAuthorizationError.parameterDenied("second")) { try session.recallScene(id: "scene") }
    #expect(session.parameters.values == before)
    #expect(!session.canUndo && !session.canRedo)
}
