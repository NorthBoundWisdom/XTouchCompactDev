#if os(macOS)
    import Foundation
    import XTouchCompactCore

    struct CaptureSessionMetadata {
        var sessionID = UUID().uuidString
        var applicationVersion: String?
        var sourceRevision: String?
        var sourceTreeDirty: Bool?
        var connectedInput: CompactMIDIEndpoint?
        var connectedOutput: CompactMIDIEndpoint?
        var selectedInputID: Int32?
        var selectedOutputID: Int32?
        var configuredTX: Int?
        var configuredGlobalRX: Int?
        var ledProtocol: String?
        var hardwareMode: Bool?
        var listenOnly: Bool?

        var json: [String: Any] {
            func endpoint(_ value: CompactMIDIEndpoint?) -> Any {
                value.map { ["id": $0.id, "name": $0.name] as [String: Any] } ?? NSNull()
            }
            return [
                "sessionID": sessionID,
                "applicationVersion": applicationVersion as Any? ?? NSNull(),
                "sourceRevision": sourceRevision as Any? ?? NSNull(),
                "sourceTreeDirty": sourceTreeDirty as Any? ?? NSNull(),
                "deviceModel": "X-TOUCH COMPACT", "firmwareVersion": NSNull(),
                "actualGlobalReceiveChannel": NSNull(),
                "connectedInput": endpoint(connectedInput), "connectedOutput": endpoint(connectedOutput),
                "selectedInputID": selectedInputID as Any? ?? NSNull(),
                "selectedOutputID": selectedOutputID as Any? ?? NSNull(),
                "configuredTransmitChannel": configuredTX as Any? ?? NSNull(),
                "configuredGlobalReceiveChannel": configuredGlobalRX as Any? ?? NSNull(),
                "ledProtocol": ledProtocol as Any? ?? NSNull(),
                "hardwareMode": hardwareMode as Any? ?? NSNull(), "listenOnly": listenOnly as Any? ?? NSNull(),
            ]
        }
    }
#endif
