import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:faceswap_studio/shared/widgets/studio_hover_focus.dart';
import 'package:faceswap_studio/app/theme/studio_theme.dart';
import 'package:faceswap_studio/shared/widgets/studio_video_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Uint8List thumbnail;
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await (FontLoader('Microsoft YaHei UI')..addFont(
          Future.value(
            ByteData.sublistView(
              File('C:/Windows/Fonts/msyh.ttc').readAsBytesSync(),
            ),
          ),
        ))
        .load();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 320, 180),
      Paint()..color = const Color(0xFF7199B0),
    );
    canvas.drawCircle(
      const Offset(250, 45),
      22,
      Paint()..color = const Color(0xFFFFCA8F),
    );
    canvas.drawPath(
      Path()
        ..moveTo(0, 180)
        ..lineTo(100, 55)
        ..lineTo(210, 180)
        ..close(),
      Paint()..color = const Color(0xFF3B635F),
    );
    final picture = recorder.endRecording();
    final rendered = await picture.toImage(320, 180);
    thumbnail = (await rendered.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    rendered.dispose();
    picture.dispose();
  });
  test('播放时间映射到原视频帧且首尾不越界', () {
    final preview = StudioVideoFramePreview(
      videoKey: 'target.mp4',
      frameTotal: 600,
      loadFrame: (_) async => Uint8List(0),
    );
    expect(preview.frameAt(0, const Duration(seconds: 20)), 0);
    expect(preview.frameAt(10000, const Duration(seconds: 20)), 300);
    expect(preview.frameAt(20000, const Duration(seconds: 20)), 599);
    expect(preview.frameAt(-100, const Duration(seconds: 20)), 0);
    expect(preview.frameAt(30000, const Duration(seconds: 20)), 599);
    expect(preview.frameAt(10000, Duration.zero), 0);
  });

  testWidgets('待换脸播放条悬停取帧、松开仅跳转一次、换片清除旧浮层', (tester) async {
    final image = thumbnail;
    final requests = <int>[];
    final seeks = <Duration>[];
    Completer<Uint8List>? gate;
    var video = 'target.mp4';
    var enabled = true;
    late StateSetter update;
    final captureKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: StudioTheme.dark(),
          home: StudioHoverFocus(
            child: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return Center(
                    child: SizedBox(
                      width: 300,
                      child: StudioVideoControls(
                        position: const Duration(seconds: 4),
                        duration: const Duration(seconds: 20),
                        playing: false,
                        enabled: enabled,
                        onTogglePlayback: () {},
                        onSeek: (value) async => seeks.add(value),
                        framePreview: StudioVideoFramePreview(
                          videoKey: video,
                          frameTotal: 600,
                          loadFrame: (frame) {
                            requests.add(frame);
                            return gate?.future ?? Future.value(image);
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    final slider = find.byKey(const ValueKey('studio-video-progress'));
    final popup = find.byKey(const ValueKey('frame-scrub-thumbnail'));
    expect(tester.getSize(slider).height, 20);
    final rect = tester.getRect(slider);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(rect.center);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump(const Duration(milliseconds: 250));
    expect(requests.last, 300);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.runAsync(() async {
      final boundary =
          captureKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final rendered = await boundary.toImage();
      final bytes = await rendered.toByteData(format: ui.ImageByteFormat.png);
      final output = File('build/target-video-scrub-preview.png');
      output.parent.createSync(recursive: true);
      output.writeAsBytesSync(bytes!.buffer.asUint8List());
      rendered.dispose();
    });
    expect(
      find.descendant(of: popup, matching: find.text('00:10')),
      findsOneWidget,
    );
    expect(seeks, isEmpty);
    await mouse.moveTo(Offset(rect.right - 1, rect.center.dy));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump();
    expect(requests.last, 599);
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    final drag = await tester.startGesture(rect.center);
    await drag.moveTo(Offset(rect.right - 15, rect.center.dy));
    await tester.pump(const Duration(milliseconds: 80));
    expect(seeks, isEmpty);
    await drag.up();
    await tester.pump();
    expect(seeks, hasLength(1));
    expect(seeks.single.inMilliseconds, greaterThan(18000));
    expect(popup, findsNothing);
    gate = Completer<Uint8List>();
    await mouse.moveTo(Offset(rect.left + 30, rect.center.dy));
    await tester.pump(const Duration(milliseconds: 80));
    update(() => video = 'replacement.mp4');
    await tester.pump();
    gate.complete(image);
    await tester.pump();
    expect(popup, findsNothing);
    gate = null;
    await mouse.moveTo(rect.center);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump();
    expect(popup, findsOneWidget);
    update(() => enabled = false);
    await tester.pump();
    await tester.pump();
    expect(popup, findsNothing);
    expect(tester.widget<Slider>(slider).onChanged, isNull);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

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
