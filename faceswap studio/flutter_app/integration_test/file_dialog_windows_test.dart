import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:faceswap_studio/shared/services/studio_file_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// 独立 isolate 只关闭当前测试 PID 的系统文件窗口，避免原生同步
// Show() 阻塞主 isolate 时连测试超时/取消计时器也无法执行。
Future<void> _cancelTestDialog(SendPort results) async {
  final user = DynamicLibrary.open('user32.dll');
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
  final post = user
      .lookupFunction<
        Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
        int Function(int, int, int, int)
      >('PostMessageW');
  final visible = user
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'IsWindowVisible',
      );
  final className = '#32770'.toNativeUtf16();
  final processId = calloc<Uint32>();
  try {
    for (var attempt = 0; attempt < 150; attempt++) {
      var after = 0;
      while (true) {
        final window = findWindow(0, after, className, nullptr);
        if (window == 0) break;
        after = window;
        windowPid(window, processId);
        if (processId.value == pid && visible(window) != 0) {
          await Future<void>.delayed(const Duration(milliseconds: 600));
          // 上一次弹窗的窗口销毁可能晚于 Future 完成，忽略已消失的旧窗口。
          windowPid(window, processId);
          if (processId.value != pid || visible(window) == 0) continue;
          results.send({
            'dialogVisible': true,
            'cancelPosted': post(window, 0x10, 0, 0) != 0,
          });
          return;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    results.send({'dialogVisible': false});
  } finally {
    calloc.free(className);
    calloc.free(processId);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('原生人脸多选与视频单选窗口打开、取消和重开', (tester) async {
    late BuildContext pickerContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              pickerContext = context;
              return const Text('文件选择集成验证');
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final reports = <Object?>[];
    for (final multiple in [true, false, true]) {
      final receiver = ReceivePort();
      final monitor = await Isolate.spawn(_cancelTestDialog, receiver.sendPort);
      try {
        final result = await tester.runAsync(() async {
          final report = receiver.first;
          var heartbeats = 0;
          final heartbeat = Timer.periodic(
            const Duration(milliseconds: 100),
            (_) => heartbeats++,
          );
          late List<XFile> files;
          try {
            files = await pickStudioFiles(
              pickerContext,
              multiple: multiple,
              acceptedTypeGroups: [
                XTypeGroup(
                  label: multiple ? '人脸图片' : '视频',
                  extensions: multiple ? ['jpg', 'png'] : ['mp4'],
                ),
              ],
            );
          } finally {
            heartbeat.cancel();
          }
          return <String, Object?>{
            ...Map<String, Object?>.from(await report as Map),
            'heartbeats': heartbeats,
            'selectedCount': files.length,
          };
        });
        expect(result, isNotNull);
        expect(result!['dialogVisible'], isTrue, reason: '$result');
        expect(result['cancelPosted'], isTrue, reason: '$result');
        expect(result['selectedCount'], 0);
        expect(
          result['heartbeats'],
          greaterThanOrEqualTo(3),
          reason: '弹窗期间主线程应继续响应：$result',
        );
        reports.add(result);
        await tester.pumpAndSettle();
        expect(find.text('文件选择集成验证'), findsOneWidget);
      } finally {
        monitor.kill(priority: Isolate.immediate);
        receiver.close();
      }
    }
    binding.reportData = {'nativeDialogs': reports};
  }, timeout: const Timeout(Duration(seconds: 60)));
}
