import 'package:faceswap_studio/app/theme/studio_theme.dart';
import 'package:faceswap_studio/shared/widgets/studio_media_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:faceswap_studio/shared/services/studio_fullscreen.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('真实视频首帧前持续 SVG，切换视频和销毁安全', (tester) async {
    const first = String.fromEnvironment('STUDIO_TEST_VIDEO_A');
    const second = String.fromEnvironment('STUDIO_TEST_VIDEO_B');
    expect(first, isNotEmpty);
    expect(second, isNotEmpty);
    Future<void> mount(String path) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: StudioTheme.dark(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 360,
                height: 280,
                child: StudioInlineVideoPlayer(
                  key: const ValueKey('test-video'),
                  filePath: path,
                  initialPosition: const Duration(milliseconds: 1440),
                ),
              ),
            ),
          ),
        ),
      );
    }

    Future<void> firstFrame() async {
      for (
        var i = 0;
        i < 250 &&
            find
                .byKey(const ValueKey('inline-video-loading'))
                .evaluate()
                .isNotEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(const ValueKey('inline-video-loading')), findsNothing);
      expect(find.text('播放失败'), findsNothing);
      final video = tester.widget<Video>(find.byType(Video));
      await tester.runAsync(() => video.controller.waitUntilFirstFrameRendered);
      expect(
        video.controller.player.state.playing,
        isFalse,
        reason: '加载首帧不应自动播放',
      );
      expect(
        video.controller.player.state.position.inMilliseconds,
        greaterThanOrEqualTo(1300),
      );
      expect(tester.takeException(), isNull);
    }

    await mount(first);
    await tester.runAsync(StudioFullscreen.toggle);
    await tester.pump(const Duration(milliseconds: 400));
    expect(StudioFullscreen.active.value, isTrue);
    expect(tester.view.physicalSize, const Size(1920, 1080));
    expect(find.byKey(const ValueKey('inline-video-loading')), findsOneWidget);
    await firstFrame();
    await mount(second);
    expect(find.byKey(const ValueKey('inline-video-loading')), findsOneWidget);
    await firstFrame();
    await mount(first);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(StudioFullscreen.toggle);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    binding.reportData = {
      'realNativeDecoder': true,
      'firstFrameGate': true,
      'replacementGate': true,
      'staysPaused': true,
      'disposeDuringLoading': true,
    };
  }, timeout: const Timeout(Duration(seconds: 90)));
}
