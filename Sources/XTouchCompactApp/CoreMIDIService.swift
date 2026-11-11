#if os(macOS)
    import CoreMIDI
    import Foundation
    import XTouchCompactCore
    import XTouchCompactLocalization

    enum CompactMIDIError: Error, LocalizedError {
        case operation(String, OSStatus)
        case outputUnavailable
        case packetOverflow
        case routeChanged

        var errorDescription: String? {
            switch self {
            case let .operation(operation, status): "\(operation) (OSStatus \(status))"
            case .outputUnavailable: "X-TOUCH COMPACT MIDI output not connected"
            case .packetOverflow: "MIDI packet could not be built"
            case .routeChanged: "MIDI route changed; test output locked."
            }
        }
    }

    /// Main-actor application boundary. Transport owns only CoreMIDI objects and a serial queue.
    /// Adapted from the same CoreMIDI callback and lifetime design as BCR2000Dev.
    @MainActor
    protocol MIDIService: AnyObject {
        var onMessages: (([MIDIMessage]) -> Void)? { get set }
        var onConnection: ((CompactMIDIConnection) -> Void)? { get set }
        func start() throws
        func select(inputID: Int32?, outputID: Int32?)
        func send(_ message: MIDIMessage) throws
        func sendPinned(_ message: MIDIMessage, inputID: Int32, outputID: Int32, generation: UInt64) throws
    }

    @MainActor
    final class CoreMIDIService: MIDIService {
        var onMessages: (([MIDIMessage]) -> Void)?
        var onConnection: ((CompactMIDIConnection) -> Void)?
        private var transport: CompactMIDITransport?

        func start() throws {
            guard transport == nil else { return }
            let newTransport = CompactMIDITransport(
                onMessages: { [weak self] messages in
                    Task { @MainActor [weak self] in self?.onMessages?(messages) }
                },
                onConnection: { [weak self] snapshot in
                    Task { @MainActor [weak self] in self?.onConnection?(snapshot) }
                }
            )
            try newTransport.start()
            transport = newTransport
        }

        func select(inputID: Int32?, outputID: Int32?) {
            transport?.select(inputID: inputID, outputID: outputID)
        }

        func send(_ message: MIDIMessage) throws {
            guard let transport else { throw CompactMIDIError.outputUnavailable }
            try transport.send(message)
        }

        func sendPinned(_ message: MIDIMessage, inputID: Int32, outputID: Int32, generation: UInt64) throws {
            guard let transport else { throw CompactMIDIError.outputUnavailable }
            try transport.send(message, expectedRoute: (inputID, outputID, generation))
        }
    }

    private final class CompactMIDITransport: @unchecked Sendable {
        typealias MessageCallback = @Sendable ([MIDIMessage]) -> Void
        typealias StatusCallback = @Sendable (CompactMIDIConnection) -> Void

        private let onMessages: MessageCallback
        private let onConnection: StatusCallback
        private let queue = DispatchQueue(label: "dev.xtouchcompact.coremidi")
        private var client: MIDIClientRef = 0
        private var inputPort: MIDIPortRef = 0
        private var outputPort: MIDIPortRef = 0
        private var connectedInput: MIDIEndpointRef = 0
        private var connectedOutput: MIDIEndpointRef = 0
        private var desiredInputID: Int32?
        private var desiredOutputID: Int32?
        private var active = false
        private var routeGeneration: UInt64 = 0

        init(onMessages: @escaping MessageCallback, onConnection: @escaping StatusCallback) {
            self.onMessages = onMessages
            self.onConnection = onConnection
        }

        deinit { stop() }

        func start() throws {
            try queue.sync {
                guard !active else { return }
                var newClient: MIDIClientRef = 0
                try check(MIDIClientCreateWithBlock("XTouchCompactDev" as CFString, &newClient) { [weak self] note in
                    guard note.pointee.messageID == .msgSetupChanged else { return }
                    self?.queue.async { [weak self] in self?.reconnect() }
                }, name: "Create MIDI client")
                client = newClient
                do {
                    try check(MIDIInputPortCreateWithProtocol(client, "Compact Input" as CFString, ._1_0,
                                                              &inputPort)
                    { [weak self] list, _ in
                        guard let self else { return }
                        let messages = Self.decode(list)
                        if !messages.isEmpty {
                            onMessages(messages)
                        }
                        }, name: "Create MIDI input")
                    try check(MIDIOutputPortCreate(client, "Compact Output" as CFString, &outputPort),
                              name: "Create MIDI output")
                } catch {
                    if inputPort != 0 {
                        MIDIPortDispose(inputPort); inputPort = 0
                    }
                    if outputPort != 0 {
                        MIDIPortDispose(outputPort); outputPort = 0
                    }
                    MIDIClientDispose(client); client = 0
                    throw error
                }
                active = true
                reconnect()
            }
        }

        func stop() {
            queue.sync {
                guard active else { return }
                if connectedInput != 0 {
                    MIDIPortDisconnectSource(inputPort, connectedInput)
                }
                MIDIPortDispose(inputPort)
                MIDIPortDispose(outputPort)
                MIDIClientDispose(client)
                inputPort = 0; outputPort = 0; client = 0
                connectedInput = 0; connectedOutput = 0; active = false
            }
        }

        func select(inputID: Int32?, outputID: Int32?) {
            queue.async { [weak self] in
                guard let self else { return }
                desiredInputID = inputID
                desiredOutputID = outputID
                reconnect()
            }
        }

        func send(_ message: MIDIMessage, expectedRoute: (Int32, Int32, UInt64)? = nil) throws {
            try queue.sync {
                guard active, outputPort != 0, connectedOutput != 0 else {
                    throw CompactMIDIError.outputUnavailable
                }
                if let expectedRoute {
                    var inputID: Int32 = 0; var outputID: Int32 = 0
                    guard connectedInput != 0,
                          MIDIObjectGetIntegerProperty(connectedInput, kMIDIPropertyUniqueID, &inputID) == noErr,
                          MIDIObjectGetIntegerProperty(connectedOutput, kMIDIPropertyUniqueID, &outputID) == noErr,
                          inputID == expectedRoute.0, outputID == expectedRoute.1, routeGeneration == expectedRoute.2 else { throw CompactMIDIError.routeChanged }
                }
                var packets = MIDIPacketList()
                let start = MIDIPacketListInit(&packets)
                let data = message.midi1Bytes
                let added = data.withUnsafeBufferPointer { bytes -> UnsafeMutablePointer<MIDIPacket>? in
                    MIDIPacketListAdd(&packets, MemoryLayout<MIDIPacketList>.size, start,
                                      0, bytes.count, bytes.baseAddress!)
                }
                guard added != nil else { throw CompactMIDIError.packetOverflow }
                try check(MIDISend(outputPort, connectedOutput, &packets), name: "Send MIDI")
            }
        }

        private func reconnect() {
            guard active else { return }
            routeGeneration &+= 1
            if connectedInput != 0 {
                MIDIPortDisconnectSource(inputPort, connectedInput)
            }
            connectedInput = 0; connectedOutput = 0
            let sources = Self.endpoints(count: MIDIGetNumberOfSources, at: MIDIGetSource)
            let destinations = Self.endpoints(count: MIDIGetNumberOfDestinations, at: MIDIGetDestination)
            func choose(_ endpoints: [(CompactMIDIEndpoint, MIDIEndpointRef)], id: Int32?)
                -> (CompactMIDIEndpoint, MIDIEndpointRef)?
            {
                if let id {
                    return endpoints.first { $0.0.id == id }
                }
                // Never bind another MIDI controller just because it is the first source.
                return endpoints.first { $0.0.name.uppercased().contains("X-TOUCH COMPACT") }
            }
            let source = choose(sources, id: desiredInputID)
            let output = choose(destinations, id: desiredOutputID)
            var error: LocalizedMessage?
            if let source {
                let result = MIDIPortConnectSource(inputPort, source.1, nil)
                if result == noErr {
                    connectedInput = source.1
                } else {
                    error = LocalizedMessage("MIDI input connection failed: %@", String(result))
                }
            }
            if let output {
                connectedOutput = output.1
            }
            onConnection(CompactMIDIConnection(generation: routeGeneration,
                                               inputs: sources.map(\.0), outputs: destinations.map(\.0),
                                               connectedInput: connectedInput == 0 ? nil : source?.0,
                                               connectedOutput: connectedOutput == 0 ? nil : output?.0,
                                               error: error))
        }

        private static func endpoints(count: () -> Int, at: (Int) -> MIDIEndpointRef)
            -> [(CompactMIDIEndpoint, MIDIEndpointRef)]
        {
            (0 ..< count()).compactMap { index in
                let endpoint = at(index)
                guard endpoint != 0 else { return nil }
                var id: Int32 = 0
                guard MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id) == noErr,
                      id != 0 else { return nil }
                var offline: Int32 = 0
                if MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline) == noErr,
                   offline != 0
                {
                    return nil
                }
                var name: Unmanaged<CFString>?
                let result = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
                let label = result == noErr ? (name?.takeRetainedValue() as String? ?? "MIDI Endpoint") : "MIDI Endpoint"
                return (CompactMIDIEndpoint(id: id, name: label), endpoint)
            }
        }

        private static func decode(_ list: UnsafePointer<MIDIEventList>) -> [MIDIMessage] {
            guard let packetOffset = MemoryLayout<MIDIEventList>.offset(of: \.packet),
                  let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \.words) else { return [] }
            var packet = UnsafeRawPointer(list).advanced(by: packetOffset)
                .assumingMemoryBound(to: MIDIEventPacket.self)
            var decoded: [MIDIMessage] = []
            for _ in 0 ..< list.pointee.numPackets {
                let words = UnsafeRawPointer(packet).advanced(by: wordsOffset)
                    .assumingMemoryBound(to: UInt32.self)
                var i = 0
                let count = Int(packet.pointee.wordCount)
                while i < count {
                    let word = words[i]
                    if let message = MIDI1UMPCodec.decode(word) {
                        decoded.append(message)
                    }
                    i += min(Self.wordCount(word), count - i)
                }
                packet = UnsafePointer(MIDIEventPacketNext(packet))
            }
            return decoded
        }

        /// Skip non-channel UMP payloads by their complete packet size.
        private static func wordCount(_ word: UInt32) -> Int {
            switch (word >> 28) & 0xF {
            case 0x0, 0x1, 0x2, 0x6, 0x7: 1
            case 0x3, 0x4, 0x8, 0x9, 0xA: 2
            case 0xB, 0xC: 3
            default: 4
            }
        }

        private func check(_ status: OSStatus, name: String) throws {
            guard status == noErr else { throw CompactMIDIError.operation(name, status) }
        }
    }
#endif
