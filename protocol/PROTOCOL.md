# MacConnect wire protocol

Home-network protocol between the Mac agent and the Windows viewer. All multi-byte integers and IEEE-754 floats are little-endian.

## Ports

| Port | Protocol | Direction | Purpose |
| --- | --- | --- | --- |
| 47901 | UDP | Windows broadcasts, Mac listens | Discovery beacon, once per second |
| 47900 | TCP | Mac connects to Windows | Desktop frames and input |
| 47903 | UDP | Mac broadcasts, phone listens | Phone discovery beacon, once per second |
| 47902 | TCP | Phone connects to Mac | Same desktop frames and input as port 47900 |

## UDP beacon

Sent to the IPv4 broadcast address of each local interface, and to `255.255.255.255`.

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | Magic `4D 43 31 00` (`MC1\0`) |
| 4 | 1 | Version `1` |
| 5 | 2 | TCP port the viewer is listening on (`47900`) |
| 7 | 1 | Name length in bytes, 0–200 |
| 8 | N | UTF-8 Windows computer name |

Packets with a different magic or version are ignored.

## TCP framing

Every TCP message is:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 1 | Message type |
| 1 | 4 | Payload length in bytes |
| 5 | N | Payload |

Maximum payload length is 8,000,000 bytes. A larger length closes the connection.

### Types

| Value | Name | Sender | Payload |
| --- | --- | --- | --- |
| 1 | Hello | Mac | name, capture size |
| 2 | Frame | Mac | One H.264 access unit, Annex B (start codes `00 00 00 01`). Keyframes include SPS and PPS. No B-frames. |
| 3 | Mouse | Windows | action, button, position, wheel |
| 4 | Key | Windows | Windows virtual-key, down flag |
| 5 | Ping | Windows | empty |
| 6 | Pong | Mac | empty |
| 7 | Accept | Windows | empty |
| 8 | Cursor | Mac | 8 bytes: `x` and `y` as little-endian Float32, each from 0 to 1 across the display. Sent whenever the Mac pointer moves, and at least once a second. Windows draws the pointer itself. Viewers that do not know type 8 ignore it. |

### Hello payload

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 2 | Name length in bytes |
| 2 | N | UTF-8 Mac computer name |
| 2+N | 2 | Capture width in pixels |
| 4+N | 2 | Capture height in pixels |

Width and height are the picture size. The viewer uses them for letterboxing. Mouse positions are normalized, so they do not depend on this size.

### Frame payload

One H.264 access unit in Annex B. The Mac GPU encodes it with frame reordering off, so a picture is not held back to wait for a later one. The pointer is not in the picture; the viewer draws it from cursor messages.

### Mouse payload (12 bytes)

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 1 | Action: `0` move, `1` down, `2` up, `3` scroll |
| 1 | 1 | Button: `0` none, `1` left, `2` right, `3` middle |
| 2 | 4 | X, float, 0.0–1.0 from the left of the picture |
| 6 | 4 | Y, float, 0.0–1.0 from the top of the picture |
| 10 | 2 | Wheel delta, signed. `120` is one scroll line. Zero for non-scroll actions. |

Positions outside 0.0–1.0 are clamped. Clicks that fall in the letterbox bars are not sent.

### Key payload (3 bytes)

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 2 | Windows virtual-key code |
| 2 | 1 | `1` key down, `0` key up |

The Mac maps these codes to macOS virtual key codes for a US keyboard.

## Session

1. The Mac waits for a beacon, then connects to the advertised TCP port. If no beacon is heard, it tries a saved Windows address (from `config.json` or the last beacon it heard) on the same TCP port.
2. The Mac sends Hello.
3. The Windows viewer allows the Mac name or asks the user. Deny closes the socket, and the same name is not asked about again for 60 seconds.
4. The viewer sends Accept. The Mac does not send frames before Accept.
5. The Mac streams frames. If a send is still in progress, older frames are dropped.
6. The viewer sends Ping about every 2 seconds, including while the allow prompt is open, so the Mac does not give up if the person takes a while to answer. The Mac replies with Pong.
7. Once Hello has been received, either side that sees no inbound message for 6 seconds closes the connection and the Mac tries again. Before Hello, the viewer waits up to 20 seconds.
8. The viewer handles each connection separately. When a Mac that is already accepted connects again, the new connection is accepted as soon as it is approved and the old one is closed. This way a stale or half-open connection can never keep the Mac out.

## Phone

The phone is a second viewer. It does not replace the Windows one, and both can be connected at the same time.

The Mac sends the same beacon layout as Windows, once a second, to UDP port **47903** on each local network (including a USB tether). The TCP port inside the beacon is **47902**. The Mac does not listen for these beacons, so it does not try to connect to itself.

The phone opens TCP **47902**. From there the messages match the Windows session, with the phone in the viewer's role:

1. The Mac sends Hello.
2. The phone sends Accept. The Mac does not send frames before Accept.
3. The phone sends Ping about every 2 seconds. The Mac replies with Pong.
4. The Mac streams Frame and Cursor. The phone sends Mouse and Key.

A new phone connection replaces the previous phone connection. The Windows session is left as it is.

USB debugging uses the same TCP port. When `adb` is available, the Mac runs `adb reverse tcp:47902 tcp:47902`, and the phone opens `127.0.0.1:47902` on itself.
