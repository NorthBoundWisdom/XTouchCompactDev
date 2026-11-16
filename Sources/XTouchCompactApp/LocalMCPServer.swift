#if os(macOS)
    import Foundation
    import Network
    import Security
    import SurfacePluginContracts
    import XTouchCompactCore

    @MainActor final class LocalMCPServer {
        private var listener: NWListener?
        private var peers: [UUID: MCPPeer] = [:]
        private var token = ""
        private var requests: [Date] = []
        private let now: () -> Date
        let router: MCPRouter
        init(authenticationToken: String = "", serverVersion: String? = nil, now: @escaping () -> Date = Date.init) {
            token = authenticationToken
            self.now = now
            let info = Bundle.main.infoDictionary ?? [:]
            let build = (info["CFBundleVersion"] as? String) ?? "unbundled"
            let version = (info["CFBundleShortVersionString"] as? String).map { $0 + "+" + build } ?? build
            router = MCPRouter(serverVersion: serverVersion ?? version, now: now)
            router.handler = { [weak self] request in
                guard let self, let handler else {
                    throw MCPRPCError(code: -32601, message: "Method not found")
                }
                let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request.jsonValue)) as! [String: Any]
                do {
                    return try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: handler(object)))
                } catch let error as MCPError {
                    throw MCPRPCError(code: error == .methodNotFound ? -32601 : -32602, message: String(describing: error))
                }
            }
        }

        var handler: (([String: Any]) throws -> [String: Any])?
        var onError: ((any Error) -> Void)?
        var onReady: ((UInt16) -> Void)?
        var readSource: (() -> String)?
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
                Task { @MainActor [weak self] in
                    // Named owners keep member access explicit under Swift 6.1 and SwiftFormat.
                    guard let server = self, server.peers.count < 16 else { connection.cancel(); return }
                    let id = UUID()
                    let peer = MCPPeer(connection: connection, respond: { [weak self] request in
                        self?.response(request) ?? MCPReply(status: 503)
                    }, responseHeaders: { [weak self] in
                        self?.readSource.map { ["XTouch-Source": $0()] } ?? [:]
                    })
                    server.peers[id] = peer
                    peer.finished = { [weak self] in self?.peers.removeValue(forKey: id) }
                    peer.start()
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        ready = true
                        if let port = boundPort {
                            onReady?(port)
                        }
                    }
                }
                if case let .failed(error) = state {
                    Task { @MainActor [weak self] in self?.stop(); self?.onError?(error) }
                }
            }
            listener.start(queue: .main)
        }

        func stop() {
            ready = false
            router.stop()
            requests.removeAll()
            listener?.cancel(); listener = nil
            for peer in Array(peers.values) {
                peer.cancel()
            }; peers.removeAll()
        }

        func respond(_ request: HTTPRequest) -> (Int, Data) {
            let reply = response(request)
            return (reply.status, (try? reply.encodedBody()) ?? Data())
        }

        func response(_ request: HTTPRequest) -> MCPReply {
            guard request.path == "/mcp" else { return MCPReply(status: 404) }
            guard request.headers["origin"] == nil else { return MCPReply(status: 403) }
            guard request.headers["authorization"] == "Bearer \(token)", !token.isEmpty else { return MCPReply(status: 401) }
            if let required = request.headers["xtouch-require-source"], required != readSource?() {
                return MCPReply(status: 409)
            }
            if request.method == "DELETE" {
                return router.deleteSession(request.headers["mcp-session-id"])
            }
            guard request.method == "POST" else { return MCPReply(status: 405) }
            guard request.headers["content-type"]?.hasPrefix("application/json") == true else { return MCPReply(status: 400) }
            // The aligned protocol accepts one message, never a JSON-RPC batch.
            // Reject the whole array before charging the request budget or invoking any tool.
            if let value = try? JSONDecoder().decode(JSONValue.self, from: request.body), value.arrayValue != nil {
                return router.handle(request.body, headers: request.headers)
            }
            let time = now()
            requests = requests.filter { time.timeIntervalSince($0) < 60 }
            guard requests.count < 60 else { return MCPReply(status: 429) }
            requests.append(time)
            return router.handle(request.body, headers: request.headers)
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
        let respond: (HTTPRequest) -> MCPReply
        let responseHeaders: () -> [String: String]
        var finished: (() -> Void)?
        var bytes = Data()
        private var timeout: Task<Void, Never>?
        init(connection: NWConnection, respond: @escaping (HTTPRequest) -> MCPReply, responseHeaders: @escaping () -> [String: String]) {
            self.connection = connection; self.respond = respond; self.responseHeaders = responseHeaders
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
                Task { @MainActor [weak self] in
                    guard let peer = self else { return }
                    if let data {
                        peer.bytes.append(data)
                    }
                    do {
                        if let request = try HTTPRequest.parse(peer.bytes) {
                            let reply = peer.respond(request)
                            let body = try reply.encodedBody()
                            let sessionHeader = reply.sessionID.map { "Mcp-Session-Id: \($0)\r\n" } ?? ""
                            let sourceHeaders = peer.responseHeaders().map { "\($0.key): \($0.value)\r\n" }.joined()
                            let header = "HTTP/1.1 \(reply.status) Response\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n" + sessionHeader + sourceHeaders + "Connection: close\r\n\r\n"
                            peer.connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak peer] _ in Task { @MainActor [weak peer] in peer?.cancel() } })
                        } else if complete || error != nil {
                            peer.cancel()
                        } else {
                            peer.receive()
                        }
                    } catch { peer.cancel() }
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
