import 'package:faceswap_studio/app/theme/studio_theme.dart';
import 'package:faceswap_studio/shared/widgets/studio_media_viewer.dart';
import 'package:faceswap_studio/shared/widgets/studio_video_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('真实原视频和输出小格原位播放暂停，双击共享播放器全屏再返回', (tester) async {
    const original = String.fromEnvironment('STUDIO_TEST_VIDEO_A');
    const output = String.fromEnvironment('STUDIO_TEST_VIDEO_B');
    expect(original, isNotEmpty);
    expect(output, isNotEmpty);
    await tester.pumpWidget(
      MaterialApp(
        theme: StudioTheme.dark(),
        home: Scaffold(
          body: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final path in [original, output])
                  SizedBox(
                    width: 120,
                    height: 92,
                    child: StudioInlineVideoPlayer(
                      key: ValueKey(path),
                      filePath: path,
                      thumbnailControls: true,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(Video), findsNothing);
    expect(find.byType(StudioVideoControls), findsNothing);

    for (final path in [original, output]) {
      final tile = find.byKey(ValueKey(path));
      final surface = find.descendant(
        of: tile,
        matching: find.byType(StudioVideoThumbnailSurface),
      );
      await tester.tap(surface);
      await tester.pump(const Duration(milliseconds: 400));
      for (var i = 0; i < 250; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find
                .descendant(of: tile, matching: find.byType(Video))
                .evaluate()
                .isNotEmpty &&
            find
                .descendant(
                  of: tile,
                  matching: find.byKey(const ValueKey('inline-video-loading')),
                )
                .evaluate()
                .isEmpty) {
          break;
        }
      }
      expect(find.text('播放失败'), findsNothing);
      final video = tester.widget<Video>(
        find.descendant(of: tile, matching: find.byType(Video)),
      );
      final player = video.controller.player;
      expect(player.state.playing, isTrue);
      final position = player.state.position;
      await tester.pump(const Duration(seconds: 1));
      expect(player.state.position, greaterThan(position));
      expect(
        tester.getSize(find.descendant(of: tile, matching: find.byType(Video))),
        const Size(120, 92),
      );
      await tester.tap(surface);
      await tester.pump(const Duration(milliseconds: 400));
      expect(player.state.playing, isFalse);
      final paused = player.state.position;
      await tester.tap(surface);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(surface);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(Dialog), findsOneWidget);
      final fullscreenVideo = tester.widget<Video>(find.byType(Video).last);
      expect(identical(fullscreenVideo.controller.player, player), isTrue);
      expect(player.state.playing, isTrue);
      expect(player.state.position, greaterThanOrEqualTo(paused));
      await tester.tap(find.byTooltip('退出全屏（Esc）').first);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(Dialog), findsNothing);
      expect(
        identical(
          tester
              .widget<Video>(
                find.descendant(of: tile, matching: find.byType(Video)),
              )
              .controller
              .player,
          player,
        ),
        isTrue,
      );
      await player.pause();
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    binding.reportData = {
      'nativeDecoder': true,
      'inlinePlaybackBothVideos': true,
      'singleClickPause': true,
      'doubleClickFullscreen': true,
      'sharedPlayerOnReturn': true,
    };
  }, timeout: const Timeout(Duration(seconds: 90)));
}
