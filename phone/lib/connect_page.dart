import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desktop_page.dart';
import 'discovery.dart';
import 'platform.dart';
import 'protocol.dart';
import 'session.dart';

const _hostKey = 'macHost';

class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  late final MacFinder _finder = MacFinder(onChanged: _onMacs);
  final _address = TextEditingController();
  Timer? _cableTimer;
  bool _cable = false;
  bool _connecting = false;
  bool _viewOnly = false;
  String? _error;
  bool _usb = false;
  String? _usbAddress;

  @override
  void initState() {
    super.initState();
    _boot();
    _cableTimer = Timer.periodic(const Duration(seconds: 2), (_) => _refreshCable());
  }

  Future<void> _boot() async {
    await _finder.loadSaved(() async {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_hostKey);
    });
    await _finder.start();
    await _refreshCable();
  }

  void _onMacs() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshCable() async {
    if (!mounted) return;
    try {
      final status = await MacPlatform.cableStatus();
      if (!mounted) return;
      setState(() {
        _usb = status.usb;
        _usbAddress = status.address;
      });
      if (_cable) _finder.setCablePeers(status.peers);
    } catch (_) {}
  }

  Future<void> _connect(String host, int port, String name) async {
    if (_connecting) return;
    final address = host.trim();
    if (!looksLikeIPv4(address)) {
      setState(() => _error = 'Type an address like 192.168.1.20.');
      return;
    }
    setState(() {
      _connecting = true;
      _error = null;
    });
    final session = MacSession();
    try {
      final hello = await session.open(address, port);
      if (!mounted) {
        await session.close();
        return;
      }
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_hostKey, address);
      } catch (_) {}
      if (!mounted) {
        await session.close();
        return;
      }
      _finder.remember(address);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DesktopPage(
            session: session,
            hello: hello,
            title: name,
            viewOnly: _viewOnly,
          ),
        ),
      );
    } catch (error) {
      await session.close();
      if (mounted) setState(() => _error = friendlyConnectError(error));
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  void dispose() {
    _cableTimer?.cancel();
    _finder.dispose();
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final macs = _finder.macs.where((mac) => _cable || mac.source != 'cable').toList();
    return Scaffold(
      appBar: AppBar(title: const Text('MacConnect')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            Text(
              'Use your Mac from this phone.',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              _cable
                  ? 'Plug the phone into the Mac with a USB cable.'
                  : 'The phone and the Mac need to be on the same Wi-Fi.',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: const Color(0xFFC8C4BA)),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('View only'),
              subtitle: const Text('Watch the Mac. Touch and keys are not sent.'),
              value: _viewOnly,
              onChanged: _connecting ? null : (value) => setState(() => _viewOnly = value),
            ),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Wi-Fi'), icon: Icon(Icons.wifi)),
                ButtonSegment(value: true, label: Text('Cable'), icon: Icon(Icons.usb)),
              ],
              selected: {_cable},
              onSelectionChanged: _connecting
                  ? null
                  : (selected) {
                      setState(() => _cable = selected.first);
                      if (selected.first) {
                        _refreshCable();
                      } else {
                        _finder.setCablePeers(const []);
                      }
                    },
            ),
            if (_cable) ...[
              const SizedBox(height: 16),
              const _CableHelp(),
              const SizedBox(height: 12),
              Text(
                _usb
                    ? 'USB network is on${_usbAddress == null ? '' : ' ($_usbAddress)'}.'
                    : 'USB tethering is off. You can still use USB debugging.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _connecting ? null : () => _connect('127.0.0.1', Wire.phonePort, 'USB debugging'),
                icon: const Icon(Icons.usb),
                label: const Text('Connect through USB debugging'),
              ),
            ],
            const SizedBox(height: 20),
            Text('Macs', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (macs.isEmpty)
              Text(
                _finder.error ??
                    (_cable
                        ? 'Looking for the Mac on the cable…'
                        : 'Looking for the Mac on this network…'),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: const Color(0xFFC8C4BA)),
              )
            else
              ...macs.map(
                (mac) => Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    title: Text(mac.name),
                    subtitle: Text(mac.host),
                    trailing: _connecting
                        ? null
                        : const Icon(Icons.chevron_right),
                    onTap: _connecting ? null : () => _connect(mac.host, mac.port, mac.name),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _address,
              keyboardType: TextInputType.text,
              decoration: const InputDecoration(
                labelText: "Mac's address",
                hintText: '192.168.1.20',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (value) => _connect(value, Wire.phonePort, 'Mac'),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _connecting ? null : () => _connect(_address.text, Wire.phonePort, 'Mac'),
              child: _connecting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Connect'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
    );
  }
}

class _CableHelp extends StatelessWidget {
  const _CableHelp();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('USB tethering', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'On the phone, open Settings, then Hotspot and tethering, and turn on USB tethering. The Mac should show up in the list.',
          style: style,
        ),
        const SizedBox(height: 10),
        Text('USB debugging', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Turn on Developer options and USB debugging, then accept the prompt. The Mac forwards the cable when adb is installed (brew install android-platform-tools).',
          style: style,
        ),
      ],
    );
  }
}

String friendlyConnectError(Object error) {
  if (error is StateError && error.message.isNotEmpty) {
    if (error.message == 'The Mac did not answer') {
      return 'The Mac did not answer. Reinstall the Mac agent, then try again.';
    }
    return error.message;
  }
  final text = '$error'.toLowerCase();
  if (text.contains('timed out') || text.contains('timeout')) {
    return 'Could not reach the Mac. Check the address, and that the Mac agent is running.';
  }
  if (text.contains('connection refused') || text.contains('errno = 111') || text.contains('errno = 61')) {
    return 'The Mac refused the connection. Reinstall the Mac agent so it listens for the phone.';
  }
  if (text.contains('unreachable') || text.contains('no route')) {
    return 'This phone cannot reach that address. For a cable, turn on USB tethering.';
  }
  return 'Could not connect to the Mac.';
}
