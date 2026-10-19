import 'dart:async';

import 'package:faceswap_studio/app/theme/studio_theme.dart';
import 'package:faceswap_studio/app/widgets/close_behavior_dialog.dart';
import 'package:faceswap_studio/app/widgets/studio_window_lifecycle.dart';
import 'package:faceswap_studio/shared/services/bridge_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _SettingsClient extends BridgeClient {
  Map<String, dynamic> settings = {
    'close_behavior': 'ask',
    'close_behavior_configured': false,
  };
  bool failSave = false;

  @override
  Future<Map<String, dynamic>> getSettings() async => Map.of(settings);

  @override
  Future<Map<String, dynamic>> updateSettings(
    Map<String, dynamic> payload,
  ) async {
    if (failSave) throw StateError('disk full');
    settings = {...settings, ...payload, 'close_behavior_configured': true};
    return Map.of(settings);
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('faceswap_studio/window');
  const codec = StandardMethodCodec();
  late _SettingsClient client;
  late List<MethodCall> nativeCalls;

  void windowsTest(String description, WidgetTesterCallback callback) {
    testWidgets(
      description,
      callback,
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  setUp(() {
    client = _SettingsClient();
    nativeCalls = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      nativeCalls.add(call);
      return null;
    });
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> launch(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: StudioTheme.dark(),
        home: StudioWindowLifecycle(
          client: client,
          child: const Scaffold(body: Text('工作台')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> closeRequest() {
    final completed = Completer<void>();
    binding.channelBuffers.push(
      channel.name,
      codec.encodeMethodCall(const MethodCall('closeRequested')),
      (_) {
        completed.complete();
      },
    );
    return completed.future;
  }

  windowsTest('首次关闭询问、重复点击只开一个弹窗；取消不保存也不执行', (tester) async {
    await launch(tester);
    final first = closeRequest();
    await tester.pumpAndSettle();
    final repeated = closeRequest();
    await tester.pumpAndSettle();
    expect(find.byType(StudioCloseDialog), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await Future.wait([first, repeated]);
    expect(client.settings['close_behavior_configured'], isFalse);
    expect(
      nativeCalls.where((call) => call.method == 'applyCloseAction'),
      isEmpty,
    );
  });

  for (final behavior in ['exit', 'minimize_to_tray']) {
    windowsTest('$behavior 先保存再执行，重建应用后还原偏好且不再询问', (tester) async {
      await launch(tester);
      final request = closeRequest();
      await tester.pumpAndSettle();
      if (behavior == 'exit') {
        await tester.tap(find.byKey(const ValueKey('close-action-exit')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text(behavior == 'exit' ? '确认关闭' : '转入后台'));
      await tester.pumpAndSettle();
      await request;
      expect(client.settings['close_behavior'], behavior);
      expect(client.settings['close_behavior_configured'], isTrue);
      expect(nativeCalls.last.method, 'applyCloseAction');
      expect(nativeCalls.last.arguments, {'close_behavior': behavior});
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await launch(tester);
      expect(nativeCalls.last.method, 'setCloseBehavior');
      expect(nativeCalls.last.arguments, {'close_behavior': behavior});
      await closeRequest();
      await tester.pumpAndSettle();
      expect(find.byType(StudioCloseDialog), findsNothing);
      expect(nativeCalls.last.method, 'applyCloseAction');
    });
  }

  windowsTest('每次询问执行本次动作，下一次仍显示已开启的开关', (tester) async {
    await launch(tester);
    final first = closeRequest();
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('转入后台'));
    await tester.pumpAndSettle();
    await first;
    expect(client.settings['close_behavior'], 'ask');
    final second = closeRequest();
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    await tester.tap(find.byTooltip('取消关闭'));
    await tester.pumpAndSettle();
    await second;
  });

  windowsTest('保存失败保持窗口打开，显示错误且允许再次尝试', (tester) async {
    await launch(tester);
    client.failSave = true;
    final request = closeRequest();
    await tester.pumpAndSettle();
    await tester.tap(find.text('转入后台'));
    await tester.pumpAndSettle();
    await request;
    expect(
      nativeCalls.where((call) => call.method == 'applyCloseAction'),
      isEmpty,
    );
    expect(find.textContaining('未能完成关闭操作'), findsOneWidget);
    final retry = closeRequest();
    await tester.pumpAndSettle();
    expect(find.byType(StudioCloseDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await retry;
  });
}
