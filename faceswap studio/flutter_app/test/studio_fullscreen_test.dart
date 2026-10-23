import 'package:faceswap_studio/shared/services/studio_fullscreen.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('软件全屏切换调用原生入口，保存应用状态', () async {
    final calls = <String>[];
    const channel = MethodChannel('com.alexmercerind/media_kit_video');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return null;
        });
    StudioFullscreen.active.value = false;
    await StudioFullscreen.toggle();
    expect(StudioFullscreen.active.value, isTrue);
    await StudioFullscreen.toggle();
    expect(StudioFullscreen.active.value, isFalse);
    expect(calls, [
      'Utils.EnterNativeFullscreen',
      'Utils.ExitNativeFullscreen',
    ]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}
