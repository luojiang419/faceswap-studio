import 'package:faceswap_studio/app/theme/studio_theme.dart';
import 'package:faceswap_studio/shared/widgets/studio_video_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('进度边界与小时格式', () {
    expect(formatStudioVideoTime(const Duration(seconds: 3661)), '1:01:01');
    expect(formatStudioVideoTime(const Duration(seconds: -1)), '00:00');
    expect(
      clampStudioVideoPosition(
        const Duration(seconds: -5),
        const Duration(seconds: 10),
      ),
      Duration.zero,
    );
    expect(
      clampStudioVideoPosition(
        const Duration(seconds: 50),
        const Duration(seconds: 10),
      ),
      const Duration(seconds: 10),
    );
    expect(
      clampStudioVideoPosition(const Duration(seconds: 5), Duration.zero),
      Duration.zero,
    );
  });

  testWidgets('播放、快进快退、拖动进度和全屏按钮传递正确', (tester) async {
    var position = const Duration(seconds: 2);
    var playing = false;
    var fullscreen = false;
    final seeks = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Center(
              child: SizedBox(
                width: 620,
                child: StudioVideoControls(
                  position: position,
                  duration: const Duration(seconds: 20),
                  playing: playing,
                  onTogglePlayback: () => setState(() => playing = !playing),
                  onFullscreen: () => setState(() => fullscreen = !fullscreen),
                  fullscreen: fullscreen,
                  onSeek: (value) async {
                    seeks.add(value);
                    setState(() => position = value);
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('播放（Space）'));
    await tester.pump();
    expect(playing, isTrue);
    expect(find.byTooltip('暂停（Space）'), findsOneWidget);
    await tester.tap(find.byTooltip('快退 5 秒（←）'));
    await tester.pump();
    expect(position, Duration.zero);
    await tester.tap(find.byTooltip('快进 5 秒（→）'));
    await tester.pump();
    expect(position, const Duration(seconds: 5));
    final slider = find.byKey(const ValueKey('studio-video-progress'));
    await tester.drag(slider, const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(position, greaterThan(const Duration(seconds: 5)));
    expect(position, lessThanOrEqualTo(const Duration(seconds: 20)));
    expect(seeks.length, greaterThanOrEqualTo(3));
    await tester.tap(find.byTooltip('全屏播放'));
    await tester.pump();
    expect(fullscreen, isTrue);
    expect(find.byTooltip('退出全屏（Esc）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未知时长和打开失败时不可拖动进度，保持全屏入口', (tester) async {
    for (final enabled in [true, false]) {
      await tester.pumpWidget(
        MaterialApp(
          home: StudioVideoControls(
            position: const Duration(seconds: 8),
            duration: Duration.zero,
            playing: false,
            enabled: enabled,
            onTogglePlayback: () {},
            onSeek: (_) async => fail('无时长不能 seek'),
            onFullscreen: () {},
          ),
        ),
      );
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.value, 0);
      expect(slider.onChanged, isNull);
      expect(find.byTooltip('全屏播放'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('左右键跳转 5 秒、空格播放、F全屏、Esc退出且不抢占文本输入', (tester) async {
    final videoFocus = FocusNode();
    final textFocus = FocusNode();
    addTearDown(videoFocus.dispose);
    addTearDown(textFocus.dispose);
    final skips = <Duration>[];
    var toggles = 0;
    var fullscreens = 0;
    var dismissals = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              StudioVideoHotkeys(
                focusNode: videoFocus,
                onTogglePlayback: () => toggles++,
                onSeekRelative: skips.add,
                onFullscreen: () => fullscreens++,
                onDismiss: () => dismissals++,
                child: const SizedBox(width: 300, height: 180),
              ),
              TextField(focusNode: textFocus),
            ],
          ),
        ),
      ),
    );
    videoFocus.requestFocus();
    await tester.pump();
    for (final key in [
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.keyF,
      LogicalKeyboardKey.escape,
    ]) {
      await tester.sendKeyEvent(key);
    }
    expect(skips, [const Duration(seconds: 5), const Duration(seconds: -5)]);
    expect(toggles, 1);
    expect(fullscreens, 1);
    expect(dismissals, 1);
    textFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(skips.length, 2);
    expect(toggles, 1);
  });

  testWidgets('浅深主题、窄缩略图与大字体控制栏不溢出', (tester) async {
    for (final dark in [false, true]) {
      for (final width in [120.0, 180.0, 280.0, 400.0, 760.0]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? StudioTheme.dark() : StudioTheme.light(),
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
              child: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: width,
                    child: StudioVideoControls(
                      position: const Duration(seconds: 3661),
                      duration: const Duration(hours: 2),
                      playing: true,
                      onTogglePlayback: () {},
                      onSeek: (_) async {},
                      onFullscreen: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull, reason: '$dark $width');
        expect(find.byType(Slider), findsOneWidget);
      }
    }
  });
}
