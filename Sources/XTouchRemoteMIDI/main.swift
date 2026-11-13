// Development-only remote hardware link.
//
//   XTouchRemoteMIDI client --ssh HOST     (developer's Mac; publishes virtual endpoints)
//   XTouchRemoteMIDI bridge                (started by the client over SSH, beside the device)
//   XTouchRemoteMIDI devices               (lists what CoreMIDI sees on this Mac)
//   XTouchRemoteMIDI listen                (passive raw capture as JSON lines; never sends)
//   XTouchRemoteMIDI button-light …        (one button-LED Note On)
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

    /// Optional append-only JSONL journal. Open before CoreMIDI or SSH starts; errors
    /// stop the command and are never retried as MIDI. Bridge/client logs stay off stdout.
    final class EventJournal: @unchecked Sendable {
        private let journal: RemoteEventJournal

        init(path: String?) throws {
            journal = try RemoteEventJournal(path: path)
        }

        func emit(_ fields: [String: Any], at date: Date = Date(), stdout: Bool = true) {
            do { try journal.emit(fields, at: date, stdout: stdout) }
            catch {
                log("event logging failed: \(error.localizedDescription); command stopped, do not retry an already sent MIDI command")
                exit(2)
            }
        }
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
        private let journal: EventJournal
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

        init(options: RemoteBridgeOptions, journal: EventJournal) {
            self.options = options
            self.journal = journal
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
                journal.emit(RemoteEventJSON.forwarding(words: words, direction: "device-to-client", delivery: "forwarded"), stdout: false)
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
                journal.emit(RemoteEventJSON.forwarding(words: words, direction: "client-to-device", delivery: sent ? "sent" : "dropped"), stdout: false)
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
        private let journal: EventJournal
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

        init(options: RemoteClientOptions, journal: EventJournal) {
            self.options = options
            self.journal = journal
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
                for words in packets(list) {
                    journal.emit(RemoteEventJSON.forwarding(words: words, direction: "app-to-bridge", delivery: "suppressed"), stdout: false)
                }
                lock.lock(); suppressed &+= UInt64(packets(list).count); let total = suppressed; lock.unlock()
                if total == 1 || total % 100 == 0 {
                    log("listen-only: suppressed \(total) packet(s) from the local app")
                }
                return
            }
            lock.lock(); let current = writer; let ready = helloReceived; lock.unlock()
            guard let current, ready else { return } // Offline: nothing reaches the device.
            for words in packets(list) {
                let sent = current.write(.midi(words: words))
                journal.emit(RemoteEventJSON.forwarding(words: words, direction: "app-to-bridge", delivery: sent ? "forwarded" : "failed"), stdout: false)
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
                    let sent = withEventList(words) { MIDIReceivedEventList(endpoint, $0) }
                    journal.emit(RemoteEventJSON.forwarding(words: words, direction: "bridge-to-app", delivery: sent ? "forwarded" : "failed"), stdout: false)
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
            guard let data = try? RemoteEventJSON.line(line, at: Date()) else { return }
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
            emit(["event": "listening", "device": options.deviceName])
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

    // MARK: - Single nonmotor feedback message (bring-up checks)

    /// Sends exactly one UMP word to the controller and prints what was sent as a JSON line.
    /// Callers pass words built by `ButtonLightCommand` or `NonMotorFeedbackCommand` only.
    func sendOne(word: UInt32, deviceName: String, record: [String: Any], journal: EventJournal) throws {
        var client: MIDIClientRef = 0
        var port: MIDIPortRef = 0
        try check(MIDIClientCreateWithBlock("XTouchRemoteMIDI send" as CFString, &client) { _ in }, "Create MIDI client")
        defer { MIDIClientDispose(client) }
        try check(MIDIOutputPortCreate(client, "Feedback Out" as CFString, &port), "Create MIDI output")
        let matcher = RemoteBridgeOptions(deviceName: deviceName)
        var destination: MIDIEndpointRef = 0
        var name = ""
        for index in 0 ..< MIDIGetNumberOfDestinations() {
            let endpoint = MIDIGetDestination(index)
            guard endpoint != 0, !isOffline(endpoint), let text = endpointName(endpoint), matcher.matchesDevice(text) else { continue }
            destination = endpoint; name = text
            break
        }
        guard destination != 0 else {
            throw NSError(domain: "XTouchRemoteMIDI", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Controller output not found; nothing was sent"])
        }
        let sentAt = Date()
        guard withEventList([word], { MIDISendEventList(port, destination, $0) }) else {
            throw NSError(domain: "XTouchRemoteMIDI", code: 2, userInfo: [NSLocalizedDescriptionKey: "MIDI send failed"])
        }
        Thread.sleep(forTimeInterval: 0.2) // Let CoreMIDI deliver before the client goes away.
        var line = record
        line["destination"] = name
        line["word"] = String(format: "%08X", word)
        journal.emit(line, at: sentAt)
    }

    func sendButtonLight(_ command: ButtonLightCommand, journal: EventJournal) throws {
        try sendOne(word: command.word, deviceName: command.deviceName,
                    record: ["event": "sent-button-light", "button": command.button, "velocity": command.velocity,
                             "channel": command.channel], journal: journal)
    }

    // MARK: - Single fader move with touch guard (bring-up HW-6)

    /// Listens for `guardSeconds`, refuses on any touch message for the fader, sends one motor
    /// position, then prints everything received for `observe` seconds as JSON lines.
    func moveFader(_ command: FaderMoveCommand, journal: EventJournal, guardSeconds: Double = 1.0) throws {
        var client: MIDIClientRef = 0
        var input: MIDIPortRef = 0
        var output: MIDIPortRef = 0
        let lock = NSLock()
        var received: [(time: Double, wallClock: Date, words: [UInt32])] = []
        let started = ProcessInfo.processInfo.systemUptime
        try check(MIDIClientCreateWithBlock("XTouchRemoteMIDI fader-move" as CFString, &client) { _ in }, "Create MIDI client")
        defer { MIDIClientDispose(client) }
        try check(MIDIInputPortCreateWithProtocol(client, "Move In" as CFString, ._1_0, &input) { list, _ in
            let now = ProcessInfo.processInfo.systemUptime - started
            let all = packets(list)
            let wallClock = Date()
            lock.lock(); received += all.map { (now, wallClock, $0) }; lock.unlock()
        }, "Create MIDI input")
        try check(MIDIOutputPortCreate(client, "Move Out" as CFString, &output), "Create MIDI output")
        let matcher = RemoteBridgeOptions()
        func find(_ count: Int, _ at: (Int) -> MIDIEndpointRef) -> MIDIEndpointRef {
            for index in 0 ..< count {
                let endpoint = at(index)
                if endpoint != 0, !isOffline(endpoint), let name = endpointName(endpoint), matcher.matchesDevice(name) {
                    return endpoint
                }
            }
            return 0
        }
        let source = find(MIDIGetNumberOfSources(), MIDIGetSource)
        let destination = find(MIDIGetNumberOfDestinations(), MIDIGetDestination)
        guard source != 0, destination != 0 else {
            throw NSError(domain: "XTouchRemoteMIDI", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Controller input or output not found; nothing was sent"])
        }
        try check(MIDIPortConnectSource(input, source, nil), "Connect controller input")
        Thread.sleep(forTimeInterval: guardSeconds)
        lock.lock(); let before = received.flatMap(\.words); lock.unlock()
        let touch = command.touchState(in: before)
        guard !command.mustRefuse(afterListeningTo: before) else {
            journal.emit(["event": "fader-move-refused", "reason": "touch activity while listening", "fader": command.fader,
                          "lastTouch": touch == true ? "down" : "up", "messagesDuringGuard": before.count])
            exit(3)
        }
        let word = command.word
        let sentAt = ProcessInfo.processInfo.systemUptime - started
        let sentWallClock = Date()
        guard withEventList([word], { MIDISendEventList(output, destination, $0) }) else {
            throw NSError(domain: "XTouchRemoteMIDI", code: 2, userInfo: [NSLocalizedDescriptionKey: "MIDI send failed"])
        }
        journal.emit(["event": "fader-move-sent", "fader": command.fader, "value": command.value, "channel": command.channel,
                      "word": String(format: "%08X", word), "t": 0, "touchBeforeSend": touch.map { $0 ? "down" : "up" } ?? "unknown",
                      "messagesDuringGuard": before.count], at: sentWallClock)
        Thread.sleep(forTimeInterval: command.observe)
        lock.lock(); let after = received.filter { $0.time >= sentAt && $0.time <= sentAt + command.observe }; lock.unlock()
        for (time, wallClock, words) in after {
            journal.emit(["event": "midi", "t": ((time - sentAt) * 1000).rounded() / 1000, "words": words.map { String(format: "%08X", $0) }], at: wallClock)
        }
        var summary = FaderObservationSummary(command: command, words: after.flatMap(\.words)).fields
        summary["event"] = "stopped"; summary["t"] = command.observe; summary["fader"] = command.fader
        journal.emit(summary)
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
    let rawArguments = Array(CommandLine.arguments.dropFirst())
    do {
        let supportsLog = ["bridge", "client", "fader-move", "button-light"].contains(rawArguments.first ?? "")
            || NonMotorFeedbackCommand.names.contains(rawArguments.first ?? "")
        let logging = try RemoteLoggingArguments(supportsLog ? Array(rawArguments.dropFirst()) : [])
        let arguments = supportsLog ? Array(rawArguments.prefix(1)) + logging.arguments : rawArguments
        let journal = try EventJournal(path: logging.logPath)
        switch arguments.first {
        case "bridge":
            try Bridge(options: RemoteBridgeOptions.parse(Array(arguments.dropFirst())), journal: journal).run()
        case "client":
            let client = try Client(options: RemoteClientOptions.parse(Array(arguments.dropFirst())), journal: journal)
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
        case "fader-move":
            try moveFader(FaderMoveCommand.parse(Array(arguments.dropFirst())), journal: journal)
        case "button-light":
            try sendButtonLight(ButtonLightCommand.parse(Array(arguments.dropFirst())), journal: journal)
        case let name? where NonMotorFeedbackCommand.names.contains(name):
            let command = try NonMotorFeedbackCommand.parse(name, Array(arguments.dropFirst()))
            var record = command.summary
            record["event"] = "sent-feedback"
            try sendOne(word: command.word, deviceName: RemoteMIDIDefaults.deviceName, record: record, journal: journal)
        case "listen":
            try Listener(options: RemoteBridgeOptions.parse(Array(arguments.dropFirst()))).run()
        default:
            log("Senders and bridge/client accept --log PATH (local append-only JSONL).\n"
                + "       XTouchRemoteMIDI fader-move --fader 1-9 --value 0-127 --channel 1-16 [--observe 0-10]\n"
                + "usage: XTouchRemoteMIDI client --ssh HOST [--listen-only] [--remote-binary PATH] [--label NAME] [--device NAME]\n"
                + "       XTouchRemoteMIDI bridge [--listen-only] [--device NAME] [--status PATH]\n"
                + "       XTouchRemoteMIDI devices\n"
                + "       XTouchRemoteMIDI listen [--device NAME]\n"
                + "       XTouchRemoteMIDI button-light --button 1-39 --velocity 0-3 --channel 1-16\n"
                + "       XTouchRemoteMIDI ring-display --encoder 1-16 --value 0-28 --channel 1-16\n"
                + "       XTouchRemoteMIDI ring-style --encoder 1-16 --style 0-4 --channel 1-16\n"
                + "       XTouchRemoteMIDI select-layer --layer a|b --channel 1-16")
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
