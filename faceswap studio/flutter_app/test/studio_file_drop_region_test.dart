import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:faceswap_studio/app/theme/studio_theme.dart';
import 'package:faceswap_studio/shared/widgets/studio_file_drop_region.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('studio-drop-'));
  tearDown(() => temp.deleteSync(recursive: true));

  testWidgets('格式、目录、多视频及重复拖入有保护，取消与禁用恢复', (tester) async {
    var imports = 0;
    final gate = Completer<void>();
    Future<void> show({bool enabled = true, bool visible = true}) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TickerMode(
                enabled: visible,
                child: SizedBox(
                  width: 300,
                  height: 300,
                  child: StudioFileDropRegion(
                    video: true,
                    extensions: const {'mp4'},
                    onFiles: enabled
                        ? (_) async {
                            imports++;
                            await gate.future;
                          }
                        : null,
                    child: const ColoredBox(color: Colors.black),
                  ),
                ),
              ),
            ),
          ),
        );
    await show();
    DropTarget drop() => tester.widget<DropTarget>(find.byType(DropTarget));
    final event = DropEventDetails(
      localPosition: Offset.zero,
      globalPosition: Offset.zero,
    );
    DropDoneDetails details(List<DropItem> files) => DropDoneDetails(
      files: files,
      localPosition: Offset.zero,
      globalPosition: Offset.zero,
    );
    double opacity() =>
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;
    drop().onDragEntered!(event);
    await tester.pump(const Duration(milliseconds: 250));
    expect(opacity(), 1);
    drop().onDragExited!(event);
    await tester.pump();
    expect(opacity(), 0);
    drop().onDragDone!(details([DropItemFile('${temp.path}/bad.exe')]));
    await tester.pump();
    expect(find.textContaining('请拖入支持的视频文件'), findsOneWidget);
    final file = File('${temp.path}/视频.MP4')..writeAsBytesSync([0]);
    drop().onDragDone!(
      details([DropItemFile(file.path), DropItemFile(file.path)]),
    );
    await tester.pump();
    expect(find.textContaining('每次只能拖入一个'), findsOneWidget);
    final folder = Directory('${temp.path}/folder.mp4')..createSync();
    await tester.runAsync(() async {
      drop().onDragDone!(details([DropItemFile(folder.path)]));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(find.textContaining('请拖入可读取的本地文件'), findsOneWidget);
    expect(imports, 0);
    await tester.runAsync(() async {
      drop().onDragDone!(details([DropItemFile(file.path)]));
      drop().onDragDone!(details([DropItemFile(file.path)]));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    expect(imports, 1);
    gate.complete();
    await tester.pump();
    drop().onDragEntered!(event);
    await tester.pump();
    await show(enabled: false);
    expect(drop().enable, isFalse);
    expect(opacity(), 0);
    await show(visible: false);
    expect(drop().enable, isFalse);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('浅深主题窄格、大字和减少动画适配，遮挡页面不接受拖入', (tester) async {
    for (final dark in [true, false]) {
      for (final video in [true, false]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? StudioTheme.dark() : StudioTheme.light(),
            home: Scaffold(
              body: Builder(
                builder: (context) => Column(
                  children: [
                    TextButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => const AlertDialog(content: Text('遮挡')),
                      ),
                      child: const Text('打开弹窗'),
                    ),
                    MediaQuery(
                      data: const MediaQueryData(
                        disableAnimations: true,
                        textScaler: TextScaler.linear(1.8),
                      ),
                      child: SizedBox(
                        width: 180,
                        height: 160,
                        child: StudioFileDropRegion(
                          video: video,
                          extensions: const {'png'},
                          onFiles: (_) async {},
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        final drop = tester.widget<DropTarget>(find.byType(DropTarget));
        drop.onDragEntered!(
          DropEventDetails(
            localPosition: Offset.zero,
            globalPosition: Offset.zero,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('打开弹窗'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<DropTarget>(find.byType(DropTarget)).enable,
          isFalse,
        );
        await tester.pumpWidget(const SizedBox());
      }
    }
  });
}
