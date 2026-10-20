import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:faceswap_studio/app/theme/studio_theme.dart';
import 'package:faceswap_studio/shared/widgets/studio_frame_scrubber.dart';
import 'package:faceswap_studio/shared/widgets/studio_hover_focus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Uint8List image;
  final captureKey = GlobalKey();
  late StateSetter update;
  late String video;
  late bool enabled;
  late bool visible;
  late double value;
  late int changes;
  late List<double> commits;
  late List<int> requests;
  late Future<Uint8List> Function(int) load;
  final scrubber = find.byType(StudioFrameScrubber);
  final popup = find.byKey(const ValueKey('frame-scrub-thumbnail'));
  final blur = find.byKey(const ValueKey('studio-page-blur'));

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
    canvas.drawPath(
      Path()
        ..moveTo(135, 180)
        ..lineTo(235, 85)
        ..lineTo(320, 180)
        ..close(),
      Paint()..color = const Color(0xFF90AF9C),
    );
    final picture = recorder.endRecording();
    final rendered = await picture.toImage(320, 180);
    image = (await rendered.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    rendered.dispose();
    picture.dispose();
  });

  setUp(() {
    video = 'first.mp4';
    enabled = visible = true;
    value = 40;
    changes = 0;
    commits = [];
    requests = [];
    load = (_) async => image;
  });

  Future<void> mount(
    WidgetTester tester, {
    bool dark = true,
    Size size = const Size(800, 600),
    bool reduced = false,
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: dark ? StudioTheme.dark() : StudioTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: reduced,
              textScaler: TextScaler.linear(scale),
            ),
            child: child!,
          ),
          home: StudioHoverFocus(
            child: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return TickerMode(
                    enabled: visible,
                    child: Center(
                      child: SizedBox(
                        width: 300,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('原生预览'),
                            Container(
                              height: 80,
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainer,
                              child: const Center(child: Text('待换脸视频')),
                            ),
                            const Text('预览帧'),
                            StudioFrameScrubber(
                              videoKey: video,
                              value: value,
                              max: 100,
                              onChanged: enabled
                                  ? (next) {
                                      changes++;
                                      setState(() => value = next);
                                    }
                                  : null,
                              onChangeEnd: enabled ? commits.add : null,
                              loadFrame: (frame) {
                                requests.add(frame);
                                return load(frame);
                              },
                            ),
                            const Text('参考脸'),
                          ],
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
    await tester.pumpAndSettle();
  }

  Future<void> settleImage(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 90));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary =
        captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final rendered = await boundary.toImage(pixelRatio: 2);
      final bytes = await rendered.toByteData(format: ui.ImageByteFormat.png);
      final folder = Directory('../../build/frame-scrub-preview')
        ..createSync(recursive: true);
      File(
        '${folder.path}/$name.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
      rendered.dispose();
    });
  }

  testWidgets('悬停读取对应帧，浮层清晰且整页2px模糊，离开后恢复', (tester) async {
    await mount(tester);
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(scrubber));
    await settleImage(tester);
    expect(requests, [50]);
    expect(popup, findsOneWidget);
    expect(find.text('帧 50 / 100'), findsOneWidget);
    expect(
      find.descendant(of: popup, matching: find.byType(Image)),
      findsOneWidget,
    );
    expect(
      tester.widget<ImageFiltered>(blur).imageFilter.toString(),
      ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2).toString(),
    );
    expect(
      find.descendant(of: blur, matching: popup),
      findsNothing,
      reason: '缩略图在整页模糊层之外',
    );
    expect(changes, 0);
    expect(commits, isEmpty, reason: '悬停不生成换脸预览');
    await capture(tester, 'dark-center');
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(popup, findsNothing);
    expect(tester.widget<ImageFiltered>(blur).enabled, isFalse);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('快速搓擦只串行取最新帧，旧图不覆盖新帧，返回已访问帧命中缓存', (tester) async {
    final first = Completer<Uint8List>();
    final latest = Completer<Uint8List>();
    load = (frame) => frame == 50 ? first.future : latest.future;
    await mount(tester);
    final rect = tester.getRect(scrubber);
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    Future<void> hover(int frame) async {
      await mouse.moveTo(
        Offset(
          rect.left + 24 + (rect.width - 48) * frame / 100,
          rect.center.dy,
        ),
      );
      await tester.pump(const Duration(milliseconds: 90));
    }

    await hover(50);
    for (final frame in [10, 30, 80]) {
      await hover(frame);
    }
    expect(requests, [50]);
    first.complete(image);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(requests, [50, 80]);
    expect(
      find.descendant(of: popup, matching: find.byType(Image)),
      findsOneWidget,
    );
    expect(
      find.text('帧 50 / 100'),
      findsOneWidget,
      reason: '保留最近画面但不能把50帧图标成80帧',
    );
    latest.complete(image);
    await settleImage(tester);
    expect(find.text('帧 80 / 100'), findsOneWidget);
    await hover(50);
    await settleImage(tester);
    expect(requests, [50, 80], reason: '36帧有限内存缓存复用');
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('持续移动也会读取缩略图，不必停住鼠标才开始取帧', (tester) async {
    await mount(tester);
    final rect = tester.getRect(scrubber);
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    for (final frame in [10, 20, 30, 40, 50, 60, 70, 80]) {
      await mouse.moveTo(
        Offset(
          rect.left + 24 + (rect.width - 48) * frame / 100,
          rect.center.dy,
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(requests.length, greaterThanOrEqualTo(2));
    expect(requests.length, lessThanOrEqualTo(3), reason: '按间隔合并中间位置');
    expect(changes, 0);
    expect(
      find.descendant(of: popup, matching: find.byType(Image)),
      findsOneWidget,
      reason: '持续移动也保留已读取画面，不反复切回加载占位',
    );
    expect(commits, isEmpty);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动期间浮层更新，仅松开时提交一次，禁用与隐藏时清理', (tester) async {
    await mount(tester);
    final gesture = await tester.startGesture(tester.getCenter(scrubber));
    await tester.pump(const Duration(milliseconds: 90));
    await gesture.moveBy(const Offset(60, 0));
    await settleImage(tester);
    expect(popup, findsOneWidget);
    expect(commits, isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(commits, hasLength(1));
    expect(value, greaterThan(50));
    expect(popup, findsNothing);
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(scrubber));
    await settleImage(tester);
    update(() => enabled = false);
    await tester.pumpAndSettle();
    expect(popup, findsNothing);
    expect(tester.widget<ImageFiltered>(blur).enabled, isFalse);
    update(() => enabled = true);
    await tester.pump();
    await mouse.moveTo(tester.getCenter(scrubber) + const Offset(10, 0));
    await settleImage(tester);
    update(() => visible = false);
    await tester.pumpAndSettle();
    expect(popup, findsNothing);
    expect(tester.widget<ImageFiltered>(blur).enabled, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('换片或销毁后忽略旧响应，取帧失败可离开后重试', (tester) async {
    final pending = Completer<Uint8List>();
    load = (_) => pending.future;
    await mount(tester);
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(scrubber));
    await tester.pump(const Duration(milliseconds: 90));
    update(() => video = 'second.mp4');
    await tester.pumpAndSettle();
    expect(popup, findsNothing);
    pending.complete(image);
    await tester.pump();
    expect(popup, findsNothing);
    load = (_) async => throw StateError('测试读取失败');
    await mouse.moveTo(tester.getCenter(scrubber) + const Offset(10, 0));
    await tester.pump(const Duration(milliseconds: 90));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('此帧暂不可用'), findsOneWidget);
    await mouse.moveTo(Offset.zero);
    load = (_) async => image;
    await mouse.moveTo(tester.getCenter(scrubber));
    await settleImage(tester);
    expect(
      find.descendant(of: popup, matching: find.byType(Image)),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(popup, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗口两端不越界，浅深主题与大字号、减少动画均适配', (tester) async {
    for (final dark in [false, true]) {
      await mount(
        tester,
        dark: dark,
        size: const Size(320, 300),
        reduced: true,
        scale: 1.8,
      );
      final rect = tester.getRect(scrubber);
      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      for (final x in [rect.left + 24, rect.right - 24]) {
        await mouse.moveTo(Offset(x, rect.center.dy));
        await settleImage(tester);
        final bounds = tester.getRect(popup);
        expect(bounds.left, greaterThanOrEqualTo(8));
        expect(bounds.right, lessThanOrEqualTo(312));
        expect(bounds.top, greaterThanOrEqualTo(8));
        expect(bounds.bottom, lessThanOrEqualTo(292));
        expect(tester.widget<ImageFiltered>(blur).enabled, isTrue);
        expect(tester.takeException(), isNull);
      }
      await capture(tester, dark ? 'dark-edge' : 'light-edge');
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }
  });
}
