import CoreVideo
import Darwin
import Foundation

/// Holds only the newest raw screen picture. Whatever the sender has not picked up yet is replaced,
/// so a slow network skips old pictures instead of falling behind, and nothing is compressed in vain.
final class FramePump {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var latest: CVPixelBuffer?
    private var stopped = false

    func publish(_ frame: CVPixelBuffer) {
        lock.lock()
        let wasEmpty = latest == nil
        latest = frame
        let alreadyStopped = stopped
        lock.unlock()
        if wasEmpty && !alreadyStopped {
            signal.signal()
        }
    }

    func take() -> CVPixelBuffer? {
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
    private let pump = FramePump()
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
            let done = senderDone
            _ = try? await blocking { done.wait(timeout: .now() + 3) }
        }
        closeSocket()
        if let capture {
            _ = try? await withTimeout(seconds: 5, what: "Stopping screen capture") { await capture.stop() }
        }
        return accepted
    }

    /// Waits for a new picture, compresses the newest one, and sends it. Quality follows the network:
    /// slow sends lower it, quick sends raise it, so the picture stays current instead of queueing up.
    private func startSender(capture: DisplayCapture) {
        let sender = Thread { [weak self] in
            guard let self else { return }
            defer { self.senderDone.signal() }
            let minimumCycle = 1.0 / 40.0
            var quality = 0.6
            while let picture = self.pump.take() {
                let cycleStart = ProcessInfo.processInfo.systemUptime
                guard let jpeg = capture.encode(picture, quality: quality) else { continue }
                do {
                    let sendStart = ProcessInfo.processInfo.systemUptime
                    try self.send(type: Wire.frame, payload: jpeg)
                    let sendSeconds = ProcessInfo.processInfo.systemUptime - sendStart
                    quality = Session.adjustedQuality(quality, sendSeconds: sendSeconds)
                } catch {
                    Log.line("Could not send a frame: \(error)")
                    self.abort()
                    break
                }
                // At most about 40 pictures a second, so a busy screen cannot flood the network.
                let spent = ProcessInfo.processInfo.systemUptime - cycleStart
                if spent < minimumCycle {
                    Thread.sleep(forTimeInterval: minimumCycle - spent)
                }
            }
        }
        sender.name = "com.macconnect.frames"
        sender.qualityOfService = .userInteractive
        sender.start()
    }

    private static func adjustedQuality(_ quality: Double, sendSeconds: Double) -> Double {
        if sendSeconds > 0.045 {
            return max(0.3, quality - 0.06)
        }
        if sendSeconds < 0.015 {
            return min(0.8, quality + 0.02)
        }
        return quality
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
