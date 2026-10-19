import 'dart:async';

import 'bridge_client.dart';
import 'local_startup.dart';

/// 首帧不等待 Bridge；连接成功后恢复设置并补发安装/更新握手。
class StartupConnection {
  StartupConnection({
    required this.client,
    required this.onSettings,
    this.readLocalSettings = readLocalStartupSettings,
  });

  final BridgeClient client;
  final void Function(Map<String, dynamic>) onSettings;
  final Future<Map<String, dynamic>> Function() readLocalSettings;
  Timer? _retry;
  bool _active = true;

  Future<void> start() async {
    final local = await readLocalSettings();
    if (!_active) return;
    if (local.isNotEmpty) onSettings(local);
    await _connect();
  }

  Future<void> _connect() async {
    try {
      final settings = await client.getSettings().timeout(
        const Duration(milliseconds: 800),
      );
      if (!_active) return;
      onSettings(settings);
      await client.confirmStartup().timeout(const Duration(milliseconds: 800));
    } catch (_) {
      if (_active) {
        _retry = Timer(const Duration(milliseconds: 500), _connect);
      }
    }
  }

  void dispose() {
    _active = false;
    _retry?.cancel();
  }
}
