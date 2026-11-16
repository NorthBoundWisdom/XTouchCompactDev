import CoreMIDI
import Darwin
import Foundation
import SurfaceControlContracts
import Testing
import XTouchCompactCore
@testable import XTouchSurfaceHardware

private func decode(_ text: String) throws -> OwnedRehearsalStep {
    try OwnedRehearsalSteps.decode(Data(text.utf8), map: FactoryStandardMap())
}

@Test func ownedStepProtocolIsStrictAndUsesFactoryControlIdentityNotCallerAddresses() throws {
    let value = try decode(#"{"operation":"input","control_id":"b.encoder.1","value":47,"connection_generation":"3"}"#)
    #expect(value == .input(.controlChange(channel: 0, number: 37, value: 47), generation: 3))
    #expect(try decode(#"{"operation":"input","control_id":"a.touch.1","value":false,"connection_generation":"1"}"#) == .input(.controlChange(channel: 0, number: 101, value: 0), generation: 1))
    for text in [#"{"operation":"input","control_id":"b.encoder.1","value":true,"connection_generation":"1"}"#,
                 #"{"operation":"input","control_id":"a.touch.1","value":127,"connection_generation":"1"}"#,
                 #"{"operation":"input","control_id":"b.encoder.1","value":128,"connection_generation":"1"}"#,
                 #"{"operation":"input","control_id":"b.encoder.1","value":0.5,"connection_generation":"1"}"#,
                 #"{"operation":"input","control_id":"b.encoder.01","value":1,"connection_generation":"1"}"#,
                 #"{"operation":"input","control_id":"b.encoder.1","value":1,"connection_generation":"01"}"#,
                 #"{"operation":"input","control_id":"b.encoder.1","value":1,"connection_generation":"1","endpoint":1}"#,
                 #"{"operation":"send","word":549519616}"#,
                 #"{"operation":"disconnect","operation":"reconnect"}"#,
                 #"{"operation":"disconnect","\u006fperation":"reconnect"}"#,
                 #"{"operation":"input","control_id":"global.layer.b","value":true,"connection_generation":"1"}"#]
    {
        #expect(throws: OwnedRehearsalFailure.self) { try decode(text) }
    }
}

@Test func ownedStepReaderRejectsFilesAndBoundsCommandsBeforeAnyTaskOrPublication() throws {
    var descriptors: [Int32] = [0, 0]
    #expect(pipe(&descriptors) == 0)
    defer { close(descriptors[0]); close(descriptors[1]) }
    let configuration = try CompactHardwareConfiguration(receiveChannel: 1, lightProtocol: .observed114)
    let reader = try OwnedRehearsalSteps(descriptor: descriptors[0], configuration: configuration)
    let line = Data("{\"operation\":\"disconnect\"}\n".utf8)
    let batch = Data((0 ..< 65).flatMap { _ in Array(line) })
    #expect(batch.withUnsafeBytes { write(descriptors[1], $0.baseAddress, $0.count) } == batch.count)
    #expect(try reader.drain().count == 64)
    #expect(try reader.drain().count == 1)
    let bad = Data(repeating: 32, count: 4097) + Data([10])
    #expect(bad.withUnsafeBytes { write(descriptors[1], $0.baseAddress, $0.count) } == bad.count)
    #expect(throws: OwnedRehearsalFailure.self) { try reader.drain() }
    let file = try #require(tmpfile())
    defer { fclose(file) }
    #expect(throws: OwnedRehearsalFailure.invalidPipe) { try OwnedRehearsalSteps(descriptor: fileno(file), configuration: configuration) }
}

@Test func ownedPrivateFinishHasNoDuplicateEofAndRejectsTrailingFrames() throws {
    for suffix in ["", "{\"operation\":\"disconnect\"}\n"] {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        defer { close(descriptors[0]) }
        let reader = try OwnedRehearsalSteps(descriptor: descriptors[0], configuration: .init(receiveChannel: 1, lightProtocol: .observed114))
        let bytes = Data(("{\"operation\":\"finish\"}\n" + suffix).utf8)
        _ = bytes.withUnsafeBytes { write(descriptors[1], $0.baseAddress, $0.count) }
        close(descriptors[1])
        if suffix.isEmpty {
            #expect(try reader.drain() == [.finish])
            #expect(try reader.drain().isEmpty)
        } else {
            #expect(throws: OwnedRehearsalFailure.self) { try reader.drain() }
        }
    }
}

@Test func ownedProfileIsSeparateAndRetentionRemainsAnIndependentCapability() throws {
    let configuration = try CompactHardwareConfiguration(receiveChannel: 1, lightProtocol: .observed114)
    let ordinary = try CompactHardwareSurface(instanceID: "test", epoch: "one", configuration: configuration, hardwareWriterID: "hardware", remoteWriterID: "remote")
    var owned = try CompactHardwareSurface(instanceID: "test", epoch: "one", configuration: configuration, hardwareWriterID: "hardware", remoteWriterID: "remote", ownedVirtualRehearsal: true)
    let retained = try CompactHardwareSurface(instanceID: "test", epoch: "one", configuration: configuration, hardwareWriterID: "hardware", remoteWriterID: "remote", inputEventCapacity: 4, ownedVirtualRehearsal: true)
    #expect(ordinary.controls.discovery().contract_version == "1.4")
    #expect(owned.controls.discovery().contract_version == "1.5")
    #expect(owned.controls.profile.id == "xtouch.compact.owned-virtual-rehearsal")
    #expect(owned.controls.profile.controls == ordinary.controls.profile.controls)
    #expect(owned.controls.inputEventCapacity == nil && retained.controls.inputEventCapacity == 4)
    #expect(owned.controls.profile.capabilities == ordinary.controls.profile.capabilities + ["session.owned_virtual_rehearsal"])
    try owned.transition(epoch: "new", connected: true, at: 1)
    #expect(owned.controls.profile.id == "xtouch.compact.owned-virtual-rehearsal" && owned.observedLayer == nil)
    #expect(try owned.controls.snapshot(at: 1).inputs.isEmpty)
}

@Test func ownedNativePacketBoundsApplyBeforeCopyOrCallbackHandoff() {
    var list = MIDIEventList()
    _ = MIDIEventListInit(&list, ._1_0)
    list.numPackets = 65
    if case .failure = CoreMIDIOwnedSystem.boundedWords(&list) {} else {
        Issue.record("Packet count overflow was accepted")
    }
    list.numPackets = 1
    list.packet.wordCount = 65
    if case .failure = CoreMIDIOwnedSystem.boundedWords(&list) {} else {
        Issue.record("Word count overflow was accepted")
    }
    list.packet.wordCount = 1
    list.packet.words.0 = 0x20B0_2501
    if case let .success(words) = CoreMIDIOwnedSystem.boundedWords(&list) {
        #expect(words == [0x20B0_2501])
    } else {
        Issue.record("A bounded actual packet was rejected")
    }
}
