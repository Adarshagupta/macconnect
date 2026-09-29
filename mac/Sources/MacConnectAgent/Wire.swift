import Foundation

/// MacConnect wire format. See protocol/PROTOCOL.md. Multi-byte values are little-endian.
enum Wire {
    static let beaconPort: UInt16 = 47901
    static let tcpPort: UInt16 = 47900
    static let beaconVersion: UInt8 = 1
    static let maxPayload = 8_000_000

    static let hello: UInt8 = 1
    static let frame: UInt8 = 2
    static let mouse: UInt8 = 3
    static let key: UInt8 = 4
    static let ping: UInt8 = 5
    static let pong: UInt8 = 6
    static let accept: UInt8 = 7

    static let mouseMove: UInt8 = 0
    static let mouseDown: UInt8 = 1
    static let mouseUp: UInt8 = 2
    static let mouseScroll: UInt8 = 3

    static func helloPayload(name: String, width: Int, height: Int) -> Data {
        var payload = Data()
        let nameBytes = Array(name.utf8.prefix(200))
        appendUInt16(UInt16(nameBytes.count), to: &payload)
        payload.append(contentsOf: nameBytes)
        appendUInt16(UInt16(clamping: width), to: &payload)
        appendUInt16(UInt16(clamping: height), to: &payload)
        return payload
    }

    /// The name Windows remembers this Mac by. It is read once so it stays the same for the whole run.
    static let computerName: String = {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Mac" : trimmed
    }()

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }
}

struct Message {
    var type: UInt8
    var payload: Data
}
