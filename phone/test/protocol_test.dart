import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:macconnect_phone/protocol.dart';

void main() {
  test('beacon carries the phone port and the Mac name', () {
    final packet = Uint8List.fromList([
      0x4D, 0x43, 0x31, 0x00, 1,
      0x1E, 0xBB,
      3, 0x4D, 0x61, 0x63,
    ]);
    final beacon = parseBeacon(packet, '10.0.0.8');
    expect(beacon, isNotNull);
    expect(beacon!.host, '10.0.0.8');
    expect(beacon.port, 47902);
    expect(beacon.name, 'Mac');
  });

  test('hello carries the picture size', () {
    final payload = Uint8List.fromList([
      3, 0, 0x4D, 0x61, 0x63,
      0x80, 0x07,
      0x38, 0x04,
    ]);
    final hello = Hello.parse(payload);
    expect(hello?.name, 'Mac');
    expect(hello?.width, 1920);
    expect(hello?.height, 1080);
  });

  test('messages can arrive split across reads', () {
    final buffer = MessageBuffer();
    buffer.add([Wire.ping, 0, 0, 0]);
    expect(buffer.next(), isNull);
    buffer.add([0]);
    final message = buffer.next();
    expect(message?.type, Wire.ping);
    expect(message?.payload, isEmpty);
    expect(buffer.next(), isNull);
  });

  test('mouse and key payloads are little endian', () {
    final mouse = mousePayload(Wire.mouseScroll, Wire.buttonNone, 0.25, 0.5, -120);
    final view = ByteData.sublistView(mouse);
    expect(mouse.length, 12);
    expect(mouse[0], Wire.mouseScroll);
    expect(view.getFloat32(2, Endian.little), closeTo(0.25, 0.0001));
    expect(view.getFloat32(6, Endian.little), closeTo(0.5, 0.0001));
    expect(view.getInt16(10, Endian.little), -120);

    final key = keyPayload(0x41, true);
    expect(key, [0x41, 0, 1]);
  });

  test('a keyframe access unit is recognized and a plain slice is not', () {
    expect(annexBHasKeyframe(Uint8List.fromList([0, 0, 0, 1, 0x65, 0x88])), isTrue);
    expect(annexBHasKeyframe(Uint8List.fromList([0, 0, 1, 0x41, 0x9A])), isFalse);
  });

  test('typed characters use the Windows virtual keys the Mac expects', () {
    final lower = keystrokesForCharacter('a');
    expect(lower?.map((stroke) => stroke.virtualKey).toList(), [0x41, 0x41]);
    expect(lower?.map((stroke) => stroke.down).toList(), [true, false]);

    final upper = keystrokesForCharacter('A');
    expect(upper?.first.virtualKey, 0x10);
    expect(upper?.first.down, isTrue);
    expect(upper?.last.virtualKey, 0x10);
    expect(upper?.last.down, isFalse);

    final bang = keystrokesForCharacter('!');
    expect(bang?.map((stroke) => stroke.virtualKey).toList(), [0x10, 0x31, 0x31, 0x10]);
  });

  test('addresses have to be IPv4', () {
    expect(looksLikeIPv4('192.168.1.20'), isTrue);
    expect(looksLikeIPv4('127.0.0.1'), isTrue);
    expect(looksLikeIPv4('10.0.0'), isFalse);
    expect(looksLikeIPv4('mac.local'), isFalse);
  });
}
