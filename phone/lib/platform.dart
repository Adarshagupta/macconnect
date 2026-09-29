import 'dart:typed_data';

import 'package:flutter/services.dart';

class CableStatus {
  final bool usb;
  final String? address;
  final List<String> peers;

  const CableStatus({required this.usb, required this.address, required this.peers});

  static const empty = CableStatus(usb: false, address: null, peers: []);
}

/// Android side of the phone app: H.264 decode, screen-on, and USB network info.
class MacPlatform {
  static const _channel = MethodChannel('macconnect/phone');

  static Future<void> prepareNetwork() {
    return _channel.invokeMethod<void>('prepareNetwork');
  }

  static Future<CableStatus> cableStatus() async {
    final raw = await _channel.invokeMethod<dynamic>('cableStatus');
    if (raw is! Map) return CableStatus.empty;
    final peers = <String>[];
    final listed = raw['peers'];
    if (listed is List) {
      for (final peer in listed) {
        if (peer is String && peer.isNotEmpty) peers.add(peer);
      }
    }
    final address = raw['address'];
    return CableStatus(
      usb: raw['usb'] == true,
      address: address is String && address.isNotEmpty ? address : null,
      peers: peers,
    );
  }

  static Future<int> startDecoder(int width, int height) async {
    final id = await _channel.invokeMethod<int>('startDecoder', {
      'width': width,
      'height': height,
    });
    if (id == null || id < 0) {
      throw StateError('This phone could not start the video decoder.');
    }
    return id;
  }

  static Future<void> feed(Uint8List annexB) {
    return _channel.invokeMethod<void>('feed', annexB);
  }

  static Future<void> stopDecoder() async {
    try {
      await _channel.invokeMethod<void>('stopDecoder');
    } catch (_) {}
  }

  static Future<void> keepScreenOn(bool on) async {
    try {
      await _channel.invokeMethod<void>('keepScreenOn', {'on': on});
    } catch (_) {}
  }
}
