import 'dart:convert';
import 'dart:typed_data';

/// MacConnect wire format. See protocol/PROTOCOL.md. Multi-byte values are little-endian.
class Wire {
  static const beaconMagic0 = 0x4D;
  static const beaconMagic1 = 0x43;
  static const beaconMagic2 = 0x31;
  static const beaconVersion = 1;

  /// UDP port the Mac announces itself on. The Windows beacon uses 47901.
  static const phoneBeaconPort = 47903;

  /// TCP port the phone opens to the Mac.
  static const phonePort = 47902;

  static const maxPayload = 8000000;

  static const hello = 1;
  static const frame = 2;
  static const mouse = 3;
  static const key = 4;
  static const ping = 5;
  static const pong = 6;
  static const accept = 7;
  static const cursor = 8;

  static const mouseMove = 0;
  static const mouseDown = 1;
  static const mouseUp = 2;
  static const mouseScroll = 3;

  static const buttonNone = 0;
  static const buttonLeft = 1;
  static const buttonRight = 2;
  static const buttonMiddle = 3;
}

class Incoming {
  final int type;
  final Uint8List payload;
  const Incoming(this.type, this.payload);
}

class Hello {
  final String name;
  final int width;
  final int height;
  const Hello({required this.name, required this.width, required this.height});

  static Hello? parse(Uint8List payload) {
    if (payload.length < 6) return null;
    final view = ByteData.sublistView(payload);
    final nameLength = view.getUint16(0, Endian.little);
    if (nameLength > 200 || payload.length < 2 + nameLength + 4) return null;
    final name = _decodeName(payload, 2, nameLength);
    final width = view.getUint16(2 + nameLength, Endian.little);
    final height = view.getUint16(4 + nameLength, Endian.little);
    if (name.isEmpty || width <= 0 || height <= 0 || width > 16384 || height > 16384) {
      return null;
    }
    return Hello(name: name, width: width, height: height);
  }
}

class MacBeacon {
  final String host;
  final int port;
  final String name;
  const MacBeacon({required this.host, required this.port, required this.name});
}

/// Reads length-prefixed messages that may arrive split across socket reads.
class MessageBuffer {
  Uint8List _data = Uint8List(0);

  void add(List<int> bytes) {
    if (bytes.isEmpty) return;
    final next = Uint8List(_data.length + bytes.length);
    next.setRange(0, _data.length, _data);
    next.setRange(_data.length, next.length, bytes);
    _data = next;
  }

  Incoming? next() {
    if (_data.length < 5) return null;
    final view = ByteData.sublistView(_data);
    final length = view.getUint32(1, Endian.little);
    if (length > Wire.maxPayload) {
      throw const FormatException('Frame is too large');
    }
    if (_data.length < 5 + length) return null;
    final type = _data[0];
    final payload = Uint8List.fromList(Uint8List.sublistView(_data, 5, 5 + length));
    final rest = _data.length - (5 + length);
    if (rest > 0) {
      _data = Uint8List.fromList(Uint8List.sublistView(_data, 5 + length));
    } else {
      _data = Uint8List(0);
    }
    return Incoming(type, payload);
  }
}

MacBeacon? parseBeacon(Uint8List data, String host) {
  if (host.isEmpty || data.length < 8) return null;
  if (data[0] != Wire.beaconMagic0 || data[1] != Wire.beaconMagic1 || data[2] != Wire.beaconMagic2 || data[3] != 0) {
    return null;
  }
  if (data[4] != Wire.beaconVersion) return null;
  final port = data[5] | (data[6] << 8);
  final nameLength = data[7];
  if (port == 0 || data.length < 8 + nameLength) return null;
  final name = _decodeName(data, 8, nameLength);
  return MacBeacon(host: host, port: port, name: name.isEmpty ? 'Mac' : name);
}

(double, double)? parseCursor(Uint8List payload) {
  if (payload.length < 8) return null;
  final view = ByteData.sublistView(payload);
  final x = view.getFloat32(0, Endian.little);
  final y = view.getFloat32(4, Endian.little);
  if (!x.isFinite || !y.isFinite) return null;
  return (x.clamp(0.0, 1.0).toDouble(), y.clamp(0.0, 1.0).toDouble());
}

Uint8List mousePayload(int action, int button, double x, double y, int wheel) {
  final data = ByteData(12);
  data.setUint8(0, action);
  data.setUint8(1, button);
  data.setFloat32(2, x.clamp(0.0, 1.0).toDouble(), Endian.little);
  data.setFloat32(6, y.clamp(0.0, 1.0).toDouble(), Endian.little);
  data.setInt16(10, wheel.clamp(-32768, 32767), Endian.little);
  return data.buffer.asUint8List();
}

Uint8List keyPayload(int virtualKey, bool down) {
  final data = ByteData(3);
  data.setUint16(0, virtualKey & 0xffff, Endian.little);
  data.setUint8(2, down ? 1 : 0);
  return data.buffer.asUint8List();
}

/// True when this access unit can start a picture (SPS or an IDR slice).
bool annexBHasKeyframe(Uint8List data) {
  var index = 0;
  while (index + 3 < data.length) {
    var start = -1;
    if (data[index] == 0 && data[index + 1] == 0 && data[index + 2] == 1) {
      start = index + 3;
    } else if (index + 4 < data.length &&
        data[index] == 0 &&
        data[index + 1] == 0 &&
        data[index + 2] == 0 &&
        data[index + 3] == 1) {
      start = index + 4;
    }
    if (start < 0 || start >= data.length) {
      index += 1;
      continue;
    }
    final nal = data[start] & 0x1F;
    if (nal == 5 || nal == 7) return true;
    index = start;
  }
  return false;
}

class KeyAction {
  final int virtualKey;
  final bool down;
  const KeyAction(this.virtualKey, this.down);
}

/// One typed character as Windows virtual-key downs and ups, including Shift when the
/// US layout needs it. The Mac agent maps these codes onto a US keyboard.
List<KeyAction>? keystrokesForCharacter(String character) {
  if (character.runes.length != 1) return null;
  final plan = _plan(character);
  if (plan == null) return null;
  return [
    if (plan.$2) const KeyAction(0x10, true),
    KeyAction(plan.$1, true),
    KeyAction(plan.$1, false),
    if (plan.$2) const KeyAction(0x10, false),
  ];
}

bool looksLikeIPv4(String text) {
  final parts = text.trim().split('.');
  if (parts.length != 4) return false;
  for (final part in parts) {
    if (part.isEmpty) return false;
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return false;
  }
  return true;
}

String _decodeName(Uint8List data, int offset, int length) {
  if (length == 0) return '';
  return utf8.decode(data.sublist(offset, offset + length), allowMalformed: true).trim();
}

/// Returns (virtual key, needs shift).
(int, bool)? _plan(String character) {
  const shiftedDigits = {
    '!': 0x31,
    '@': 0x32,
    '#': 0x33,
    r'$': 0x34,
    '%': 0x35,
    '^': 0x36,
    '&': 0x37,
    '*': 0x38,
    '(': 0x39,
    ')': 0x30,
  };
  const plainPunctuation = {
    '-': 0xBD,
    '=': 0xBB,
    '[': 0xDB,
    ']': 0xDD,
    r'\': 0xDC,
    ';': 0xBA,
    "'": 0xDE,
    ',': 0xBC,
    '.': 0xBE,
    '/': 0xBF,
    '`': 0xC0,
    ' ': 0x20,
  };
  const shiftedPunctuation = {
    '_': 0xBD,
    '+': 0xBB,
    '{': 0xDB,
    '}': 0xDD,
    '|': 0xDC,
    ':': 0xBA,
    '"': 0xDE,
    '<': 0xBC,
    '>': 0xBE,
    '?': 0xBF,
    '~': 0xC0,
  };

  if (shiftedDigits.containsKey(character)) {
    return (shiftedDigits[character]!, true);
  }
  if (shiftedPunctuation.containsKey(character)) {
    return (shiftedPunctuation[character]!, true);
  }
  if (plainPunctuation.containsKey(character)) {
    return (plainPunctuation[character]!, false);
  }
  final code = character.codeUnitAt(0);
  if (code >= 0x30 && code <= 0x39) return (code, false);
  if (code >= 0x41 && code <= 0x5A) return (code, true);
  if (code >= 0x61 && code <= 0x7A) return (code - 0x20, false);
  return null;
}
