import 'dart:ffi';

import 'package:faceswap_studio/app/theme/studio_theme.dart';
import 'package:faceswap_studio/app/widgets/close_behavior_dialog.dart';
import 'package:faceswap_studio/app/widgets/studio_window_lifecycle.dart';
import 'package:faceswap_studio/shared/services/bridge_client.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

class _Client extends BridgeClient {
  Map<String, dynamic> settings = {
    'close_behavior': 'ask',
    'close_behavior_configured': false,
  };

  @override
  Future<Map<String, dynamic>> getSettings() async => Map.of(settings);

  @override
  Future<Map<String, dynamic>> updateSettings(
    Map<String, dynamic> payload,
  ) async {
    settings = {...settings, ...payload, 'close_behavior_configured': true};
    return Map.of(settings);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('真实 WM_CLOSE、取消、托盘隐藏/恢复及每次询问', (tester) async {
    final user = DynamicLibrary.open('user32.dll');
    final kernel = DynamicLibrary.open('kernel32.dll');
    final findWindow = user
        .lookupFunction<
          IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
          int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
        >('FindWindowExW');
    final windowPid = user
        .lookupFunction<
          Uint32 Function(IntPtr, Pointer<Uint32>),
          int Function(int, Pointer<Uint32>)
        >('GetWindowThreadProcessId');
    final currentPid = kernel.lookupFunction<Uint32 Function(), int Function()>(
      'GetCurrentProcessId',
    );
    final post = user
        .lookupFunction<
          Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
          int Function(int, int, int, int)
        >('PostMessageW');
    final visible = user
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'IsWindowVisible',
        );
    final register = user
        .lookupFunction<
          Uint32 Function(Pointer<Utf16>),
          int Function(Pointer<Utf16>)
        >('RegisterWindowMessageW');
    final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    final messageName = 'FaceSwapStudio.ActivateWindow'.toNativeUtf16();
    final pid = calloc<Uint32>();
    late int window;
    late int activate;
    try {
      var after = 0;
      while (true) {
        window = findWindow(0, after, className, nullptr);
        if (window == 0) break;
        windowPid(window, pid);
        if (pid.value == currentPid()) break;
        after = window;
      }
      expect(window, isNonZero);
      windowPid(window, pid);
      // 只向当前测试进程的窗口发送消息，不触碰用户的软件实例。
      expect(pid.value, currentPid());
      activate = register(messageName);
    } finally {
      calloc.free(className);
      calloc.free(messageName);
      calloc.free(pid);
    }
    final client = _Client();
    await tester.pumpWidget(
      MaterialApp(
        theme: StudioTheme.dark(),
        home: StudioWindowLifecycle(
          client: client,
          child: const Scaffold(
            body: Center(child: Text('关闭行为 · Windows 集成验证')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 40 && !condition(); i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(condition(), isTrue);
    }

    void close() => expect(post(window, 0x0010, 0, 0), isNonZero);
    void restore() => expect(post(window, activate, 0, 0), isNonZero);

    close();
    await until(() => find.byType(StudioCloseDialog).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(visible(window), isNonZero);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(visible(window), isNonZero);
    expect(client.settings['close_behavior_configured'], isFalse);

    close();
    await until(() => find.byType(StudioCloseDialog).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    await tester.tap(find.text('转入后台'));
    await until(() => visible(window) == 0);
    expect(client.settings['close_behavior'], 'minimize_to_tray');
    restore();
    await until(() => visible(window) != 0);
    close();
    await until(() => visible(window) == 0);
    expect(find.byType(StudioCloseDialog), findsNothing);
    restore();
    await until(() => visible(window) != 0);

    client.settings = {
      'close_behavior': 'ask',
      'close_behavior_configured': true,
    };
    await const MethodChannel(
      'faceswap_studio/window',
    ).invokeMethod<void>('setCloseBehavior', {'close_behavior': 'ask'});
    close();
    await until(() => find.byType(StudioCloseDialog).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(StudioCloseDialog), findsNothing);
    expect(visible(window), isNonZero);
    binding.reportData = {
      'realNativeWindow': true,
      'wmCloseShowsFlutterDialog': true,
      'cancelKeepsWindowVisible': true,
      'nativeTrayHideAndRestore': true,
      'rememberedBackgroundSkipsDialog': true,
      'alwaysAskRestored': true,
      'settingsBackend':
          'isolated memory fixture; disk persistence verified by Python tests',
    };
  });
}
