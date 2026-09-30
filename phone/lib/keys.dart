import 'package:flutter/services.dart';

/// Windows virtual-key codes. The Mac treats Ctrl as Command, Alt as Option, and the Windows key as Control.
int? windowsVirtualKey(LogicalKeyboardKey key) {
  final special = _named[key];
  if (special != null) return special;
  final label = key.keyLabel;
  if (label.length != 1) return null;
  final code = label.toUpperCase().codeUnitAt(0);
  if (code >= 0x30 && code <= 0x39) return code;
  if (code >= 0x41 && code <= 0x5A) return code;
  return null;
}

final _named = <LogicalKeyboardKey, int>{
  LogicalKeyboardKey.backspace: 0x08,
  LogicalKeyboardKey.tab: 0x09,
  LogicalKeyboardKey.enter: 0x0D,
  LogicalKeyboardKey.escape: 0x1B,
  LogicalKeyboardKey.space: 0x20,
  LogicalKeyboardKey.pageUp: 0x21,
  LogicalKeyboardKey.pageDown: 0x22,
  LogicalKeyboardKey.end: 0x23,
  LogicalKeyboardKey.home: 0x24,
  LogicalKeyboardKey.arrowLeft: 0x25,
  LogicalKeyboardKey.arrowUp: 0x26,
  LogicalKeyboardKey.arrowRight: 0x27,
  LogicalKeyboardKey.arrowDown: 0x28,
  LogicalKeyboardKey.delete: 0x2E,
  LogicalKeyboardKey.capsLock: 0x14,
  LogicalKeyboardKey.shift: 0x10,
  LogicalKeyboardKey.shiftLeft: 0xA0,
  LogicalKeyboardKey.shiftRight: 0xA1,
  LogicalKeyboardKey.control: 0x11,
  LogicalKeyboardKey.controlLeft: 0xA2,
  LogicalKeyboardKey.controlRight: 0xA3,
  LogicalKeyboardKey.alt: 0x12,
  LogicalKeyboardKey.altLeft: 0xA4,
  LogicalKeyboardKey.altRight: 0xA5,
  LogicalKeyboardKey.meta: 0x5B,
  LogicalKeyboardKey.metaLeft: 0x5B,
  LogicalKeyboardKey.metaRight: 0x5C,
  LogicalKeyboardKey.minus: 0xBD,
  LogicalKeyboardKey.equal: 0xBB,
  LogicalKeyboardKey.bracketLeft: 0xDB,
  LogicalKeyboardKey.bracketRight: 0xDD,
  LogicalKeyboardKey.backslash: 0xDC,
  LogicalKeyboardKey.semicolon: 0xBA,
  LogicalKeyboardKey.quote: 0xDE,
  LogicalKeyboardKey.comma: 0xBC,
  LogicalKeyboardKey.period: 0xBE,
  LogicalKeyboardKey.slash: 0xBF,
  LogicalKeyboardKey.backquote: 0xC0,
  LogicalKeyboardKey.f1: 0x70,
  LogicalKeyboardKey.f2: 0x71,
  LogicalKeyboardKey.f3: 0x72,
  LogicalKeyboardKey.f4: 0x73,
  LogicalKeyboardKey.f5: 0x74,
  LogicalKeyboardKey.f6: 0x75,
  LogicalKeyboardKey.f7: 0x76,
  LogicalKeyboardKey.f8: 0x77,
  LogicalKeyboardKey.f9: 0x78,
  LogicalKeyboardKey.f10: 0x79,
  LogicalKeyboardKey.f11: 0x7A,
  LogicalKeyboardKey.f12: 0x7B,
};
