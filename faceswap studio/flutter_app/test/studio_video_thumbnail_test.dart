import 'dart:io';
import 'dart:ui' as ui;

import 'package:faceswap_studio/app/theme/studio_theme.dart';
import 'package:faceswap_studio/shared/widgets/studio_media_viewer.dart';
import 'package:faceswap_studio/shared/widgets/studio_video_controls.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await (FontLoader('MaterialIcons')..addFont(
          Future.value(
            ByteData.sublistView(
              File(
                'D:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytesSync(),
            ),
          ),
        ))
        .load();
  });
  testWidgets('居中图标移入显示移出隐藏，单击原位播放暂停，双击只打开全屏', (tester) async {
    var playing = false;
    var toggles = 0;
    var fullscreens = 0;
    final capture = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: StudioTheme.dark(),
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: capture,
              child: SizedBox(
                width: 120,
                height: 92,
                child: StatefulBuilder(
                  builder: (context, update) => StudioVideoThumbnailSurface(
                    playing: playing,
                    onTogglePlayback: () => update(() {
                      toggles++;
                      playing = !playing;
                    }),
                    onFullscreen: () => fullscreens++,
                    child: const ColoredBox(color: Color(0xFF7199B0)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final surface = find.byType(StudioVideoThumbnailSurface);
    final button = find.byKey(const ValueKey('thumbnail-play-button'));
    expect(tester.widget<AnimatedOpacity>(button).opacity, 0);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(surface));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(button).opacity, 1);
    expect(
      tester.getCenter(find.byIcon(Icons.play_arrow_rounded)),
      tester.getCenter(surface),
    );
    expect(find.byType(Slider), findsNothing);
    await tester.runAsync(() async {
      final boundary =
          capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/queue-thumbnail-hover.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.tap(surface);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(toggles, 1);
    expect(playing, isTrue);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(button).opacity, 0);
    expect(playing, isTrue, reason: '移出不暂停原位播放');
    await tester.tap(surface);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(surface);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(fullscreens, 1);
    expect(toggles, 1, reason: '双击不触发两次播放切换');
    await tester.tap(surface);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(toggles, 2);
    expect(playing, isFalse);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('队列小格初始保留缩略图且无控制条，换片和销毁不提前创建解码器', (tester) async {
    for (final dark in [true, false]) {
      for (final path in ['original.mp4', 'output.mp4']) {
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? StudioTheme.dark() : StudioTheme.light(),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 120,
                  height: 92,
                  child: StudioInlineVideoPlayer(
                    filePath: path,
                    thumbnailControls: true,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.byType(StudioVideoThumbnailSurface), findsOneWidget);
        expect(
          find.byKey(const ValueKey('inline-video-loading')),
          findsNothing,
        );
        expect(find.byType(StudioVideoControls), findsNothing);
        expect(find.text('播放失败'), findsNothing);
        expect(tester.takeException(), isNull);
      }
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
