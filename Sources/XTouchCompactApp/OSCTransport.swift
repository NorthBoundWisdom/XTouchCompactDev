#if os(macOS)
    import Foundation
    import Network
    import XTouchCompactCore

    @MainActor protocol OSCTransport: AnyObject {
        func start(host: String, port: UInt16, onFailure: @escaping (any Error) -> Void) throws
        func send(_ data: Data)
        func stop()
    }

    @MainActor final class NetworkOSCTransport: OSCTransport {
        private var connection: NWConnection?
        private var generation = UUID()
        private var onFailure: ((any Error) -> Void)?
        func start(host: String, port: UInt16, onFailure: @escaping (any Error) -> Void) throws {
            stop()
            guard !host.isEmpty, port > 0, let port = NWEndpoint.Port(rawValue: port) else { throw OSCError.invalidAddress }
            self.onFailure = onFailure
            let generation = generation
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .udp)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                if case let .failed(error) = state {
                    Task { @MainActor [weak self] in guard self?.generation == generation else { return }; self?.onFailure?(error) }
                }
            }
            connection.start(queue: .main)
        }

        func send(_ data: Data) {
            let generation = generation
            connection?.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in guard self?.generation == generation else { return }; self?.onFailure?(error) }
            })
        }

        func stop() {
            generation = UUID(); connection?.cancel(); connection = nil; onFailure = nil
        }
    }
#endif
