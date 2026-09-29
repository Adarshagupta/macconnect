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
        try readFully(fd, into: &header)
        let length = Int(header[1]) | (Int(header[2]) << 8) | (Int(header[3]) << 16) | (Int(header[4]) << 24)
        if length > Wire.maxPayload {
            throw SocketError.message("Frame length \(length) exceeds the protocol limit")
        }
        var payload = [UInt8](repeating: 0, count: length)
        if length > 0 {
            try readFully(fd, into: &payload)
        }
        Heartbeat.beat()
        return Message(type: header[0], payload: Data(payload))
    }

    static func writeMessage(_ fd: Int32, type: UInt8, payload: Data) throws {
        var message = Data(capacity: 5 + payload.count)
        let length = UInt32(payload.count)
        message.append(type)
        message.append(UInt8(length & 0xff))
        message.append(UInt8((length >> 8) & 0xff))
        message.append(UInt8((length >> 16) & 0xff))
        message.append(UInt8((length >> 24) & 0xff))
        message.append(payload)
        try message.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        throw SocketError.message("Timed out sending to the Windows viewer")
                    }
                    throw SocketError.message("Write failed: \(errnoText())")
                }
                sent += count
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
            throw SocketError.message("Address \(host) is not an IPv4 address")
        }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let originalFlags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)

        let result = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(fd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result < 0 && errno != EINPROGRESS {
            let text = errnoText()
            Darwin.close(fd)
            throw SocketError.message("Connect to \(host):\(port) failed: \(text)")
        }
        if result < 0 {
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, timeoutMs)
            if ready <= 0 {
                Darwin.close(fd)
                throw SocketError.message("Connect to \(host):\(port) timed out")
            }
            var pending: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &pending, &size)
            if pending != 0 {
                let text = String(cString: strerror(pending))
                Darwin.close(fd)
                throw SocketError.message("Connect to \(host):\(port) failed: \(text)")
            }
        }

        _ = fcntl(fd, F_SETFL, originalFlags)
        var noDelay: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
        // A small send buffer keeps old pictures out of the network queue. When the network is slower
        // than the screen changes, the sender waits and then sends the newest picture, not a stale one.
        var sendBuffer: Int32 = 256 * 1024
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size))
        setTimeouts(fd, seconds: 6)
        return fd
    }

    static func setTimeouts(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, size)
    }

    private static func readFully(_ fd: Int32, into buffer: inout [UInt8]) throws {
        let total = buffer.count
        try buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var got = 0
            while got < total {
                let count = Darwin.read(fd, base.advanced(by: got), total - got)
                if count == 0 {
                    throw SocketError.message("The Windows viewer closed the connection")
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        throw SocketError.message("Nothing heard from the Windows viewer for a while")
                    }
                    throw SocketError.message("Read failed: \(errnoText())")
                }
                got += count
            }
        }
    }
}

func errnoText() -> String {
    String(cString: strerror(errno))
}
