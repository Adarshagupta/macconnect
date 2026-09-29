import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'keys.dart';
import 'platform.dart';
import 'protocol.dart';
import 'session.dart';

class DesktopPage extends StatefulWidget {
  final MacSession session;
  final Hello hello;
  final String title;

  const DesktopPage({
    super.key,
    required this.session,
    required this.hello,
    required this.title,
  });

  @override
  State<DesktopPage> createState() => _DesktopPageState();
}

class _DesktopPageState extends State<DesktopPage> {
  final _cursor = ValueNotifier<Offset?>(null);
  final _held = <int>{};
  int? _textureId;
  String? _error;
  bool _waiting = true;
  bool _keyboardOpen = false;
  bool _rightNext = false;
  bool _gotKey = false;
  bool _leftDown = false;
  bool _dragging = false;
  bool _scrollMode = false;
  bool _handled = false;
  int _pointers = 0;
  int? _primary;
  int _button = Wire.buttonLeft;
  Offset? _origin;
  (double, double)? _downNorm;
  Offset? _lastFocal;
  double _scrollAccum = 0;
  Timer? _longPress;
  Size _box = Size.zero;

  static const _slop = 14.0;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _start();
  }

  Future<void> _start() async {
    try {
      final id = await MacPlatform.startDecoder(widget.hello.width, widget.hello.height);
      if (!mounted) return;
      widget.session.listen(
        frame: _onFrame,
        cursor: (x, y) => _cursor.value = Offset(x, y),
        closed: _onClosed,
      );
      widget.session.sendAccept();
      await MacPlatform.keepScreenOn(true);
      if (!mounted) return;
      setState(() => _textureId = id);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'The picture could not start. $error');
    }
  }

  Future<void> _onFrame(Uint8List frame) async {
    if (!_gotKey && !annexBHasKeyframe(frame)) return;
    _gotKey = true;
    await MacPlatform.feed(frame);
    if (_waiting && mounted) {
      setState(() => _waiting = false);
    }
  }

  void _onClosed(String reason) {
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  bool _onHardwareKey(KeyEvent event) {
    if (_keyboardOpen) return false;
    final virtualKey = windowsVirtualKey(event.logicalKey);
    if (virtualKey == null) return false;
    if (event is KeyUpEvent) {
      widget.session.key(virtualKey, false);
    } else if (event is KeyDownEvent || event is KeyRepeatEvent) {
      widget.session.key(virtualKey, true);
    }
    return true;
  }

  Rect _fitted(Size size) {
    final aspect = widget.hello.width / widget.hello.height;
    final viewAspect = size.width / size.height;
    if (viewAspect > aspect) {
      final width = size.height * aspect;
      return Rect.fromLTWH((size.width - width) / 2, 0, width, size.height);
    }
    final height = size.width / aspect;
    return Rect.fromLTWH(0, (size.height - height) / 2, size.width, height);
  }

  (double, double)? _norm(Offset local) {
    if (_box.isEmpty) return null;
    final rect = _fitted(_box);
    if (!rect.contains(local)) return null;
    final x = ((local.dx - rect.left) / rect.width).clamp(0.0, 1.0);
    final y = ((local.dy - rect.top) / rect.height).clamp(0.0, 1.0);
    return (x.toDouble(), y.toDouble());
  }

  void _pointerDown(PointerDownEvent event) {
    _pointers += 1;
    if (_pointers > 1) {
      _longPress?.cancel();
      if (_leftDown) {
        widget.session.mouseUp(_button, _downNorm?.$1 ?? 0, _downNorm?.$2 ?? 0);
        _leftDown = false;
      }
      _scrollMode = true;
      _lastFocal = event.localPosition;
      return;
    }
    _primary = event.pointer;
    _origin = event.localPosition;
    _dragging = false;
    _scrollMode = false;
    _handled = false;
    _downNorm = _norm(event.localPosition);
    final point = _downNorm;
    if (point != null) widget.session.mouseMove(point.$1, point.$2);
    _longPress?.cancel();
    _longPress = Timer(const Duration(milliseconds: 450), () {
      final down = _downNorm;
      if (_dragging || _scrollMode || down == null || _handled) return;
      _handled = true;
      widget.session.mouseDown(Wire.buttonRight, down.$1, down.$2);
      widget.session.mouseUp(Wire.buttonRight, down.$1, down.$2);
    });
  }

  void _pointerMove(PointerMoveEvent event) {
    if (_scrollMode) {
      final last = _lastFocal;
      _lastFocal = event.localPosition;
      if (last == null) return;
      _scrollAccum += last.dy - event.localPosition.dy;
      final lines = _scrollAccum ~/ 36;
      if (lines != 0) {
        _scrollAccum -= lines * 36;
        final point = _norm(event.localPosition) ?? _downNorm;
        if (point != null) {
          widget.session.mouseScroll(point.$1, point.$2, lines * 120);
        }
      }
      return;
    }
    if (event.pointer != _primary) return;
    final origin = _origin;
    if (!_dragging && origin != null && (event.localPosition - origin).distance > _slop) {
      final down = _downNorm;
      if (down != null) {
        _dragging = true;
        _longPress?.cancel();
        _button = _rightNext ? Wire.buttonRight : Wire.buttonLeft;
        _rightNext = false;
        widget.session.mouseDown(_button, down.$1, down.$2);
        _leftDown = true;
      }
    }
    final point = _norm(event.localPosition);
    if (point != null) widget.session.mouseMove(point.$1, point.$2);
  }

  void _pointerUp(PointerEvent event) {
    _pointers = _pointers > 0 ? _pointers - 1 : 0;
    if (_pointers > 0) return;
    _longPress?.cancel();
    if (_scrollMode) {
      _scrollMode = false;
      _primary = null;
      return;
    }
    final point = _norm(event.localPosition) ?? _downNorm;
    if (point != null && !_handled) {
      if (_leftDown) {
        widget.session.mouseMove(point.$1, point.$2);
        widget.session.mouseUp(_button, point.$1, point.$2);
      } else {
        final button = _rightNext ? Wire.buttonRight : Wire.buttonLeft;
        _rightNext = false;
        widget.session.mouseMove(point.$1, point.$2);
        widget.session.mouseDown(button, point.$1, point.$2);
        widget.session.mouseUp(button, point.$1, point.$2);
      }
    } else if (_leftDown && point != null) {
      widget.session.mouseUp(_button, point.$1, point.$2);
    }
    _leftDown = false;
    _dragging = false;
    _handled = false;
    _primary = null;
  }

  Future<void> _openKeyboard() async {
    setState(() => _keyboardOpen = true);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return MacKeyboard(
          held: _held,
          onType: widget.session.typeCharacter,
          onTap: (virtualKey) {
            widget.session.key(virtualKey, true);
            widget.session.key(virtualKey, false);
          },
          onModifier: (virtualKey, down) {
            if (down) {
              _held.add(virtualKey);
            } else {
              _held.remove(virtualKey);
            }
            widget.session.key(virtualKey, down);
          },
        );
      },
    );
    if (mounted) setState(() => _keyboardOpen = false);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _longPress?.cancel();
    for (final virtualKey in _held.toList()) {
      widget.session.key(virtualKey, false);
    }
    unawaited(MacPlatform.keepScreenOn(false));
    unawaited(MacPlatform.stopDecoder());
    unawaited(widget.session.close());
    _cursor.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hello = widget.hello;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: SizedBox(
              height: 48,
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Disconnect',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                  Expanded(
                    child: Text(
                      widget.title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  IconButton(
                    tooltip: _rightNext ? 'Next tap is a right click' : 'Right click',
                    onPressed: () => setState(() => _rightNext = !_rightNext),
                    icon: Icon(
                      Icons.mouse,
                      color: _rightNext ? const Color(0xFF8EB7FF) : Colors.white,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Keyboard',
                    onPressed: _openKeyboard,
                    icon: const Icon(Icons.keyboard, color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                _box = Size(constraints.maxWidth, constraints.maxHeight);
                final rect = _fitted(_box);
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_textureId != null)
                      Positioned.fromRect(
                        rect: rect,
                        child: Texture(
                          textureId: _textureId!,
                          filterQuality: FilterQuality.low,
                        ),
                      ),
                    Positioned.fill(
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: _error == null ? _pointerDown : null,
                        onPointerMove: _error == null ? _pointerMove : null,
                        onPointerUp: _error == null ? _pointerUp : null,
                        onPointerCancel: _error == null ? _pointerUp : null,
                        child: const SizedBox.expand(),
                      ),
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ValueListenableBuilder<Offset?>(
                          valueListenable: _cursor,
                          builder: (context, cursor, _) {
                            if (cursor == null) return const SizedBox.shrink();
                            return Stack(
                              children: [
                                Positioned(
                                  left: rect.left + cursor.dx * rect.width - 1,
                                  top: rect.top + cursor.dy * rect.height - 1,
                                  child: const CustomPaint(
                                    size: Size(16, 20),
                                    painter: _CursorPainter(),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                    if (_waiting && _error == null)
                      const IgnorePointer(
                        child: Center(
                          child: Text(
                            'Waiting for the picture…',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ),
                      ),
                    if (_error != null)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CursorPainter extends CustomPainter {
  const _CursorPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(0, size.height)
      ..lineTo(size.width * 0.38, size.height * 0.72)
      ..lineTo(size.width * 0.62, size.height)
      ..lineTo(size.width * 0.78, size.height * 0.88)
      ..lineTo(size.width * 0.48, size.height * 0.62)
      ..lineTo(size.width * 0.95, size.width * 0.55)
      ..close();
    canvas.drawPath(path, Paint()..color = Colors.black..strokeWidth = 3..style = PaintingStyle.stroke..strokeJoin = StrokeJoin.round);
    canvas.drawPath(path, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class MacKeyboard extends StatefulWidget {
  final Set<int> held;
  final void Function(String character) onType;
  final void Function(int virtualKey) onTap;
  final void Function(int virtualKey, bool down) onModifier;

  const MacKeyboard({
    super.key,
    required this.held,
    required this.onType,
    required this.onTap,
    required this.onModifier,
  });

  @override
  State<MacKeyboard> createState() => _MacKeyboardState();
}

class _MacKeyboardState extends State<MacKeyboard> {
  final _text = TextEditingController();
  String _previous = '';

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _changed(String value) {
    if (value.length > _previous.length && value.startsWith(_previous)) {
      for (final rune in value.substring(_previous.length).runes) {
        widget.onType(String.fromCharCode(rune));
      }
    } else if (value.length < _previous.length && _previous.startsWith(value)) {
      for (var i = 0; i < _previous.length - value.length; i++) {
        widget.onTap(0x08);
      }
    } else {
      widget.onTap(0x08);
      for (final rune in value.runes) {
        widget.onType(String.fromCharCode(rune));
      }
    }
    _previous = value;
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 12, 12, 12 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _text,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Type here to type on the Mac',
              border: OutlineInputBorder(),
            ),
            onChanged: _changed,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _mod('Command', 0x11),
              _mod('Option', 0x12),
              _mod('Control', 0x5B),
              _mod('Shift', 0x10),
              _key('Esc', 0x1B),
              _key('Tab', 0x09),
              _key('Enter', 0x0D),
              _key('Delete', 0x2E),
              _key('←', 0x25),
              _key('↑', 0x26),
              _key('↓', 0x28),
              _key('→', 0x27),
            ],
          ),
        ],
      ),
    );
  }

  Widget _mod(String label, int virtualKey) {
    final on = widget.held.contains(virtualKey);
    return FilterChip(
      label: Text(label),
      selected: on,
      onSelected: (selected) {
        widget.onModifier(virtualKey, selected);
        setState(() {});
      },
    );
  }

  Widget _key(String label, int virtualKey) {
    return ActionChip(
      label: Text(label),
      onPressed: () => widget.onTap(virtualKey),
    );
  }
}
