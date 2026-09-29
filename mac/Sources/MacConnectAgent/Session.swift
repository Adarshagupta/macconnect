import Darwin
import Foundation

final class FramePump {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var latest: Data?
    private var stopped = false

    func publish(_ frame: Data) {
        lock.lock()
        let wasEmpty = latest == nil
        latest = frame
        let alreadyStopped = stopped
        lock.unlock()
        if wasEmpty && !alreadyStopped {
            signal.signal()
        }
    }

    func take() -> Data? {
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

final class StayAwake {
    private var process: Process?

    func start() {
        guard process == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-dimsu"]
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
    private var fd: Int32 = -1
    private var stopped = false

    init(beacon: Beacon) {
        self.beacon = beacon
    }

    func run() async throws {
        let fd = try Socket.connect(host: beacon.host, port: beacon.port, timeoutMs: 5_000)
        self.fd = fd
        defer { closeSocket() }

        let capture = try await DisplayCapture.prepare { [pump] jpeg in
            pump.publish(jpeg)
        }
        try send(type: Wire.hello, payload: Wire.helloPayload(name: Wire.computerName(), width: capture.width, height: capture.height))
        Log.line("Connected to \(beacon.name) at \(beacon.host):\(beacon.port)")
        try waitForAccept(fd)

        let awake = StayAwake()
        awake.start()
        defer { awake.stop() }

        try await capture.start { [weak self] reason in
            Log.line("Capture stopped: \(reason)")
            self?.closeSocket()
            self?.pump.stop()
        }
        defer {
            pump.stop()
        }

        let sender = Thread { [weak self] in
            guard let self else { return }
            while let frame = self.pump.take() {
                do {
                    try self.send(type: Wire.frame, payload: frame)
                } catch {
                    Log.line("Could not send a frame: \(error)")
                    self.closeSocket()
                    self.pump.stop()
                    break
                }
            }
        }
        sender.name = "com.macconnect.frames"
        sender.start()

        defer {
            pump.stop()
            closeSocket()
            while sender.isExecuting {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }

        do {
            try readInput(fd)
        } catch {
            Log.line("Session ended: \(error)")
        }
        await capture.stop()
    }

    private func waitForAccept(_ fd: Int32) throws {
        while !hasStopped() {
            let message = try Socket.readMessage(fd)
            switch message.type {
            case Wire.ping:
                try send(type: Wire.pong, payload: Data())
            case Wire.accept:
                Log.line("Windows accepted this Mac")
                return
            default:
                Log.line("Ignored message \(message.type) before accept")
            }
        }
        throw SocketError.message("Connection closed before Windows accepted this Mac")
    }

    private func readInput(_ fd: Int32) throws {
        while !hasStopped() {
            let message = try Socket.readMessage(fd)
            switch message.type {
            case Wire.ping:
                try send(type: Wire.pong, payload: Data())
            case Wire.mouse:
                Input.shared.handleMouse(message.payload)
            case Wire.key:
                Input.shared.handleKey(message.payload)
            case Wire.pong, Wire.accept:
                break
            default:
                break
            }
        }
    }

    private func hasStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func currentFD() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return fd
    }

    private func send(type: UInt8, payload: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        let current = currentFD()
        if current < 0 {
            throw SocketError.message("The connection is closed")
        }
        try Socket.writeMessage(current, type: type, payload: payload)
    }

    private func closeSocket() {
        lock.lock()
        let current = fd
        let already = stopped
        stopped = true
        fd = -1
        lock.unlock()
        if current >= 0 {
            _ = shutdown(current, SHUT_RDWR)
            Darwin.close(current)
        }
        if !already {
            pump.stop()
        }
    }
}
