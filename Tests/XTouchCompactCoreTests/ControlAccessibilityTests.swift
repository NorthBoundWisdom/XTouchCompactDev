import Testing
@testable import XTouchCompactCore

@Test func allEightyNinePhysicalControlsHaveUniqueLayerIndependentAccessibilityIdentities() {
    let controls = CompactInputGroup.allCases.flatMap(\.controls)
    let ids = controls.map(\.accessibilityID)
    #expect(controls.count == 89 && ids.count == 89)
    #expect(Set(ids).count == 89)
    #expect(Set(ids).isDisjoint(with: [CompactControl.expression.accessibilityID, CompactControl.footswitch.accessibilityID]))
    for layer in CompactLayer.allCases {
        #expect(controls.map(\.accessibilityID) == ids)
        #expect(!ids.contains { $0.hasPrefix("surface.layer.\(layer.rawValue)") })
    }
    #expect(CompactControl.fader(1).accessibilityID == "surface.fader.1")
    #expect(CompactControl.faderTouch(1).accessibilityID == "surface.touch.1")
    #expect(CompactControl.encoder(16).accessibilityID != CompactControl.encoderPush(16).accessibilityID)
}
