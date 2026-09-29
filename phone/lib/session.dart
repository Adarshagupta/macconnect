import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'protocol.dart';

/// One connection to the Mac. The Mac sends the picture; this phone sends touch and keys.
class MacSession {
  Socket? _socket;
  StreamSubscription<Uint8List>? _subscription;
  final MessageBuffer _reader = MessageBuffer();
  final Completer<Hello> _hello = Completer<Hello>();
  Timer? _ping;
  Future<void> _writes = Future<void>.value();
  bool _closed = false;
  bool _acceptSent = false;
  String? _closeReason;
  Uint8List? _pendingFrame;
  Future<void>? _pump;

  Future<void> Function(Uint8List frame)? onFrame;
  void Function(double x, double y)? onCursor;
  void Function(String reason)? _onClosed;

  /// Completes with the Mac's name and picture size. Pings start immediately so a slow
  /// decoder setup does not look like a dead phone to the Mac.
  Future<Hello> open(String host, int port) async {
    final socket = await Socket.connect(
      InternetAddress(host, type: InternetAddressType.IPv4),
      port,
      timeout: const Duration(seconds: 5),
    );
    _socket = socket;
    socket.setOption(SocketOption.tcpNoDelay, true);
    unawaited(_hello.future.then<void>((_) {}, onError: (_) {}));
    _subscription = socket.listen(
      _onBytes,
      onError: (Object error) => fail('$error'),
      onDone: () => fail('The Mac closed the connection'),
    );
    _ping = Timer.periodic(const Duration(seconds: 2), (_) {
      send(Wire.ping, Uint8List(0));
    });
    send(Wire.ping, Uint8List(0));
    try {
      return await _hello.future.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      fail('The Mac did not answer');
      throw StateError('The Mac did not answer');
    }
  }

  void listen({
    required Future<void> Function(Uint8List frame) frame,
    required void Function(double x, double y) cursor,
    required void Function(String reason) closed,
  }) {
    onFrame = frame;
    onCursor = cursor;
    _onClosed = closed;
    if (_closed) {
      closed(_closeReason ?? 'Disconnected');
      return;
    }
    _pumpFrames();
  }

  void sendAccept() {
    if (_acceptSent || _closed) return;
    _acceptSent = true;
    send(Wire.accept, Uint8List(0));
  }

  void mouseMove(double x, double y) {
    send(Wire.mouse, mousePayload(Wire.mouseMove, Wire.buttonNone, x, y, 0));
  }

  void mouseDown(int button, double x, double y) {
    send(Wire.mouse, mousePayload(Wire.mouseDown, button, x, y, 0));
  }

  void mouseUp(int button, double x, double y) {
    send(Wire.mouse, mousePayload(Wire.mouseUp, button, x, y, 0));
  }

  void mouseScroll(double x, double y, int wheel) {
    send(Wire.mouse, mousePayload(Wire.mouseScroll, Wire.buttonNone, x, y, wheel));
  }

  void key(int virtualKey, bool down) {
    send(Wire.key, keyPayload(virtualKey, down));
  }

  void typeCharacter(String character) {
    final strokes = keystrokesForCharacter(character);
    if (strokes == null) return;
    for (final stroke in strokes) {
      key(stroke.virtualKey, stroke.down);
    }
  }

  /// Local close. Does not notify [listen], so a page can disconnect without popping itself twice.
  Future<void> close() async {
    try {
      await _writes;
    } catch (_) {}
    fail('Disconnected', notify: false);
  }

  void fail(String reason, {bool notify = true}) {
    if (_closed) return;
    _closed = true;
    _closeReason = reason;
    _ping?.cancel();
    final subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel() ?? Future<void>.value());
    _socket?.destroy();
    _socket = null;
    if (!_hello.isCompleted) {
      _hello.completeError(StateError(reason));
    }
    if (notify) {
      _onClosed?.call(reason);
    }
  }

  void send(int type, Uint8List payload) {
    if (_closed) return;
    _writes = _writes.then((_) async {
      final socket = _socket;
      if (_closed || socket == null) return;
      final bytes = Uint8List(5 + payload.length);
      final view = ByteData.sublistView(bytes);
      bytes[0] = type;
      view.setUint32(1, payload.length, Endian.little);
      bytes.setRange(5, bytes.length, payload);
      socket.add(bytes);
      await socket.flush();
    }).catchError((Object _) {
      fail('Could not send to the Mac');
    });
  }

  void _onBytes(Uint8List data) {
    if (_closed) return;
    try {
      _reader.add(data);
      while (true) {
        final message = _reader.next();
        if (message == null) return;
        _handle(message);
      }
    } catch (error) {
      fail('$error');
    }
  }

  void _handle(Incoming message) {
    switch (message.type) {
      case Wire.hello:
        final hello = Hello.parse(message.payload);
        if (hello != null && !_hello.isCompleted) {
          _hello.complete(hello);
        }
      case Wire.frame:
        _pendingFrame = message.payload;
        _pumpFrames();
      case Wire.cursor:
        final cursor = parseCursor(message.payload);
        if (cursor != null) onCursor?.call(cursor.$1, cursor.$2);
      case Wire.pong:
        break;
      default:
        break;
    }
  }

  /// Keeps only the newest picture while the decoder is busy, matching the Mac agent.
  void _pumpFrames() {
    if (_pump != null || onFrame == null || _pendingFrame == null) return;
    _pump = () async {
      while (!_closed && _pendingFrame != null && onFrame != null) {
        final frame = _pendingFrame!;
        _pendingFrame = null;
        try {
          await onFrame!(frame);
        } catch (_) {}
      }
      _pump = null;
      if (!_closed && _pendingFrame != null && onFrame != null) {
        _pumpFrames();
      }
    }();
  }
}
