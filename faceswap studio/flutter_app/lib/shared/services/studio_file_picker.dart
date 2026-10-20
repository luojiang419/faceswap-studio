import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('faceswap_studio/file_dialog');
bool _dialogOpen = false;

/// Windows Shell 运行在独立 STA 线程，避免阻塞 Flutter 主窗口。
/// 同时仅允许一个文件窗口；取消、页面已销毁时不更新素材。
Future<List<XFile>> pickStudioFiles(
  BuildContext context, {
  required List<XTypeGroup> acceptedTypeGroups,
  bool multiple = true,
}) async {
  if (_dialogOpen) return [];
  _dialogOpen = true;
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
    _dialogOpen = false;
  }
}
