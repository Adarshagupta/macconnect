import CoreGraphics
import CoreVideo
import Darwin
import Foundation

/// Holds only the newest item. Whatever the consumer has not picked up yet is replaced, so a slow
/// network skips old pictures instead of falling behind, and nothing is compressed or sent in vain.
final class LatestSlot<Item> {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var latest: Item?
    private var stopped = false

    func publish(_ frame: Item) {
        lock.lock()
        let wasEmpty = latest == nil
        latest = frame
        let alreadyStopped = stopped
        lock.unlock()
        if wasEmpty && !alreadyStopped {
            signal.signal()
        }
    }

    func take() -> Item? {
        signal.wait()
        lock.lock()
        defer { lock.unlock() }
        if stopped {
            return nil
        }
        let frame = latest
        latest = nil
        return frame
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        signal.signal()
    }
}

/// Keeps the Mac from sleeping while Windows is connected. Tied to this process, so it can never be orphaned.
final class StayAwake {
    private var process: Process?

    func start() {
        guard process == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-dims", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        do {
            try process.run()
            self.process = process
            Log.line("Keeping the Mac awake while Windows is connected")
        } catch {
            Log.line("Could not start caffeinate: \(error.localizedDescription)")
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }
}

final class Session {
    private let beacon: Beacon
    private let pump = LatestSlot<CVPixelBuffer>()
    private let lock = NSLock()
    private let writeLock = NSLock()
    private let senderDone = DispatchSemaphore(value: 0)
    private var fd: Int32 = -1
    private var aborted = false

    init(beacon: Beacon) {
        self.beacon = beacon
    }

    /// Connects, streams until the connection ends, and cleans up. Returns true if Windows accepted this Mac.
    func run() async throws -> Bool {
        let target = beacon
        let connected = try await blocking { try Socket.connect(host: target.host, port: target.port, timeoutMs: 5_000) }
        setFD(connected)

        var capture: DisplayCapture?
        var accepted = false
        var senderStarted = false
        let awake = StayAwake()

        do {
            let frames = pump
            let prepared = try await withTimeout(seconds: 15, what: "Preparing screen capture") {
                try await DisplayCapture.prepare { picture in frames.publish(picture) }
            }
            capture = prepared

            try send(type: Wire.hello, payload: Wire.helloPayload(name: Wire.computerName, width: prepared.width, height: prepared.height))
            Log.line("Connected to \(beacon.name) at \(beacon.host):\(beacon.port)")
            try await blocking { try self.waitForAccept() }
            accepted = true

            awake.start()
            try await withTimeout(seconds: 15, what: "Starting screen capture") {
                try await prepared.start { [weak self] reason in
                    Log.line("Capture stopped: \(reason)")
                    self?.abort()
                }
            }

            startSender(capture: prepared)
            startCursorSender()
            senderStarted = true
            try await blocking { try self.readInput() }
        } catch {
            Log.line("Session ended: \(error)")
        }

        // Cleanup always runs, whatever went wrong above.
        abort()
        Input.shared.releaseAll()
        awake.stop()
        if senderStarted {
            _ = try? await blocking { self.waitForSenders() }
        }
        closeSocket()
        if let capture {
            _ = try? await withTimeout(seconds: 5, what: "Stopping screen capture") { await capture.stop() }
        }
        return accepted
    }

    /// Encodes and sends the newest picture on one thread. Older pictures are dropped while this runs,
    /// so a slow frame cannot pile up behind itself.
    private func startSender(capture: DisplayCapture) {
        let width = capture.width
        let height = capture.height
        let sender = Thread { [weak self] in
            guard let self else { return }
            defer { self.senderDone.signal() }
            let encoder: H264Encoder
            do {
                encoder = try H264Encoder(width: width, height: height)
            } catch {
                Log.line("\(error)")
                self.abort()
                return
            }
            while let picture = self.pump.take() {
                guard let accessUnit = encoder.encode(picture) else { continue }
                do {
                    try self.send(type: Wire.frame, payload: accessUnit)
                } catch {
                    Log.line("Could not send a frame: \(error)")
                    self.abort()
                    break
                }
            }
        }
        sender.name = "com.macconnect.frames"
        sender.qualityOfService = .userInteractive
        sender.start()
    }

    /// Reports where the Mac pointer is, about 120 times a second, whenever it moves. Windows draws it on
    /// top of the picture, so the pointer moves right away instead of waiting for the next screen picture.
    private func startCursorSender() {
        let thread = Thread { [weak self] in
            var lastX: Float = -1
            var lastY: Float = -1
            var lastSentAt = 0.0
            while true {
                guard let self, !self.isAborted else { return }
                if let position = Session.cursorPosition() {
                    let now = ProcessInfo.processInfo.systemUptime
                    let moved = position.x != lastX || position.y != lastY
                    // Also repeat the position once a second, so a fresh viewer always learns it.
                    if moved || now - lastSentAt > 1.0 {
                        do {
                            try self.send(type: Wire.cursor, payload: Wire.cursorPayload(x: position.x, y: position.y))
                        } catch {
                            return
                        }
                        lastX = position.x
                        lastY = position.y
                        lastSentAt = now
                    }
                }
                Thread.sleep(forTimeInterval: 1.0 / 120.0)
            }
        }
        thread.name = "com.macconnect.cursor"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private static func cursorPosition() -> (x: Float, y: Float)? {
        guard let event = CGEvent(source: nil) else { return nil }
        let bounds = CGDisplayBounds(CGMainDisplayID())
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let location = event.location
        let x = min(1, max(0, (location.x - bounds.origin.x) / bounds.width))
        let y = min(1, max(0, (location.y - bounds.origin.y) / bounds.height))
        return (Float(x), Float(y))
    }

    /// Waits for the picture thread to finish.
    private func waitForSenders() -> DispatchTimeoutResult {
        senderDone.wait(timeout: .now() + 3)
    }

    private func waitForAccept() throws {
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline && !isAborted {
            let message = try Socket.readMessage(currentFD())
            switch message.type {
            case Wire.ping:
                try send(type: Wire.pong, payload: Data())
            case Wire.accept:
                Log.line("Windows accepted this Mac")
                return
            default:
                break
            }
        }
        throw SocketError.message("Windows did not accept this Mac")
    }

    private func readInput() throws {
        while !isAborted {
            let message = try Socket.readMessage(currentFD())
            switch message.type {
            case Wire.ping:
                try send(type: Wire.pong, payload: Data())
            case Wire.mouse:
                Input.shared.handleMouse(message.payload)
            case Wire.key:
                Input.shared.handleKey(message.payload)
            default:
                break
            }
        }
    }

    private var isAborted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return aborted
    }

    private func currentFD() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return fd
    }

    private func setFD(_ value: Int32) {
        lock.lock()
        fd = value
        lock.unlock()
    }

    private func send(type: UInt8, payload: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        if isAborted {
            throw SocketError.message("The connection is closed")
        }
        try Socket.writeMessage(currentFD(), type: type, payload: payload)
    }

    /// Stops all traffic and wakes any thread blocked on the socket. The descriptor itself is closed
    /// later by `closeSocket`, once the reader and sender have finished with it.
    private func abort() {
        lock.lock()
        let already = aborted
        aborted = true
        let current = fd
        lock.unlock()
        if already { return }
        if current >= 0 {
            _ = Darwin.shutdown(current, SHUT_RDWR)
        }
        pump.stop()
    }

    private func closeSocket() {
        lock.lock()
        let current = fd
        fd = -1
        lock.unlock()
        if current >= 0 {
            Darwin.close(current)
        }
    }
}
