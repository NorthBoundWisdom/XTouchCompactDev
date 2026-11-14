import SurfaceControlContracts
import Testing
@testable import XTouchCompactCore

@Test func hardwareProfileSeparatesTouchAndPositionAndHasNoMotionFeedback() throws {
    let configuration = try CompactHardwareConfiguration(receiveChannel: 1, lightProtocol: .observed114)
    let profile = configuration.profile
    _ = try SurfaceControlSession(instanceID: "test", epoch: "test", profile: profile)
    #expect(profile.controls.count == 182)
    #expect(profile.controls.allSatisfy { $0.accepts_input == false && $0.hold == nil })
    let fadersHaveNoFeedback = profile.controls.filter { $0.id.contains(".fader.") }.allSatisfy(\.feedback_kinds.isEmpty)
    #expect(fadersHaveNoFeedback)
    #expect(profile.controls.filter { $0.id.contains(".touch.") }.count == 18)
    let other = try CompactHardwareConfiguration(receiveChannel: 0, lightProtocol: .observed114)
    #expect(profile.mappingRevision == other.profile.mappingRevision)
    #expect(profile.capabilities != other.profile.capabilities)
}

@Test func everyHardwareDisplayControlAndLegalValueCannotEncodeMotorOrProgramChange() throws {
    let configuration = try CompactHardwareConfiguration(receiveChannel: 1, lightProtocol: .observed114)
    for control in configuration.profile.controls where !control.feedback_kinds.isEmpty {
        let part = try #require(control.id.split(separator: ".").last)
        let index = try #require(Int(part))
        let messages: [HardwareDisplayMessage] = if control.id.contains(".button.") {
            ButtonLight.allCases.map { .buttonLight(button: index, light: $0) }
        } else {
            (0 ... 28).map { .ringDisplay(encoder: index, value: UInt8($0)) } + RingStyle.allCases.map { .ringStyle(encoder: index, style: $0) }
        }
        for message in messages {
            let word = try message.word(configuration: configuration)
            let status = (word >> 16) & 0xF0, number = (word >> 8) & 0x7F
            #expect(status != 0xC0)
            #expect(!(status == 0xB0 && (1 ... 9).contains(number)))
            #expect(status == 0xB0 || status == 0x90)
            #expect((word >> 16) & 0x0F == 1)
        }
    }
}
