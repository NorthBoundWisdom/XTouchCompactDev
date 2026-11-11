#if os(macOS)
    import Foundation
    import Network
    import Security

    @MainActor final class LocalMCPServer {
        private var listener: NWListener?
        private var peers: [UUID: MCPPeer] = [:]
        private var token = ""
        private var requests: [Date] = []
        init(authenticationToken: String = "") {
            token = authenticationToken
        }

        var handler: (([String: Any]) throws -> [String: Any])?
        var onError: ((any Error) -> Void)?
        private var ready = false
        var boundPort: UInt16? {
            guard ready, let port = listener?.port?.rawValue, port != 0 else { return nil }
            return port
        }

        var isRunning: Bool {
            listener != nil
        }

        func start(port: UInt16 = 8765, token: String) throws {
            stop()
            self.token = token
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.peers.count < 16 else { connection.cancel(); return }
                    let id = UUID()
                    let peer = MCPPeer(connection: connection) { [weak self] request in self?.respond(request) ?? (503, Data()) }
                    self.peers[id] = peer
                    peer.finished = { [weak self] in self?.peers.removeValue(forKey: id) }
                    peer.start()
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    Task { @MainActor in self?.ready = true }
                }
                if case let .failed(error) = state {
                    Task { @MainActor in self?.stop(); self?.onError?(error) }
                }
            }
            listener.start(queue: .main)
        }

        func stop() {
            ready = false
            listener?.cancel(); listener = nil
            for peer in Array(peers.values) {
                peer.cancel()
            }; peers.removeAll()
        }

        func respond(_ request: HTTPRequest) -> (Int, Data) {
            guard request.path == "/mcp" else { return (404, Data()) }
            guard request.headers["origin"] == nil else { return (403, Data()) }
            guard request.headers["authorization"] == "Bearer \(token)", !token.isEmpty else { return (401, Data()) }
            guard request.method == "POST" else { return (405, Data()) }
            guard request.headers["content-type"]?.hasPrefix("application/json") == true,
                  let json = try? JSONSerialization.jsonObject(with: request.body) else { return (400, Data()) }
            let isBatch = json is [Any]
            let items: [[String: Any]]
            if isBatch {
                guard let batch = json as? [[String: Any]], !batch.isEmpty, batch.count <= 16 else { return (400, Data()) }
                items = batch
            } else {
                guard let object = json as? [String: Any] else { return (400, Data()) }
                items = [object]
            }
            // Preflight and reserve the complete batch budget before any side effects.
            guard items.allSatisfy(validEnvelope) else { return (400, Data()) }
            requests = requests.filter { Date().timeIntervalSince($0) < 60 }
            guard requests.count + items.count <= 60 else { return (429, Data()) }
            requests.append(contentsOf: Array(repeating: Date(), count: items.count))
            let responses = items.compactMap { execute($0) }
            guard !responses.isEmpty else { return (202, Data()) }
            let result: Any = isBatch ? responses : responses[0]
            return (200, (try? JSONSerialization.data(withJSONObject: result)) ?? Data())
        }

        private func validEnvelope(_ object: [String: Any]) -> Bool {
            guard object["jsonrpc"] as? String == "2.0", object["method"] is String else { return false }
            guard let id = object["id"] else { return true }
            if id is String || id is NSNull {
                return true
            }
            if let number = id as? NSNumber {
                return CFGetTypeID(number) != CFBooleanGetTypeID() && number.doubleValue.isFinite
            }
            return false
        }

        private func execute(_ object: [String: Any]) -> [String: Any]? {
            guard object["id"] != nil, let method = object["method"] as? String else { return nil }
            let id = object["id"]!
            let response: [String: Any]
            do {
                let result: [String: Any] = if method == "initialize" {
                    ["protocolVersion": "2025-03-26", "capabilities": ["tools": [:]],
                     "serverInfo": ["name": "XTouchCompactDev", "version": "0.1.0"]]
                } else if method == "ping" {
                    [:]
                } else {
                    try handler?(object) ?? { throw MCPError.methodNotFound }()
                }
                response = ["jsonrpc": "2.0", "id": id, "result": result]
            } catch {
                response = ["jsonrpc": "2.0", "id": id, "error": ["code": (error as? MCPError == .methodNotFound ? -32601 : -32602), "message": String(describing: error)]]
            }
            return response
        }
    }

    struct HTTPRequest {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
        static func parse(_ data: Data) throws -> Self? {
            guard data.count <= 32768 else { throw MCPError.invalidRequest }
            guard let range = data.range(of: Data("\r\n\r\n".utf8)) else {
                if data.count > 8192 {
                    throw MCPError.invalidRequest
                }; return nil
            }
            guard range.lowerBound <= 8192, let header = String(data: data[..<range.lowerBound], encoding: .utf8) else { throw MCPError.invalidRequest }
            let lines = header.components(separatedBy: "\r\n")
            let start = lines[0].split(separator: " ")
            guard start.count == 3, start[2] == "HTTP/1.1" else { throw MCPError.invalidRequest }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw MCPError.invalidRequest }
                let key = line[..<colon].lowercased()
                guard headers[key] == nil else { throw MCPError.invalidRequest }
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard headers["transfer-encoding"] == nil, let length = Int(headers["content-length"] ?? "0"),
                  (0 ... 16384).contains(length) else { throw MCPError.invalidRequest }
            let body = data[range.upperBound...]
            guard body.count >= length else { return nil }
            guard body.count == length else { throw MCPError.invalidRequest }
            return Self(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body))
        }
    }

    enum MCPError: Error, Equatable { case invalidRequest, denied, unknownTool, methodNotFound, credentials(OSStatus) }

    @MainActor private final class MCPPeer {
        let connection: NWConnection
        let respond: (HTTPRequest) -> (Int, Data)
        var finished: (() -> Void)?
        var bytes = Data()
        private var timeout: Task<Void, Never>?
        init(connection: NWConnection, respond: @escaping (HTTPRequest) -> (Int, Data)) {
            self.connection = connection; self.respond = respond
        }

        func start() {
            connection.start(queue: .main)
            timeout = Task {
                try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled {
                    cancel()
                }
            }
            receive()
        }

        func cancel() {
            timeout?.cancel(); connection.cancel(); finished?()
        }

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let data {
                        self.bytes.append(data)
                    }
                    do {
                        if let request = try HTTPRequest.parse(self.bytes) {
                            let (status, body) = self.respond(request)
                            let header = "HTTP/1.1 \(status) Response\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                            self.connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] _ in Task { @MainActor in self?.cancel() } })
                        } else if complete || error != nil {
                            self.cancel()
                        } else {
                            self.receive()
                        }
                    } catch { self.cancel() }
                }
            }
        }
    }

    struct MCPTokenStore {
        func token() throws -> String {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: "dev.xtouchcompact.mcp", kSecAttrAccount as String: "localhost"]
            var item: CFTypeRef?
            let status = SecItemCopyMatching((query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, b in b }) as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8) {
                return token
            }
            guard status == errSecItemNotFound else { throw MCPError.credentials(status) }
            var bytes = [UInt8](repeating: 0, count: 32)
            let random = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard random == errSecSuccess else { throw MCPError.credentials(random) }
            let token = Data(bytes).base64EncodedString()
            let save = query.merging([kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { _, b in b }
            let saved = SecItemAdd(save as CFDictionary, nil)
            guard saved == errSecSuccess else { throw MCPError.credentials(saved) }
            return token
        }
    }
#endif
