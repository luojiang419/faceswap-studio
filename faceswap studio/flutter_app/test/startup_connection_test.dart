import 'dart:async';

import 'package:faceswap_studio/shared/services/bridge_client.dart';
import 'package:faceswap_studio/shared/services/startup_connection.dart';
import 'package:flutter_test/flutter_test.dart';

class _LateClient extends BridgeClient {
  int reads = 0;
  int handshakes = 0;
  bool available = false;
  Completer<Map<String, dynamic>>? pending;

  @override
  Future<Map<String, dynamic>> getSettings() async {
    reads++;
    if (pending != null) return pending!.future;
    if (!available) throw StateError('Bridge 正在启动');
    return {'theme': 'dark', 'close_behavior': 'exit'};
  }

  @override
  Future<Map<String, dynamic>> confirmStartup() async {
    handshakes++;
    if (handshakes == 1) throw StateError('握手暂未就绪');
    return {'ok': true};
  }
}

void main() {
  testWidgets('先读本地设置，晚连接后补发握手，成功后停止重试', (tester) async {
    final client = _LateClient();
    final applied = <Map<String, dynamic>>[];
    final connection = StartupConnection(
      client: client,
      onSettings: applied.add,
      readLocalSettings: () async => {'theme': 'light'},
    );
    await connection.start();
    expect(applied.single['theme'], 'light');
    expect(client.handshakes, 0);
    client.available = true;
    await tester.pump(const Duration(milliseconds: 500));
    expect(applied.last['theme'], 'dark');
    expect(client.handshakes, 1);
    await tester.pump(const Duration(milliseconds: 500));
    expect(client.handshakes, 2);
    final reads = client.reads;
    await tester.pump(const Duration(seconds: 10));
    expect(client.reads, reads);
    connection.dispose();
  });

  testWidgets('请求卡住时限时重试，退出后晚返回不再写设置或发送握手', (tester) async {
    final client = _LateClient()..pending = Completer();
    final applied = <Map<String, dynamic>>[];
    final connection = StartupConnection(
      client: client,
      onSettings: applied.add,
      readLocalSettings: () async => {},
    );
    final started = connection.start();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    await started;
    await tester.pump(const Duration(milliseconds: 500));
    expect(client.reads, 2);
    connection.dispose();
    client.pending!.complete({'theme': 'dark'});
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(applied, isEmpty);
    expect(client.reads, 2);
    expect(client.handshakes, 0);
  });
}
