import Foundation
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

public enum SimulatorHTTPError: Error { case socket, bind, listen, read, request }

/// A small blocking HTTP transport, isolated from CoreMIDI and UI. Each request is
/// handled serially, so a consumer can never race two mutations of a value session.
public final class LoopbackHTTPServer {
    private let descriptor: Int32
    public let port: UInt16
    private let token: String
    public init(port: UInt16, token: String) throws {
        guard !token.isEmpty, !token.contains("\r"), !token.contains("\n") else { throw SimulatorHTTPError.request }
        self.token = token
        #if canImport(Darwin)
            let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        #else
            let socketFD = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard socketFD >= 0 else { throw SimulatorHTTPError.socket }
        var reuse: Int32 = 1
        _ = withUnsafePointer(to: &reuse) { setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size)) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { close(socketFD); throw SimulatorHTTPError.bind }
        guard listen(socketFD, 16) == 0 else { close(socketFD); throw SimulatorHTTPError.listen }
        var bound = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &size) }
        }
        descriptor = socketFD
        self.port = UInt16(bigEndian: bound.sin_port)
    }

    deinit { close(descriptor) }

    public func run(handler: (Data) -> Data) throws -> Never {
        try run(nextDeadline: { nil }, maintenance: {}, handler: handler)
    }

    /// Serve requests serially. While idle, wait for a connection at most until
    /// `nextDeadline()` (a `systemUptime` value) and then call `maintenance()`, so host
    /// timers run without a request. A request in progress delays maintenance by at most
    /// its fixed read budget; the handler is expected to run due maintenance itself first.
    public func run(nextDeadline: () -> Double?, maintenance: () -> Void, handler: (Data) -> Data) throws -> Never {
        signal(SIGPIPE, SIG_IGN)
        while true {
            var listening = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let wait = nextDeadline().map { deadline -> Int32 in
                let remaining = (deadline - ProcessInfo.processInfo.systemUptime) * 1000
                return Int32(min(max(0, remaining.rounded(.up)), 60000))
            } ?? -1
            let ready = poll(&listening, 1, wait)
            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                throw SimulatorHTTPError.socket
            }
            if ready == 0 {
                maintenance()
                continue
            }
            let peer = accept(descriptor, nil, nil)
            if peer < 0 {
                if errno == EINTR {
                    continue
                }; throw SimulatorHTTPError.socket
            }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            _ = withUnsafePointer(to: &timeout) { setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }
            _ = withUnsafePointer(to: &timeout) { setsockopt(peer, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }
            let response: (Int, Data)
            do {
                let request = try readRequest(peer)
                if request.path != "/mcp" {
                    response = (404, Data())
                } else if request.headers["origin"] != nil {
                    response = (403, Data())
                } else if request.headers["authorization"] != "Bearer \(token)" {
                    response = (401, Data())
                } else if let version = request.headers["mcp-protocol-version"], !["2025-11-25", "2026-07-28"].contains(version) {
                    response = (400, Data())
                } else if request.method != "POST" {
                    response = (405, Data())
                } else if request.headers["content-type"]?.hasPrefix("application/json") != true {
                    response = (400, Data())
                } else {
                    let body = handler(request.body); response = (body.isEmpty ? 202 : 200, body)
                }
            } catch { response = (400, Data()) }
            let head = "HTTP/1.1 \(response.0) Response\r\nContent-Type: application/json\r\nContent-Length: \(response.1.count)\r\nConnection: close\r\n\r\n"
            let bytes = Data(head.utf8) + response.1
            bytes.withUnsafeBytes { buffer in
                var sent = 0
                while sent < bytes.count {
                    let count = send(peer, buffer.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                    if count <= 0 {
                        break
                    }
                    sent += count
                }
            }
            close(peer)
        }
    }

    private struct Request { var method: String; var path: String; var headers: [String: String]; var body: Data }
    private func readRequest(_ peer: Int32) throws -> Request {
        var bytes = Data()
        var storage = [UInt8](repeating: 0, count: 4096)
        // A per-recv timeout alone permits an unauthenticated slow drip to occupy
        // this serial listener forever. The complete request has one fixed budget.
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while bytes.count <= 32768 {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw SimulatorHTTPError.read }
            var readiness = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
            let ready = poll(&readiness, 1, Int32(max(1, (remaining * 1000).rounded(.up))))
            if ready < 0, errno == EINTR {
                continue
            }
            guard ready > 0 else { throw SimulatorHTTPError.read }
            let count = recv(peer, &storage, storage.count, 0)
            guard ProcessInfo.processInfo.systemUptime <= deadline, count > 0 else { throw SimulatorHTTPError.read }
            bytes.append(contentsOf: storage.prefix(count))
            guard let split = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                guard bytes.count <= 8192 else { throw SimulatorHTTPError.request }; continue
            }
            guard split.lowerBound <= 8192, let header = String(data: bytes[..<split.lowerBound], encoding: .utf8) else { throw SimulatorHTTPError.request }
            let lines = header.components(separatedBy: "\r\n")
            let start = lines[0].split(separator: " ")
            guard start.count == 3, start[2] == "HTTP/1.1" else { throw SimulatorHTTPError.request }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw SimulatorHTTPError.request }
                let key = line[..<colon].lowercased()
                guard headers[key] == nil else { throw SimulatorHTTPError.request }
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard headers["transfer-encoding"] == nil,
                  let length = Int(headers["content-length"] ?? "0"), (0 ... 16384).contains(length) else { throw SimulatorHTTPError.request }
            let body = bytes[split.upperBound...]
            if body.count < length {
                continue
            }
            guard body.count == length else { throw SimulatorHTTPError.request }
            return Request(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body))
        }
        throw SimulatorHTTPError.request
    }
}
