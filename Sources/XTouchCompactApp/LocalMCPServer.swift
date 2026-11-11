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
            requests = requests.filter { Date().timeIntervalSince($0) < 60 }
            guard requests.count < 60 else { return (429, Data()) }
            requests.append(Date())
            if let batch = (try? JSONSerialization.jsonObject(with: request.body)) as? [[String: Any]] {
                guard !batch.isEmpty, batch.count <= 16 else { return (400, Data()) }
                var responses: [[String: Any]] = []
                for item in batch {
                    guard let body = try? JSONSerialization.data(withJSONObject: item) else { return (400, Data()) }
                    let (status, result) = respond(HTTPRequest(method: request.method, path: request.path, headers: request.headers, body: body))
                    if status == 202 {
                        continue
                    }
                    guard status == 200, let response = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any] else { return (status, result) }
                    responses.append(response)
                }
                return responses.isEmpty ? (202, Data()) : (200, (try? JSONSerialization.data(withJSONObject: responses)) ?? Data())
            }
            guard request.headers["content-type"]?.hasPrefix("application/json") == true,
                  let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  object["jsonrpc"] as? String == "2.0", let method = object["method"] as? String else { return (400, Data()) }
            if object["id"] == nil {
                return (202, Data())
            }
            let id = object["id"]!
            let response: [String: Any]
            do {
                let result: [String: Any] = if method == "initialize" {
                    ["protocolVersion": "2025-03-26", "capabilities": ["tools": [:]],
                     "serverInfo": ["name": "XTouchCompactDev", "version": "0.1.0"]]
                } else if method == "ping" {
                    [:]
                } else {
                    try handler?(object) ?? [:]
                }
                response = ["jsonrpc": "2.0", "id": id, "result": result]
            } catch {
                response = ["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": String(describing: error)]]
            }
            return (200, (try? JSONSerialization.data(withJSONObject: response)) ?? Data())
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

    enum MCPError: Error { case invalidRequest, denied, unknownTool, credentials(OSStatus) }

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
