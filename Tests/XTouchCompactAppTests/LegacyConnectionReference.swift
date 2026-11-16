#if os(macOS)
    import Foundation
    import SurfaceConnectionState
    @testable import XTouchCompactApp
    @testable import XTouchCompactCore

    /// a5324f7 old native route predicate and publication ownership, now tests only.
    struct LegacyConnectionReference: CompactConnectionReference {
        let log = CompactContextAudit()
        private(set) var published = CompactMIDIConnection()
        var audit: any CompactContextAuditReader {
            log
        }

        func willPublish(_ next: CompactMIDIConnection, current: CompactMIDIConnection, changed: Bool, generation: UInt64) {
            let expected = next.isConnected != published.isConnected || next.connectedInput?.id != published.connectedInput?.id
                || next.connectedOutput?.id != published.connectedOutput?.id || next.generation != published.generation
            log.compare("route.previous.full", input: String(reflecting: next), native: String(reflecting: published), candidate: String(reflecting: current))
            log.compare("route.transition", input: String(reflecting: next), native: "changed=\(expected)|generation=\(next.generation)", candidate: "changed=\(changed)|generation=\(generation)")
        }

        mutating func didPublish(_ next: CompactMIDIConnection, actual: CompactMIDIConnection, semantic: ConnectionSnapshot<EmptyConnectionIdentity>, generation: UInt64) {
            published = next
            log.compare("route.published.full", input: String(reflecting: next), native: String(reflecting: published), candidate: String(reflecting: actual))
            log.compare("route.published.semantic", input: String(reflecting: next), native: String(reflecting: published.neutralRoute), candidate: String(reflecting: semantic))
            log.compare("route.published.generation", input: "published", native: String(published.generation), candidate: String(generation))
        }

        func admission(captured: CompactMIDIConnection, current: CompactMIDIConnection, actual: Bool) {
            let expected = current.generation == captured.generation && current.connectedInput?.id == captured.connectedInput?.id && current.connectedOutput?.id == captured.connectedOutput?.id
            log.compare("route.dispatch.admission", input: "captured=" + String(reflecting: captured) + "|current=" + String(reflecting: current), native: String(expected), candidate: String(actual))
        }
    }
#endif
