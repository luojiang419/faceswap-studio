import 'package:flutter/foundation.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 应用全屏与视频全屏共用原生窗口；视频关闭时保留应用全屏。
class StudioFullscreen {
  static final active = ValueNotifier(false);
  static bool _changing = false;
  static Future<void> toggle() async {
    if (_changing) return;
    _changing = true;
    try {
      if (active.value) {
        await defaultExitNativeFullscreen();
      } else {
        await defaultEnterNativeFullscreen();
      }
      active.value = !active.value;
    } finally {
      _changing = false;
    }
  }
}
