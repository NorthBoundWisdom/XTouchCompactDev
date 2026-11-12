// Development-only remote hardware link.
//
//   XTouchRemoteMIDI client --ssh HOST     (developer's Mac; publishes virtual endpoints)
//   XTouchRemoteMIDI bridge                (started by the client over SSH, beside the device)
//   XTouchRemoteMIDI devices               (lists what CoreMIDI sees on this Mac)
//   XTouchRemoteMIDI listen                (passive raw capture as JSON lines; never sends)
//
// Raw MIDI 1.0 UMP packets are carried verbatim over the SSH stdio stream. Nothing is
// parsed, filtered, synthesized or acknowledged here; all safety policy stays in the app.
import CompactRemoteMIDI
import Foundation

#if os(macOS)
    import CoreMIDI
    import Darwin

    /// CoreMIDI delivers setup-changed notifications (device plug/unplug) through the run loop
    /// of the thread that created the client. `dispatchMain()` never runs that loop, so
    /// hot-plug went unnoticed; park the main thread on its run loop instead.
    func parkOnMainRunLoop() -> Never {
        let keepAlive = Timer(timeInterval: 3600, repeats: true) { _ in }
        RunLoop.main.add(keepAlive, forMode: .common)
        while true {
            CFRunLoopRun()
        }
    }

    func log(_ text: String) {
        FileHandle.standardError.write(Data("XTouchRemoteMIDI: \(text)\n".utf8))
    }

    /// Serialized, complete writes of frames to one file descriptor.
    final class FrameWriter: @unchecked Sendable {
        private let fd: Int32
        private let lock = NSLock()
        init(fd: Int32) {
            self.fd = fd
        }

        @discardableResult func write(_ frame: RemoteFrame) -> Bool {
            let bytes = frame.encoded
            lock.lock(); defer { lock.unlock() }
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// Blocking reader on its own thread. Ends on EOF, read error or any protocol violation.
    func startReader(fd: Int32, onFrame: @escaping @Sendable (RemoteFrame) -> Void,
                     onEnd: @escaping @Sendable (String) -> Void)
    {
        Thread {
            var decoder = RemoteFrameDecoder()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else { onEnd(count == 0 ? "stream closed" : "read failed (errno \(errno))"); return }
                do {
                    for frame in try decoder.append(buffer[0 ..< count]) {
                        onFrame(frame)
                    }
                } catch {
                    onEnd(error.localizedDescription); return
                }
            }
        }.start()
    }

    /// Each UMP packet of a MIDI 1.0 event list as its words.
    func packets(_ list: UnsafePointer<MIDIEventList>) -> [[UInt32]] {
        guard let packetOffset = MemoryLayout<MIDIEventList>.offset(of: \.packet),
              let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \.words) else { return [] }
        var packet = UnsafeRawPointer(list).advanced(by: packetOffset).assumingMemoryBound(to: MIDIEventPacket.self)
        var result: [[UInt32]] = []
        for _ in 0 ..< list.pointee.numPackets {
            let count = min(Int(packet.pointee.wordCount), RemoteFrame.maximumWords)
            let words = UnsafeRawPointer(packet).advanced(by: wordsOffset).assumingMemoryBound(to: UInt32.self)
            if count > 0 {
                result.append(Array(UnsafeBufferPointer(start: words, count: count)))
            }
            packet = UnsafePointer(MIDIEventPacketNext(packet))
        }
        return result
    }

    /// One-packet MIDI 1.0 event list for `words`. The decoder bounds a packet to 64 words,
    /// which is exactly the capacity of a single `MIDIEventList`.
    @discardableResult func withEventList(_ words: [UInt32], _ body: (UnsafePointer<MIDIEventList>) -> OSStatus) -> Bool {
        guard !words.isEmpty, words.count <= RemoteFrame.maximumWords else { return false }
        var list = MIDIEventList()
        let first = MIDIEventListInit(&list, ._1_0)
        _ = words.withUnsafeBufferPointer {
            MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, first, 0, $0.count, $0.baseAddress!)
        }
        return withUnsafePointer(to: list) { body($0) } == noErr
    }

    func endpointName(_ endpoint: MIDIEndpointRef) -> String? {
        var name: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    func isOffline(_ endpoint: MIDIEndpointRef) -> Bool {
        var offline: Int32 = 0
        return MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline) == noErr && offline != 0
    }

    func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw NSError(domain: "XTouchRemoteMIDI", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "\(operation) failed (OSStatus \(status))"])
        }
    }

    // MARK: - Bridge (beside the controller)

    final class Bridge: @unchecked Sendable {
        private let options: RemoteBridgeOptions
        private let out = FrameWriter(fd: STDOUT_FILENO)
        private let queue = DispatchQueue(label: "dev.xtouchcompact.remote.bridge")
        private let lock = NSLock()
        private var client: MIDIClientRef = 0
        private var inputPort: MIDIPortRef = 0
        private var outputPort: MIDIPortRef = 0
        private var source: MIDIEndpointRef = 0
        private var destination: MIDIEndpointRef = 0
        private var sourceName: String?
        private var destinationName: String?
        private var reportedDevice: (Bool, Bool)?
        private var helloReceived = false
        private var lastHeard = Date()
        private var finished = false
        private var toClient: UInt64 = 0
        private var toDevice: UInt64 = 0
        private var dropped: UInt64 = 0

        init(options: RemoteBridgeOptions) {
            self.options = options
        }

        func run() throws -> Never {
            try check(MIDIClientCreateWithBlock("XTouchRemoteMIDI bridge" as CFString, &client) { [weak self] note in
                guard note.pointee.messageID == .msgSetupChanged, let self else { return }
                queue.async { [weak self] in self?.reconnect() }
            }, "Create MIDI client")
            try check(MIDIInputPortCreateWithProtocol(client, "Bridge In" as CFString, ._1_0, &inputPort) { [weak self] list, _ in
                self?.fromDevice(list)
            }, "Create MIDI input")
            try check(MIDIOutputPortCreate(client, "Bridge Out" as CFString, &outputPort), "Create MIDI output")
            guard out.write(.hello(version: RemoteFrame.version)) else { finish("client stream closed") }
            queue.sync { reconnect() }
            startReader(fd: STDIN_FILENO, onFrame: { [self] in fromClient($0) }, onEnd: { [self] in finish($0) })
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + RemoteMIDIDefaults.pingInterval, repeating: RemoteMIDIDefaults.pingInterval)
            timer.setEventHandler { [self] in
                lock.lock(); let silent = Date().timeIntervalSince(lastHeard); lock.unlock()
                if silent > RemoteMIDIDefaults.silenceTimeout {
                    finish("client silent for \(Int(silent)) s")
                }
                if !out.write(.ping) {
                    finish("client stream closed")
                }
                writeStatus(running: true)
            }
            timer.resume()
            for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
                signal(signalNumber, SIG_IGN)
                let handler = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
                handler.setEventHandler { [self] in finish("signal \(signalNumber)") }
                handler.resume()
                _ = Unmanaged.passRetained(handler)
            }
            parkOnMainRunLoop()
        }

        private func fromDevice(_ list: UnsafePointer<MIDIEventList>) {
            for words in packets(list) {
                guard out.write(.midi(words: words)) else { finish("client stream closed") }
                lock.lock(); toClient &+= 1; lock.unlock()
            }
        }

        private func fromClient(_ frame: RemoteFrame) {
            lock.lock()
            lastHeard = Date()
            let ready = helloReceived
            lock.unlock()
            switch frame {
            case let .hello(version):
                guard version == RemoteFrame.version else { finish("client protocol version \(version) unsupported") }
                lock.lock(); helloReceived = true; lock.unlock()
            case let .midi(words):
                guard ready else { finish("MIDI before hello") }
                lock.lock(); let target = destination; let port = outputPort; lock.unlock()
                // Listen-only: the controller is never written, whatever the client sends.
                let sent = !options.listenOnly && target != 0 && withEventList(words) { MIDISendEventList(port, target, $0) }
                lock.lock()
                if sent {
                    toDevice &+= 1
                } else {
                    dropped &+= 1
                }
                lock.unlock()
            case .ping:
                break
            case .device:
                finish("unexpected device frame from client")
            }
        }

        /// Runs on `queue`.
        private func reconnect() {
            if source != 0 {
                MIDIPortDisconnectSource(inputPort, source)
            }
            source = 0; sourceName = nil; destinationName = nil
            lock.lock(); destination = 0; lock.unlock()
            func find(_ count: Int, _ at: (Int) -> MIDIEndpointRef) -> (MIDIEndpointRef, String)? {
                for index in 0 ..< count {
                    let endpoint = at(index)
                    guard endpoint != 0, !isOffline(endpoint), let name = endpointName(endpoint),
                          options.matchesDevice(name) else { continue }
                    return (endpoint, name)
                }
                return nil
            }
            if let found = find(MIDIGetNumberOfSources(), MIDIGetSource),
               MIDIPortConnectSource(inputPort, found.0, nil) == noErr
            {
                source = found.0; sourceName = found.1
            }
            if let found = find(MIDIGetNumberOfDestinations(), MIDIGetDestination) {
                lock.lock(); destination = found.0; lock.unlock()
                destinationName = found.1
            }
            let present = (source != 0, destinationName != nil)
            if reportedDevice.map({ $0 != present }) ?? true {
                reportedDevice = present
                log("controller input \(present.0 ? "present" : "absent"), output \(present.1 ? "present" : "absent")")
                if !out.write(.device(source: present.0, destination: present.1)) {
                    finish("client stream closed")
                }
            }
            writeStatus(running: true)
        }

        private func writeStatus(running: Bool) {
            guard let path = options.statusPath else { return }
            lock.lock()
            let status = RemoteBridgeStatus(pid: getpid(), running: running, deviceSource: sourceName,
                                            deviceDestination: destinationName, framesToClient: toClient,
                                            framesToDevice: toDevice, framesDropped: dropped, updatedAt: Date())
            lock.unlock()
            if let data = try? RemoteBridgeStatus.encoder.encode(status) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }

        private func finish(_ reason: String) -> Never {
            lock.lock()
            let first = !finished
            finished = true
            lock.unlock()
            if first {
                log("bridge stopping: \(reason)")
                writeStatus(running: false)
                if client != 0 {
                    MIDIClientDispose(client)
                }
            }
            exit(0)
        }
    }

    // MARK: - Client (developer's Mac)

    final class Client: @unchecked Sendable {
        private let options: RemoteClientOptions
        private let lock = NSLock()
        private var client: MIDIClientRef = 0
        private var source: MIDIEndpointRef = 0
        private var destination: MIDIEndpointRef = 0
        private var writer: FrameWriter?
        private var process: Process?
        private var helloReceived = false
        private var lastHeard = Date()
        private var online = false
        private var suppressed: UInt64 = 0

        init(options: RemoteClientOptions) {
            self.options = options
        }

        func setUp() throws {
            try check(MIDIClientCreateWithBlock("XTouchRemoteMIDI client" as CFString, &client) { _ in }, "Create MIDI client")
        }

        /// Endpoints exist only while the bridge reports the controller, so the app sees the
        /// same setup-changed events as a USB plug/unplug. Stable IDs keep its saved port choice.
        private func setOnline(_ value: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard online != value else { return }
            online = value
            if value {
                let name = options.endpointName as CFString
                var newSource: MIDIEndpointRef = 0
                var newDestination: MIDIEndpointRef = 0
                guard MIDISourceCreateWithProtocol(client, name, ._1_0, &newSource) == noErr,
                      MIDIDestinationCreateWithProtocol(client, name, ._1_0, &newDestination, { [weak self] list, _ in
                          self?.toBridge(list)
                      }) == noErr
                else {
                    if newSource != 0 {
                        MIDIEndpointDispose(newSource)
                    }
                    online = false
                    log("cannot create virtual endpoints"); return
                }
                for (endpoint, isSource) in [(newSource, true), (newDestination, false)] {
                    _ = MIDIObjectSetIntegerProperty(endpoint, kMIDIPropertyUniqueID,
                                                     RemoteMIDIDefaults.endpointUniqueID(host: options.label, isSource: isSource))
                    _ = MIDIObjectSetStringProperty(endpoint, kMIDIPropertyManufacturer, "XTouchCompactDev remote" as CFString)
                }
                source = newSource; destination = newDestination
                log("\(options.endpointName) online")
            } else {
                if source != 0 {
                    MIDIEndpointDispose(source)
                }
                if destination != 0 {
                    MIDIEndpointDispose(destination)
                }
                source = 0; destination = 0
                log("\(options.endpointName) offline")
            }
        }

        private func toBridge(_ list: UnsafePointer<MIDIEventList>) {
            if options.listenOnly {
                lock.lock(); suppressed &+= UInt64(packets(list).count); let total = suppressed; lock.unlock()
                if total == 1 || total % 100 == 0 {
                    log("listen-only: suppressed \(total) packet(s) from the local app")
                }
                return
            }
            lock.lock(); let current = writer; let ready = helloReceived; lock.unlock()
            guard let current, ready else { return } // Offline: nothing reaches the device.
            for words in packets(list) {
                current.write(.midi(words: words))
            }
        }

        private func fromBridge(_ frame: RemoteFrame, process: Process) {
            lock.lock(); lastHeard = Date(); let ready = helloReceived; lock.unlock()
            switch frame {
            case let .hello(version):
                guard version == RemoteFrame.version else {
                    log("bridge protocol version \(version) unsupported; redeploy the bridge"); process.terminate(); return
                }
                lock.lock(); helloReceived = true; lock.unlock()
                log("connected to bridge on \(options.sshHost)" + (options.listenOnly ? " (listen-only: nothing is sent to the controller)" : ""))
            case let .device(present, output):
                guard ready else { process.terminate(); return }
                setOnline(present && output)
            case let .midi(words):
                guard ready else { process.terminate(); return }
                lock.lock(); let endpoint = source; lock.unlock()
                if endpoint != 0 {
                    withEventList(words) { MIDIReceivedEventList(endpoint, $0) }
                }
            case .ping:
                break
            }
        }

        func runForever() -> Never {
            var delay: TimeInterval = 1
            while true {
                let started = Date()
                runSession()
                setOnline(false)
                if Date().timeIntervalSince(started) > 30 {
                    delay = 1
                }
                log("reconnecting in \(Int(delay)) s")
                Thread.sleep(forTimeInterval: delay)
                delay = min(delay * 2, 15)
            }
        }

        private func runSession() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = options.sshArguments
            let toSSH = Pipe(), fromSSH = Pipe()
            process.standardInput = toSSH
            process.standardOutput = fromSSH
            process.standardError = FileHandle.standardError
            do { try process.run() } catch {
                log("cannot start ssh: \(error.localizedDescription)"); return
            }
            let sessionWriter = FrameWriter(fd: toSSH.fileHandleForWriting.fileDescriptor)
            lock.lock()
            self.process = process; writer = sessionWriter; helloReceived = false; lastHeard = Date()
            lock.unlock()
            sessionWriter.write(.hello(version: RemoteFrame.version))
            startReader(fd: fromSSH.fileHandleForReading.fileDescriptor,
                        onFrame: { [self] in fromBridge($0, process: process) },
                        onEnd: { reason in
                            log("bridge stream ended: \(reason)")
                            if process.isRunning {
                                process.terminate()
                            }
                        })
            Thread { [self] in
                while process.isRunning {
                    Thread.sleep(forTimeInterval: RemoteMIDIDefaults.pingInterval)
                    lock.lock(); let silent = Date().timeIntervalSince(lastHeard); lock.unlock()
                    guard process.isRunning else { return }
                    if silent > RemoteMIDIDefaults.silenceTimeout || !sessionWriter.write(.ping) {
                        log("bridge silent for \(Int(silent)) s"); process.terminate(); return
                    }
                }
            }.start()
            process.waitUntilExit()
            lock.lock(); writer = nil; helloReceived = false; self.process = nil; lock.unlock()
            try? toSSH.fileHandleForWriting.close()
            log("ssh exited (status \(process.terminationStatus))")
        }

        func shutDown() {
            lock.lock(); let current = process; lock.unlock()
            if current?.isRunning == true {
                current?.terminate()
            }
            setOnline(false)
            if client != 0 {
                MIDIClientDispose(client)
            }
        }
    }

    // MARK: - Passive raw listener

    /// Read-only capture for startup-state investigation: connects to every matching source,
    /// including ones that appear later, and prints one JSON line per UMP packet with the raw
    /// words (SysEx included). It creates no output port and can never send MIDI.
    final class Listener: @unchecked Sendable {
        private let options: RemoteBridgeOptions
        private let queue = DispatchQueue(label: "dev.xtouchcompact.remote.listen")
        private let lock = NSLock()
        private var client: MIDIClientRef = 0
        private var port: MIDIPortRef = 0
        private var connected: [MIDIEndpointRef: String] = [:]
        private let started = ProcessInfo.processInfo.systemUptime

        init(options: RemoteBridgeOptions) {
            self.options = options
        }

        /// `t` is seconds since the listener started (monotonic).
        private func emit(_ fields: [String: Any]) {
            var line = fields
            line["t"] = ((ProcessInfo.processInfo.systemUptime - started) * 1_000_000).rounded() / 1_000_000
            guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
            data.append(0x0A)
            lock.lock(); defer { lock.unlock() }
            FileHandle.standardOutput.write(data)
        }

        func run() throws -> Never {
            try check(MIDIClientCreateWithBlock("XTouchRemoteMIDI listen" as CFString, &client) { [weak self] note in
                guard note.pointee.messageID == .msgSetupChanged, let self else { return }
                queue.async { [weak self] in self?.rescan() }
            }, "Create MIDI client")
            try check(MIDIInputPortCreateWithProtocol(client, "Listen In" as CFString, ._1_0, &port) { [weak self] list, tag in
                guard let self else { return }
                let endpoint = MIDIEndpointRef(UInt(bitPattern: tag))
                lock.lock(); let name = connected[endpoint] ?? "?"; lock.unlock()
                for words in packets(list) {
                    emit(["event": "midi", "source": name, "words": words.map { String(format: "%08X", $0) }])
                }
            }, "Create MIDI input")
            emit(["event": "listening", "device": options.deviceName, "wallClock": ISO8601DateFormatter().string(from: Date())])
            queue.sync { rescan() }
            for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
                signal(signalNumber, SIG_IGN)
                let handler = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
                handler.setEventHandler { [self] in emit(["event": "stopped"]); exit(0) }
                handler.resume()
                _ = Unmanaged.passRetained(handler)
            }
            parkOnMainRunLoop()
        }

        /// Runs on `queue`. Connects new matching sources and reports ones that disappeared.
        private func rescan() {
            var present: [MIDIEndpointRef: String] = [:]
            for index in 0 ..< MIDIGetNumberOfSources() {
                let endpoint = MIDIGetSource(index)
                guard endpoint != 0, !isOffline(endpoint), let name = endpointName(endpoint), options.matchesDevice(name) else { continue }
                present[endpoint] = name
            }
            lock.lock(); let known = connected; lock.unlock()
            for (endpoint, name) in present where known[endpoint] == nil {
                let status = MIDIPortConnectSource(port, endpoint, UnsafeMutableRawPointer(bitPattern: UInt(endpoint)))
                if status == noErr {
                    lock.lock(); connected[endpoint] = name; lock.unlock()
                    emit(["event": "source-connected", "source": name])
                } else {
                    emit(["event": "connect-failed", "source": name, "status": Int(status)])
                }
            }
            for (endpoint, name) in known where present[endpoint] == nil {
                lock.lock(); connected[endpoint] = nil; lock.unlock()
                emit(["event": "source-gone", "source": name])
            }
        }
    }

    // MARK: - Entry

    func listDevices() throws {
        var client: MIDIClientRef = 0
        try check(MIDIClientCreateWithBlock("XTouchRemoteMIDI devices" as CFString, &client) { _ in }, "Create MIDI client")
        let matcher = RemoteBridgeOptions()
        for (title, count, at) in [("sources", MIDIGetNumberOfSources(), MIDIGetSource as (Int) -> MIDIEndpointRef),
                                   ("destinations", MIDIGetNumberOfDestinations(), MIDIGetDestination)]
        {
            print("\(title):")
            for index in 0 ..< count {
                let endpoint = at(index)
                let name = endpointName(endpoint) ?? "?"
                let flags = [matcher.matchesDevice(name) ? "controller" : nil, isOffline(endpoint) ? "offline" : nil]
                    .compactMap(\.self).joined(separator: ", ")
                print("  \(name)\(flags.isEmpty ? "" : "  [\(flags)]")")
            }
        }
        MIDIClientDispose(client)
    }

    signal(SIGPIPE, SIG_IGN)
    let arguments = Array(CommandLine.arguments.dropFirst())
    do {
        switch arguments.first {
        case "bridge":
            try Bridge(options: RemoteBridgeOptions.parse(Array(arguments.dropFirst()))).run()
        case "client":
            let client = try Client(options: RemoteClientOptions.parse(Array(arguments.dropFirst())))
            try client.setUp()
            for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
                signal(signalNumber, SIG_IGN)
                let handler = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
                handler.setEventHandler { client.shutDown(); exit(0) }
                handler.resume()
                _ = Unmanaged.passRetained(handler)
            }
            Thread { client.runForever() }.start()
            parkOnMainRunLoop()
        case "devices":
            try listDevices()
        case "listen":
            try Listener(options: RemoteBridgeOptions.parse(Array(arguments.dropFirst()))).run()
        default:
            log("usage: XTouchRemoteMIDI client --ssh HOST [--listen-only] [--remote-binary PATH] [--label NAME] [--device NAME]\n"
                + "       XTouchRemoteMIDI bridge [--listen-only] [--device NAME] [--status PATH]\n"
                + "       XTouchRemoteMIDI devices\n"
                + "       XTouchRemoteMIDI listen [--device NAME]")
            exit(64)
        }
    } catch {
        log(error.localizedDescription)
        exit(2)
    }
#else
    #if canImport(Glibc)
        import Glibc
    #endif
    FileHandle.standardError.write(Data("XTouchRemoteMIDI requires macOS CoreMIDI.\n".utf8))
    exit(1)
#endif
