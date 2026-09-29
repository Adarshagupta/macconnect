import Darwin
import Foundation

struct Beacon {
    var host: String
    var port: UInt16
    var name: String
}

final class Discovery {
    private var fd: Int32

    init() throws {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if fd < 0 {
            throw SocketError.message("Could not open the discovery socket: \(errnoText())")
        }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Wire.beaconPort.bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_ANY)

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 {
            let failed = fd
            fd = -1
            Darwin.close(failed)
            throw SocketError.message("Could not listen for the Windows PC on UDP \(Wire.beaconPort): \(errnoText())")
        }
        Socket.setTimeouts(fd, seconds: 2)
    }

    deinit {
        if fd >= 0 {
            Darwin.close(fd)
        }
    }

    func next() -> Beacon? {
        var buffer = [UInt8](repeating: 0, count: 512)
        var sender = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let received = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return withUnsafeMutablePointer(to: &sender) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                    recvfrom(fd, base, raw.count, 0, sock, &length)
                }
            }
        }
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
        guard nameLength >= 0, received >= 8 + nameLength, port > 0 else {
            return nil
        }
        let nameData = Data(buffer[8..<(8 + nameLength)])
        let name = String(data: nameData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var hostBytes = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let converted = hostBytes.withUnsafeMutableBufferPointer { pointer -> Bool in
            var address = sender.sin_addr
            return inet_ntop(AF_INET, &address, pointer.baseAddress, socklen_t(INET_ADDRSTRLEN)) != nil
        }
        guard converted else { return nil }
        let host = hostBytes.withUnsafeBufferPointer { buffer -> String in
            guard let base = buffer.baseAddress else { return "" }
            return String(cString: base)
        }
        guard !host.isEmpty else { return nil }
        let displayName = if let name, !name.isEmpty { name } else { "Windows" }
        return Beacon(host: host, port: port, name: displayName)
    }
}

extension Discovery {
    static func listen() async -> Discovery {
        while true {
            do {
                return try Discovery()
            } catch {
                Log.line("\(error)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
