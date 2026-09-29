import Darwin
import Foundation

/// Lets an Android phone show and control this Mac while the Windows viewer keeps working.
///
/// The phone opens TCP `Wire.phonePort`. The Mac announces that port on UDP `Wire.phoneBeaconPort`
/// from every network, including a USB tether. If `adb` is installed, a USB debugging cable is
/// forwarded too, so the phone can open `127.0.0.1` on itself and reach this Mac.
final class PhoneHub {
    static let shared = PhoneHub()

    private let lock = NSLock()
    private var current: Session?
    private var started = false
    private var loggedAddresses = ""
    private var loggedAdbMissing = false
    private var forwarded = Set<String>()
    private var adbNotes = Set<String>()
    private var listenFailures = 0

    private init() {}

    func start() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        Thread.detach("com.macconnect.phone-accept") { self.acceptLoop() }
        Thread.detach("com.macconnect.phone-beacon") { self.beaconLoop() }
        Thread.detach("com.macconnect.phone-cable") { self.cableLoop() }
    }

    private func acceptLoop() {
        while true {
            Heartbeat.beat()
            let fd: Int32
            do {
                fd = try Socket.listen(port: Wire.phonePort)
                listenFailures = 0
            } catch {
                listenFailures += 1
                if listenFailures == 1 || listenFailures % 15 == 0 {
                    Log.line("\(error)")
                }
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            Log.line("Waiting for a phone on TCP \(Wire.phonePort)")
            while true {
                guard let accepted = Socket.acceptPhone(fd) else { continue }
                Log.line("Phone connected from \(accepted.1)")
                startSession(fd: accepted.0, host: accepted.1)
            }
        }
    }

    private func startSession(fd: Int32, host: String) {
        let session = Session(connected: fd, host: host)
        lock.lock()
        let previous = current
        current = session
        lock.unlock()
        previous?.cancel()

        Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                guard let self else { return }
                self.lock.lock()
                if self.current === session {
                    self.current = nil
                }
                self.lock.unlock()
            }
            do {
                _ = try await session.run()
            } catch {
                Log.line("Phone session ended: \(error)")
            }
        }
    }

    private func beaconLoop() {
        let packet = Wire.phoneBeaconPacket()
        while true {
            Heartbeat.beat()
            let interfaces = LocalNetworks.interfaces()
            let summary = interfaces.map { "\($0.address) (\($0.name))" }.joined(separator: ", ")
            if summary != loggedAddresses {
                loggedAddresses = summary
                if summary.isEmpty {
                    Log.line("No network yet for the phone. USB debugging still works once adb is available.")
                } else {
                    Log.line("A phone can connect to \(summary) on TCP \(Wire.phonePort)")
                }
            }
            if interfaces.isEmpty {
                sendBeacon(packet, from: nil, to: "255.255.255.255")
            } else {
                for item in interfaces {
                    sendBeacon(packet, from: item.address, to: item.broadcast)
                    if item.broadcast != "255.255.255.255" {
                        sendBeacon(packet, from: item.address, to: "255.255.255.255")
                    }
                }
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// Binds to one interface, then broadcasts, so a USB tether hears the Mac and not only Wi-Fi.
    private func sendBeacon(_ packet: [UInt8], from local: String?, to broadcast: String) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if fd < 0 { return }
        defer { Darwin.close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        if let local {
            var bindAddress = sockaddr_in()
            bindAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            bindAddress.sin_family = sa_family_t(AF_INET)
            bindAddress.sin_port = 0
            if inet_pton(AF_INET, local, &bindAddress.sin_addr) == 1 {
                _ = withUnsafePointer(to: &bindAddress) { pointer -> Int32 in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                        Darwin.bind(fd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = Wire.phoneBeaconPort.bigEndian
        if inet_pton(AF_INET, broadcast, &dest.sin_addr) != 1 { return }
        packet.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = withUnsafePointer(to: &dest) { pointer -> Int in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    Darwin.sendto(fd, base, raw.count, 0, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func cableLoop() {
        while true {
            Heartbeat.beat()
            refreshAdb()
            Thread.sleep(forTimeInterval: 3)
        }
    }

    private func refreshAdb() {
        guard let adb = Self.adbPath() else {
            if !loggedAdbMissing {
                loggedAdbMissing = true
                Log.line("adb was not found, so a USB debugging cable is not forwarded. USB tethering still works. Install it with: brew install android-platform-tools")
            }
            return
        }
        let listed = Self.adbDevices(adb)
        if listed.unauthorized && adbNotes.insert("unauthorized").inserted {
            Log.line("USB cable: allow USB debugging on the phone.")
        }
        var live = Set<String>()
        for serial in listed.ready {
            live.insert(serial)
            let status = Self.run(adb, ["-s", serial, "reverse", "tcp:\(Wire.phonePort)", "tcp:\(Wire.phonePort)"])
            if status == 0 {
                adbNotes.remove(serial)
                if forwarded.insert(serial).inserted {
                    Log.line("USB cable: the phone can open 127.0.0.1:\(Wire.phonePort) (\(serial))")
                }
            } else if adbNotes.insert(serial).inserted {
                Log.line("USB cable: could not forward port \(Wire.phonePort) for \(serial).")
            }
        }
        forwarded = forwarded.intersection(live)
    }

    private static func adbPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "\(home)/Android/Sdk/platform-tools/adb",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let found = capture("/usr/bin/which", ["adb"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if found.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: found) {
            return found
        }
        return nil
    }

    private static func adbDevices(_ adb: String) -> (ready: [String], unauthorized: Bool) {
        let output = capture(adb, ["devices"])
        var ready: [String] = []
        var unauthorized = false
        for line in output.split(separator: "\n").dropFirst() {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            if fields.count < 2 { continue }
            let state = String(fields[1])
            if state == "device" {
                ready.append(String(fields[0]))
            } else if state == "unauthorized" {
                unauthorized = true
            }
        }
        return (ready, unauthorized)
    }

    @discardableResult
    private static func run(_ launch: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        return wait(process)
    }

    private static func capture(_ launch: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        if wait(process) != 0 && !process.isRunning {
            // Still return whatever was written. `which` exits 1 when adb is missing.
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Gives up after a few seconds so a stuck adb server cannot freeze the cable thread.
    private static func wait(_ process: Process) -> Int32 {
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return -1
        }
        return process.terminationStatus
    }
}

private extension Thread {
    static func detach(_ name: String, _ block: @escaping () -> Void) {
        let thread = Thread(block: block)
        thread.name = name
        thread.start()
    }
}

struct LocalInterface {
    var name: String
    var address: String
    var broadcast: String
}

enum LocalNetworks {
    static func interfaces() -> [LocalInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(first) }

        var found: [LocalInterface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            cursor = current.pointee.ifa_next
            let flags = Int32(current.pointee.ifa_flags)
            if (flags & IFF_UP) == 0 || (flags & IFF_LOOPBACK) != 0 {
                continue
            }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let address = ipv4(addr)
            if address.isEmpty || address.hasPrefix("127.") {
                continue
            }
            var broadcast = "255.255.255.255"
            if (flags & IFF_BROADCAST) != 0, let destination = current.pointee.ifa_dstaddr, destination.pointee.sa_family == UInt8(AF_INET) {
                let text = ipv4(destination)
                if !text.isEmpty {
                    broadcast = text
                }
            }
            let name: String
            if let pointer = Optional(current.pointee.ifa_name) {
                name = String(cString: pointer)
            } else {
                name = "network"
            }
            found.append(LocalInterface(name: name, address: address, broadcast: broadcast))
        }
        return found
    }

    private static func ipv4(_ pointer: UnsafeMutablePointer<sockaddr>) -> String {
        var copy = pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &copy.sin_addr, &host, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return ""
        }
        return String(cString: host)
    }
}
