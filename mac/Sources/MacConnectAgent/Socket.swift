import Darwin
import Foundation

enum SocketError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}

enum Socket {
    static func readMessage(_ fd: Int32) throws -> Message {
        var header = [UInt8](repeating: 0, count: 5)
        try readExact(fd, &header, header.count)
        let length = Int(UInt32(header[1]) | (UInt32(header[2]) << 8) | (UInt32(header[3]) << 16) | (UInt32(header[4]) << 24))
        if length < 0 || length > Wire.maxPayload {
            throw SocketError.message("Frame length \(length) exceeds the protocol limit")
        }
        var payload = [UInt8](repeating: 0, count: length)
        if length > 0 {
            try readExact(fd, &payload, length)
        }
        return Message(type: header[0], payload: Data(payload))
    }

    static func writeMessage(_ fd: Int32, type: UInt8, payload: Data) throws {
        var header = [UInt8](repeating: 0, count: 5)
        header[0] = type
        let length = UInt32(payload.count)
        header[1] = UInt8(length & 0xff)
        header[2] = UInt8((length >> 8) & 0xff)
        header[3] = UInt8((length >> 16) & 0xff)
        header[4] = UInt8((length >> 24) & 0xff)
        try writeExact(fd, header, header.count)
        if !payload.isEmpty {
            try payload.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                try writeExact(fd, base, payload.count)
            }
        }
    }

    static func connect(host: String, port: UInt16, timeoutMs: Int32) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 {
            throw SocketError.message("Could not open a socket: \(errnoText())")
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        if inet_pton(AF_INET, host, &address.sin_addr) != 1 {
            Darwin.close(fd)
            throw SocketError.message("Address \(host) is not IPv4")
        }

        let originalFlags = fcntl(fd, F_GETFL, 0)
        if originalFlags >= 0 {
            _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)
        }

        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult < 0 && errno != EINPROGRESS {
            Darwin.close(fd)
            throw SocketError.message("Connect to \(host):\(port) failed: \(errnoText())")
        }
        if connectResult < 0 {
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let waited = Darwin.poll(&descriptor, nfds_t(1), timeoutMs)
            if waited <= 0 {
                Darwin.close(fd)
                throw SocketError.message("Connect to \(host):\(port) timed out")
            }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
            if socketError != 0 {
                Darwin.close(fd)
                throw SocketError.message("Connect to \(host):\(port) failed: \(String(cString: strerror(socketError)))")
            }
        }

        if originalFlags >= 0 {
            _ = fcntl(fd, F_SETFL, originalFlags)
        }
        var noDelay: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
        setTimeouts(fd, seconds: 6)
        return fd
    }

    static func setTimeouts(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, size)
    }

    private static func readExact(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) throws {
        var got = 0
        while got < count {
            let readCount = Darwin.read(fd, buffer.advanced(by: got), count - got)
            if readCount == 0 {
                throw SocketError.message("The Windows viewer closed the connection")
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw SocketError.message("Read failed: \(errnoText())")
            }
            got += readCount
        }
    }

    private static func readExact(_ fd: Int32, _ buffer: inout [UInt8], _ count: Int) throws {
        try buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else {
                throw SocketError.message("Could not read into an empty buffer")
            }
            try readExact(fd, base, count)
        }
    }

    private static func writeExact(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) throws {
        var sent = 0
        while sent < count {
            let writeCount = Darwin.write(fd, buffer.advanced(by: sent), count - sent)
            if writeCount < 0 {
                if errno == EINTR { continue }
                throw SocketError.message("Write failed: \(errnoText())")
            }
            sent += writeCount
        }
    }

    private static func writeExact(_ fd: Int32, _ buffer: [UInt8], _ count: Int) throws {
        try buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            try writeExact(fd, base, count)
        }
    }
}

func errnoText() -> String {
    String(cString: strerror(errno))
}
