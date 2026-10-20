import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('faceswap_studio/file_dialog');
Future<void>? _dialogClosed;
bool? _dialogMultiple;

/// Windows Shell 运行在独立 STA 线程，避免阻塞 Flutter 主窗口。
/// 同时仅允许一个文件窗口；另一素材入口等待交接，不丢弃点击。
Future<List<XFile>> pickStudioFiles(
  BuildContext context, {
  required List<XTypeGroup> acceptedTypeGroups,
  bool multiple = true,
}) async {
  while (_dialogClosed != null) {
    // 同类入口防重入；人脸多选与视频单选分别保留一次选择机会。
    if (_dialogMultiple == multiple) return [];
    await _dialogClosed;
    if (!context.mounted) return [];
  }
  final closed = Completer<void>();
  _dialogClosed = closed.future;
  _dialogMultiple = multiple;
  try {
    List<XFile> files;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      final paths = await _channel.invokeListMethod<String>('openFiles', {
        'multiple': multiple,
        'filters': [
          for (final group in acceptedTypeGroups)
            {'label': group.label, 'extensions': group.extensions ?? []},
        ],
      });
      files = [for (final path in paths ?? <String>[]) XFile(path)];
    } else if (multiple) {
      files = await openFiles(acceptedTypeGroups: acceptedTypeGroups);
    } else {
      final file = await openFile(acceptedTypeGroups: acceptedTypeGroups);
      files = [?file];
    }
    return context.mounted ? files : [];
  } on PlatformException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('打开文件窗口失败，请重试。${error.code}')));
    }
    return [];
  } finally {
    _dialogClosed = null;
    _dialogMultiple = null;
    closed.complete();
  }
}
