import CoreGraphics
import Foundation

final class Input {
    static let shared = Input()

    private let source: CGEventSource?
    private var shift = false
    private var control = false
    private var option = false
    private var command = false
    private var leftDown = false
    private var rightDown = false
    private var otherDown = false

    private init() {
        source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
    }

    func handleMouse(_ payload: Data) {
        guard payload.count >= 12 else { return }
        let bytes = [UInt8](payload)
        let action = bytes[0]
        let button = bytes[1]
        let x = Self.floatLE(bytes, 2)
        let y = Self.floatLE(bytes, 6)
        let wheelBits = UInt16(bytes[10]) | (UInt16(bytes[11]) << 8)
        let wheel = Int16(bitPattern: wheelBits)
        let point = displayPoint(x, y)

        switch action {
        case Wire.mouseMove:
            move(to: point)
        case Wire.mouseDown:
            setButton(button, down: true)
            postMouse(type: downType(button), point: point, button: cgButton(button))
        case Wire.mouseUp:
            postMouse(type: upType(button), point: point, button: cgButton(button))
            setButton(button, down: false)
        case Wire.mouseScroll:
            move(to: point)
            let lines = scrollLines(wheel)
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else {
                return
            }
            event.location = point
            event.post(tap: .cghidEventTap)
        default:
            break
        }
    }

    func handleKey(_ payload: Data) {
        guard payload.count >= 3 else { return }
        let bytes = [UInt8](payload)
        let virtualKey = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let down = bytes[2] == 1
        guard let macKey = KeyMap.code(for: virtualKey) else { return }
        updateModifiers(virtualKey, down: down)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: macKey, keyDown: down) else { return }
        event.flags = modifierFlags()
        event.post(tap: .cghidEventTap)
    }

    private func move(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        let type: CGEventType
        let button: CGMouseButton
        if leftDown {
            type = .leftMouseDragged
            button = .left
        } else if rightDown {
            type = .rightMouseDragged
            button = .right
        } else if otherDown {
            type = .otherMouseDragged
            button = .center
        } else {
            type = .mouseMoved
            button = .left
        }
        postMouse(type: type, point: point, button: button)
    }

    private func postMouse(type: CGEventType, point: CGPoint, button: CGMouseButton) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            return
        }
        event.post(tap: .cghidEventTap)
    }

    private func displayPoint(_ x: Float, _ y: Float) -> CGPoint {
        let nx = CGFloat(min(1, max(0, x)))
        let ny = CGFloat(min(1, max(0, y)))
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(
            x: bounds.origin.x + nx * bounds.size.width,
            y: bounds.origin.y + ny * bounds.size.height
        )
    }

    private func setButton(_ button: UInt8, down: Bool) {
        switch button {
        case 1: leftDown = down
        case 2: rightDown = down
        case 3: otherDown = down
        default: break
        }
    }

    private func cgButton(_ button: UInt8) -> CGMouseButton {
        switch button {
        case 2: return .right
        case 3: return .center
        default: return .left
        }
    }

    private func downType(_ button: UInt8) -> CGEventType {
        switch button {
        case 2: return .rightMouseDown
        case 3: return .otherMouseDown
        default: return .leftMouseDown
        }
    }

    private func upType(_ button: UInt8) -> CGEventType {
        switch button {
        case 2: return .rightMouseUp
        case 3: return .otherMouseUp
        default: return .leftMouseUp
        }
    }

    private func scrollLines(_ wheel: Int16) -> Int32 {
        if wheel == 0 { return 0 }
        let lines = Int32(wheel) / 120
        if lines != 0 { return lines }
        return wheel > 0 ? 1 : -1
    }

    private func updateModifiers(_ virtualKey: UInt16, down: Bool) {
        switch virtualKey {
        case 0x10, 0xA0, 0xA1: shift = down
        case 0x11, 0xA2, 0xA3: control = down
        case 0x12, 0xA4, 0xA5: option = down
        case 0x5B, 0x5C: command = down
        default: break
        }
    }

    private func modifierFlags() -> CGEventFlags {
        var flags: CGEventFlags = []
        if shift { flags.insert(.maskShift) }
        if control { flags.insert(.maskControl) }
        if option { flags.insert(.maskAlternate) }
        if command { flags.insert(.maskCommand) }
        return flags
    }

    private static func floatLE(_ bytes: [UInt8], _ offset: Int) -> Float {
        let bits = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        return Float(bitPattern: bits)
    }
}

enum KeyMap {
    private static let letters: [UInt16: CGKeyCode] = [
        0x41: 0x00, 0x53: 0x01, 0x44: 0x02, 0x46: 0x03, 0x48: 0x04, 0x47: 0x05,
        0x5A: 0x06, 0x58: 0x07, 0x43: 0x08, 0x56: 0x09, 0x42: 0x0B, 0x51: 0x0C,
        0x57: 0x0D, 0x45: 0x0E, 0x52: 0x0F, 0x59: 0x10, 0x54: 0x11, 0x4F: 0x1F,
        0x55: 0x20, 0x49: 0x22, 0x50: 0x23, 0x4C: 0x25, 0x4A: 0x26, 0x4B: 0x28,
        0x4E: 0x2D, 0x4D: 0x2E,
    ]

    private static let numbers: [UInt16: CGKeyCode] = [
        0x31: 0x12, 0x32: 0x13, 0x33: 0x14, 0x34: 0x15, 0x36: 0x16,
        0x35: 0x17, 0x39: 0x19, 0x37: 0x1A, 0x38: 0x1C, 0x30: 0x1D,
    ]

    private static let controls: [UInt16: CGKeyCode] = [
        0x08: 0x33, 0x09: 0x30, 0x0D: 0x24, 0x10: 0x38, 0x11: 0x3B, 0x12: 0x3A,
        0x14: 0x39, 0x1B: 0x35, 0x20: 0x31, 0x21: 0x74, 0x22: 0x79, 0x23: 0x77,
        0x24: 0x73, 0x25: 0x7B, 0x26: 0x7E, 0x27: 0x7C, 0x28: 0x7D, 0x2E: 0x75,
        0x5B: 0x37, 0x5C: 0x37, 0x70: 0x7A, 0x71: 0x78, 0x72: 0x63, 0x73: 0x76,
        0x74: 0x60, 0x75: 0x61, 0x76: 0x62, 0x77: 0x64, 0x78: 0x65, 0x79: 0x6D,
        0x7A: 0x67, 0x7B: 0x6F, 0xA0: 0x38, 0xA1: 0x3C, 0xA2: 0x3B, 0xA3: 0x3E,
        0xA4: 0x3A, 0xA5: 0x3D, 0xBA: 0x29, 0xBB: 0x18, 0xBC: 0x2B, 0xBD: 0x1B,
        0xBE: 0x2F, 0xBF: 0x2C, 0xC0: 0x32, 0xDB: 0x21, 0xDC: 0x2A, 0xDD: 0x1E,
        0xDE: 0x27, 0x60: 0x52, 0x61: 0x53, 0x62: 0x54, 0x63: 0x55, 0x64: 0x56,
        0x65: 0x57, 0x66: 0x58, 0x67: 0x59, 0x68: 0x5B, 0x69: 0x5C, 0x6A: 0x43,
        0x6B: 0x45, 0x6D: 0x4E, 0x6E: 0x41, 0x6F: 0x4B,
    ]

    static func code(for virtualKey: UInt16) -> CGKeyCode? {
        if let code = letters[virtualKey] { return code }
        if let code = numbers[virtualKey] { return code }
        return controls[virtualKey]
    }
}
