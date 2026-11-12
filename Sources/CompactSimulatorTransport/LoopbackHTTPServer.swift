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

    /// Host timer hooks, valid only for the duration of `run`.
    private struct Timers {
        let nextDeadline: () -> Double?
        let maintenance: () -> Void
    }

    /// Wait until `descriptor` is ready for `events`, or `budget` (a `systemUptime` value, nil
    /// for no limit) passes. Every wait in this server goes through here: whenever the host's
    /// next deadline arrives first, `maintenance()` runs on this same thread and the wait
    /// continues. So a peer that is slow to connect, send, or read can never postpone host
    /// timers; they are late only by poll wake-up latency plus one request's processing time.
    private func wait(_ descriptor: Int32, _ events: Int32, budget: Double?, timers: Timers) throws -> Bool {
        var retryAt = 0.0
        while true {
            var now = ProcessInfo.processInfo.systemUptime
            if let due = timers.nextDeadline(), due <= now, now >= retryAt {
                timers.maintenance()
                now = ProcessInfo.processInfo.systemUptime
                // If maintenance could not clear the deadline, retry later instead of spinning.
                if let still = timers.nextDeadline(), still <= now {
                    retryAt = now + 0.05
                }
            }
            if let budget, budget <= now {
                return false
            }
            var limit = budget.map { $0 - now } ?? 60
            if let due = timers.nextDeadline() {
                limit = min(limit, max(due, retryAt) - now)
            }
            var entry = pollfd(fd: descriptor, events: Int16(events), revents: 0)
            let ready = poll(&entry, 1, Int32(min(max(0, (limit * 1000).rounded(.up)), 60000)))
            if ready < 0, errno != EINTR {
                throw SimulatorHTTPError.socket
            }
            if ready > 0 {
                return true
            }
        }
    }

    private static func setNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        }
    }

    /// Serve requests serially on the calling thread. `nextDeadline()` is a `systemUptime`
    /// value; when it arrives, `maintenance()` runs between I/O waits: while idle, while a
    /// request is still being read, and while a response is being written. The handler and
    /// maintenance never run concurrently, so host state keeps one serial mutation order.
    /// The handler is expected to run due maintenance itself before using host state.
    public func run(nextDeadline: @escaping () -> Double?, maintenance: @escaping () -> Void, handler: (Data) -> Data) throws -> Never {
        signal(SIGPIPE, SIG_IGN)
        let timers = Timers(nextDeadline: nextDeadline, maintenance: maintenance)
        Self.setNonBlocking(descriptor)
        while true {
            _ = try wait(descriptor, POLLIN, budget: nil, timers: timers)
            let peer = accept(descriptor, nil, nil)
            if peer < 0 {
                if [EINTR, EAGAIN, EWOULDBLOCK, ECONNABORTED].contains(errno) {
                    continue
                }
                throw SimulatorHTTPError.socket
            }
            Self.setNonBlocking(peer)
            let response: (Int, Data)
            do {
                let request = try readRequest(peer, timers: timers)
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
            try? write(Data(head.utf8) + response.1, to: peer, timers: timers)
            close(peer)
        }
    }

    /// One fixed three-second budget for the whole response, so a peer that does not read
    /// cannot hold the serial listener; host timers keep running while it is slow.
    private func write(_ bytes: Data, to peer: Int32, timers: Timers) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var sent = 0
        while sent < bytes.count {
            let count = bytes.withUnsafeBytes { send(peer, $0.baseAddress!.advanced(by: sent), bytes.count - sent, 0) }
            if count > 0 {
                sent += count
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                guard try wait(peer, POLLOUT, budget: deadline, timers: timers) else { return }
            } else {
                return
            }
        }
    }

    private struct Request { var method: String; var path: String; var headers: [String: String]; var body: Data }
    private func readRequest(_ peer: Int32, timers: Timers) throws -> Request {
        var bytes = Data()
        var storage = [UInt8](repeating: 0, count: 4096)
        // A per-recv timeout alone permits an unauthenticated slow drip to occupy
        // this serial listener forever. The complete request has one fixed budget.
        // Host timers still run on time while this budget is being consumed.
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while bytes.count <= 32768 {
            guard try wait(peer, POLLIN, budget: deadline, timers: timers) else { throw SimulatorHTTPError.read }
            let count = recv(peer, &storage, storage.count, 0)
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                continue
            }
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
