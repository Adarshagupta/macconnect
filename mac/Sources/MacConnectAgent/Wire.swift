import Foundation

/// MacConnect wire format. See protocol/PROTOCOL.md. Multi-byte values are little-endian.
enum Wire {
    static let beaconPort: UInt16 = 47901
    static let tcpPort: UInt16 = 47900
    /// The phone connects here. Separate from the Windows viewer, which the Mac connects out to.
    static let phonePort: UInt16 = 47902
    /// The Mac announces itself here so a phone can find it. Not 47901, so the Mac does not answer its own beacon.
    static let phoneBeaconPort: UInt16 = 47903
    static let beaconVersion: UInt8 = 1
    static let maxPayload = 8_000_000

    static let hello: UInt8 = 1
    static let frame: UInt8 = 2
    static let mouse: UInt8 = 3
    static let key: UInt8 = 4
    static let ping: UInt8 = 5
    static let pong: UInt8 = 6
    static let accept: UInt8 = 7
    static let cursor: UInt8 = 8

    /// Where the Mac pointer is, as a fraction of the display (0 to 1). Two little-endian Float32 values.
    static func cursorPayload(x: Float, y: Float) -> Data {
        var payload = Data()
        for value in [x, y] {
            let bits = value.bitPattern
            payload.append(UInt8(bits & 0xff))
            payload.append(UInt8((bits >> 8) & 0xff))
            payload.append(UInt8((bits >> 16) & 0xff))
            payload.append(UInt8((bits >> 24) & 0xff))
        }
        return payload
    }

    static let mouseMove: UInt8 = 0
    static let mouseDown: UInt8 = 1
    static let mouseUp: UInt8 = 2
    static let mouseScroll: UInt8 = 3

    /// Same layout as the Windows beacon. The TCP port inside is the phone port, and it is sent to `phoneBeaconPort`.
    static func phoneBeaconPacket() -> [UInt8] {
        let nameBytes = Array(computerName.utf8.prefix(200))
        var packet = [UInt8](repeating: 0, count: 8 + nameBytes.count)
        packet[0] = 0x4D
        packet[1] = 0x43
        packet[2] = 0x31
        packet[3] = 0x00
        packet[4] = beaconVersion
        packet[5] = UInt8(phonePort & 0xff)
        packet[6] = UInt8((phonePort >> 8) & 0xff)
        packet[7] = UInt8(nameBytes.count)
        for (index, byte) in nameBytes.enumerated() {
            packet[8 + index] = byte
        }
        return packet
    }

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
