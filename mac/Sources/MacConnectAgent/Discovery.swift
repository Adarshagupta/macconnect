import Darwin
import Foundation

struct Beacon {
    var host: String
    var port: UInt16
    var name: String
}

/// Listens for the Windows viewer's once-a-second broadcast.
final class Discovery {
    private let fd: Int32

    private init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        Darwin.close(fd)
    }

    /// Returns nil (and logs why) if the port cannot be used. The agent keeps working through saved addresses.
    static func make() -> Discovery? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if fd < 0 {
            Log.line("Could not open the discovery socket: \(errnoText())")
            return nil
        }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Wire.beaconPort.bigEndian
        address.sin_addr.s_addr = 0

        let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(fd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 {
            Log.line("Could not listen for the Windows PC on UDP \(Wire.beaconPort): \(errnoText())")
            Darwin.close(fd)
            return nil
        }
        Socket.setTimeouts(fd, seconds: 2)
        return Discovery(fd: fd)
    }

    /// Waits up to two seconds for one beacon.
    func next() -> Beacon? {
        var buffer = [UInt8](repeating: 0, count: 512)
        var sender = sockaddr_in()
        var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let capacity = buffer.count
        let received = buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return withUnsafeMutablePointer(to: &sender) { senderPointer -> Int in
                senderPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    Darwin.recvfrom(fd, base, capacity, 0, generic, &senderLength)
                }
            }
        }
        Heartbeat.beat()
        if received < 8 {
            return nil
        }
        if buffer[0] != 0x4D || buffer[1] != 0x43 || buffer[2] != 0x31 || buffer[3] != 0 {
            return nil
        }
        if buffer[4] != Wire.beaconVersion {
            return nil
        }
        let port = UInt16(buffer[5]) | (UInt16(buffer[6]) << 8)
        let nameLength = Int(buffer[7])
        if port == 0 || received < 8 + nameLength {
            return nil
        }
        let nameData = Data(buffer[8..<(8 + nameLength)])
        let decoded = String(data: nameData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = decoded.isEmpty ? "Windows" : decoded

        var hostBytes = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var address = sender.sin_addr
        let converted = inet_ntop(AF_INET, &address, &hostBytes, socklen_t(INET_ADDRSTRLEN)) != nil
        if !converted {
            return nil
        }
        let host = String(cString: hostBytes)
        if host.isEmpty || host.hasPrefix("127.") {
            return nil
        }
        return Beacon(host: host, port: port, name: name)
    }
}
