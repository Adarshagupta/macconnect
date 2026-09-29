import 'dart:async';
import 'dart:io';

import 'platform.dart';
import 'protocol.dart';

class FoundMac {
  final String name;
  final String host;
  final int port;
  final DateTime seen;
  final String source;

  const FoundMac({
    required this.name,
    required this.host,
    required this.port,
    required this.seen,
    required this.source,
  });
}

/// Listens for the Mac's once-a-second announcement and keeps cable addresses beside it.
class MacFinder {
  RawDatagramSocket? _socket;
  Timer? _expire;
  final Map<String, FoundMac> _macs = {};
  final void Function() onChanged;
  String? savedHost;
  String? error;
  bool _stopped = false;

  MacFinder({required this.onChanged});

  List<FoundMac> get macs {
    final list = _macs.values.toList()
      ..sort((a, b) {
        if (a.source == 'beacon' && b.source != 'beacon') return -1;
        if (b.source == 'beacon' && a.source != 'beacon') return 1;
        return a.host.compareTo(b.host);
      });
    return list;
  }

  Future<void> loadSaved(Future<String?> Function() readHost) async {
    try {
      final host = await readHost();
      if (_stopped || host == null || !looksLikeIPv4(host)) return;
      savedHost = host;
      _macs.putIfAbsent(
        host,
        () => FoundMac(
          name: 'Saved address',
          host: host,
          port: Wire.phonePort,
          seen: DateTime.now(),
          source: 'saved',
        ),
      );
      onChanged();
    } catch (_) {}
  }

  Future<void> start() async {
    try {
      await MacPlatform.prepareNetwork();
    } catch (_) {}
    if (_stopped) return;
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        Wire.phoneBeaconPort,
        reuseAddress: true,
      );
      if (_stopped) {
        socket.close();
        return;
      }
      socket.broadcastEnabled = true;
      _socket = socket;
      socket.listen((event) {
        if (event != RawSocketEvent.read || _stopped) return;
        final packet = socket.receive();
        if (packet == null) return;
        final beacon = parseBeacon(packet.data, packet.address.address);
        if (beacon == null) return;
        _macs[beacon.host] = FoundMac(
          name: beacon.name,
          host: beacon.host,
          port: beacon.port,
          seen: DateTime.now(),
          source: 'beacon',
        );
        onChanged();
      });
    } catch (_) {
      error = 'This phone could not listen for the Mac. You can still type its address.';
      onChanged();
    }
    _expire = Timer.periodic(const Duration(seconds: 2), (_) => _dropStale());
    if (_stopped) {
      _expire?.cancel();
      _socket?.close();
      _socket = null;
    }
  }

  void remember(String host) {
    savedHost = host;
    final existing = _macs[host];
    if (existing == null || existing.source == 'saved') {
      _macs[host] = FoundMac(
        name: existing?.name ?? 'Saved address',
        host: host,
        port: Wire.phonePort,
        seen: DateTime.now(),
        source: existing?.source == 'beacon' ? 'beacon' : 'saved',
      );
      onChanged();
    }
  }

  void setCablePeers(List<String> peers) {
    _macs.removeWhere((_, mac) => mac.source == 'cable');
    for (final peer in peers) {
      if (!looksLikeIPv4(peer) || peer.startsWith('127.')) continue;
      if (_macs.containsKey(peer)) continue;
      _macs[peer] = FoundMac(
        name: 'Mac on the cable',
        host: peer,
        port: Wire.phonePort,
        seen: DateTime.now(),
        source: 'cable',
      );
    }
    onChanged();
  }

  void _dropStale() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 5));
    final removed = <String>[];
    _macs.removeWhere((host, mac) {
      final drop = mac.source == 'beacon' && mac.seen.isBefore(cutoff);
      if (drop) removed.add(host);
      return drop;
    });
    var changed = removed.isNotEmpty;
    final saved = savedHost;
    if (saved != null && looksLikeIPv4(saved) && !_macs.containsKey(saved)) {
      _macs[saved] = FoundMac(
        name: 'Saved address',
        host: saved,
        port: Wire.phonePort,
        seen: DateTime.now(),
        source: 'saved',
      );
      changed = true;
    }
    if (changed) onChanged();
  }

  void dispose() {
    _stopped = true;
    _expire?.cancel();
    _socket?.close();
    _socket = null;
  }
}
