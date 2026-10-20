import 'dart:async';

import 'package:faceswap_studio/shared/services/studio_file_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('faceswap_studio/file_dialog');
  const filters = [
    XTypeGroup(label: '人脸图片', extensions: ['jpg', 'png']),
  ];
  late BuildContext context;
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void windowsTest(String name, WidgetTesterCallback callback) {
    testWidgets(
      name,
      callback,
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (value) {
              context = value;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
  }

  windowsTest('多选保留中文路径和过滤条件，单选正确传入', (tester) async {
    await mount(tester);
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return [r'D:\人脸素材\甲.jpg', r'D:\人脸素材\乙.png'];
    });
    final files = await pickStudioFiles(context, acceptedTypeGroups: filters);
    expect(files.map((file) => file.path), [
      r'D:\人脸素材\甲.jpg',
      r'D:\人脸素材\乙.png',
    ]);
    expect(calls.single.method, 'openFiles');
    expect(calls.single.arguments, {
      'multiple': true,
      'filters': [
        {
          'label': '人脸图片',
          'extensions': ['jpg', 'png'],
        },
      ],
    });
    await pickStudioFiles(
      context,
      acceptedTypeGroups: filters,
      multiple: false,
    );
    expect(calls.last.arguments['multiple'], isFalse);
  });

  windowsTest('等待弹窗时阻止重复打开，取消后允许重试', (tester) async {
    await mount(tester);
    var calls = 0;
    final pending = Completer<List<String>>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      _,
    ) {
      calls++;
      return calls == 1 ? pending.future : Future.value(<String>[]);
    });
    final first = pickStudioFiles(context, acceptedTypeGroups: filters);
    expect(
      await pickStudioFiles(context, acceptedTypeGroups: filters),
      isEmpty,
    );
    expect(calls, 1);
    pending.complete([]);
    expect(await first, isEmpty);
    expect(
      await pickStudioFiles(context, acceptedTypeGroups: filters),
      isEmpty,
    );
    expect(calls, 2);
  });

  windowsTest('人脸窗口回调尚未完成时点击视频，保留请求且不同时打开窗口', (tester) async {
    await mount(tester);
    final source = Completer<List<String>>();
    final calls = <bool>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) {
      final multiple = (call.arguments as Map)['multiple'] as bool;
      calls.add(multiple);
      return multiple ? source.future : Future.value([r'D:\素材\video.mp4']);
    });
    final faces = pickStudioFiles(context, acceptedTypeGroups: filters);
    var videoFinished = false;
    final video =
        pickStudioFiles(
          context,
          acceptedTypeGroups: const [
            XTypeGroup(label: '视频', extensions: ['mp4']),
          ],
          multiple: false,
        ).then((value) {
          videoFinished = true;
          return value;
        });
    await tester.pump();
    expect(calls, [true]);
    expect(videoFinished, isFalse, reason: '不同素材入口不能静默当作取消');
    source.complete([r'D:\素材\face.jpg']);
    expect((await faces).single.path, r'D:\素材\face.jpg');
    expect((await video).single.path, r'D:\素材\video.mp4');
    expect(calls, [true, false]);
  });

  windowsTest('排队选择期间页面销毁，不再打开视频窗口', (tester) async {
    await mount(tester);
    final source = Completer<List<String>>();
    var calls = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      _,
    ) {
      calls++;
      return source.future;
    });
    final faces = pickStudioFiles(context, acceptedTypeGroups: filters);
    final video = pickStudioFiles(
      context,
      acceptedTypeGroups: filters,
      multiple: false,
    );
    await tester.pumpWidget(const SizedBox());
    source.complete([]);
    expect(await faces, isEmpty);
    expect(await video, isEmpty);
    expect(calls, 1);
  });

  windowsTest('原生错误显示提示并释放弹窗锁', (tester) async {
    await mount(tester);
    var calls = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      _,
    ) async {
      if (++calls == 1) throw PlatformException(code: 'file_dialog_failed');
      return <String>[];
    });
    expect(
      await pickStudioFiles(context, acceptedTypeGroups: filters),
      isEmpty,
    );
    await tester.pump();
    expect(find.textContaining('打开文件窗口失败'), findsOneWidget);
    expect(
      await pickStudioFiles(context, acceptedTypeGroups: filters),
      isEmpty,
    );
    expect(calls, 2);
  });

  windowsTest('等待期间页面销毁后丢弃选择，避免更新已销毁页面', (tester) async {
    await mount(tester);
    final pending = Completer<List<String>>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) => pending.future,
    );
    final result = pickStudioFiles(context, acceptedTypeGroups: filters);
    await tester.pumpWidget(const SizedBox());
    pending.complete([r'D:\人脸素材\甲.jpg']);
    expect(await result, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
