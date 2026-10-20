import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

/// 外部文件拖拽覆盖整个素材卡片；导入仍由工作台原有流程负责。
class StudioFileDropRegion extends StatefulWidget {
  const StudioFileDropRegion({
    super.key,
    required this.video,
    required this.extensions,
    required this.onFiles,
    required this.child,
  });

  final bool video;
  final Set<String> extensions;
  final Future<void> Function(List<XFile>)? onFiles;
  final Widget child;

  @override
  State<StudioFileDropRegion> createState() => _StudioFileDropRegionState();
}

class _StudioFileDropRegionState extends State<StudioFileDropRegion>
    with SingleTickerProviderStateMixin {
  late final AnimationController _float = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  bool _dragging = false;
  bool _accepting = false;
  bool _enabled = false;

  @override
  void dispose() {
    _float.dispose();
    super.dispose();
  }

  void _setDragging(bool value) {
    if (!mounted || _dragging == value) return;
    setState(() => _dragging = value);
    _syncAnimation();
  }

  void _syncAnimation() {
    if (_dragging && _enabled && !MediaQuery.disableAnimationsOf(context)) {
      if (!_float.isAnimating) _float.repeat(reverse: true);
    } else {
      _float.stop();
      _float.value = 0;
    }
  }

  void _reject(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _accept(DropDoneDetails details) async {
    _setDragging(false);
    if (!_enabled || _accepting || details.files.isEmpty) return;
    if (details.files.any((file) {
      final name = file.path.split(RegExp(r'[/\\]')).last;
      final dot = name.lastIndexOf('.');
      return file is DropItemDirectory ||
          dot < 0 ||
          !widget.extensions.contains(name.substring(dot + 1).toLowerCase());
    })) {
      _reject(
        widget.video ? '请拖入支持的视频文件，暂不支持文件夹。' : '请拖入支持的人脸图片或音频文件，暂不支持文件夹。',
      );
      return;
    }
    if (widget.video && details.files.length != 1) {
      _reject('每次只能拖入一个待换脸视频，请选择一个文件。');
      return;
    }
    _accepting = true;
    try {
      for (final file in details.files) {
        if (!await FileSystemEntity.isFile(file.path)) {
          if (mounted) _reject('请拖入可读取的本地文件，暂不支持文件夹。');
          return;
        }
      }
      if (!mounted ||
          !_enabled ||
          widget.onFiles == null ||
          !(ModalRoute.of(context)?.isCurrent ?? true)) {
        return;
      }
      await widget.onFiles!(details.files);
    } on FileSystemException {
      if (mounted) _reject('文件无法读取，请检查文件是否存在或被占用。');
    } finally {
      _accepting = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    _enabled =
        widget.onFiles != null &&
        TickerMode.of(context) &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    if (!_enabled) _dragging = false;
    _syncAnimation();
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);
    const curve = Cubic(0.22, 1, 0.36, 1);

    return DropTarget(
      enable: _enabled,
      onDragEntered: (_) {
        if (_enabled) _setDragging(true);
      },
      onDragExited: (_) => _setDragging(false),
      onDragDone: _accept,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _dragging ? 1 : 0,
                duration: duration,
                curve: curve,
                child: AnimatedScale(
                  scale: _dragging ? 1 : 0.98,
                  duration: duration,
                  curve: curve,
                  child: DecoratedBox(
                    key: ValueKey(
                      widget.video
                          ? 'target-drop-overlay'
                          : 'source-drop-overlay',
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withValues(alpha: 0.96),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: primary, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: primary.withValues(alpha: 0.16),
                          blurRadius: 24,
                        ),
                      ],
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color.alphaBlend(
                            primary.withValues(alpha: 0.13),
                            theme.colorScheme.surface,
                          ),
                          theme.colorScheme.surface.withValues(alpha: 0.96),
                        ],
                      ),
                    ),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final small = constraints.maxHeight < 230;
                        return Center(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AnimatedBuilder(
                                  animation: _float,
                                  builder: (context, child) =>
                                      Transform.translate(
                                        offset: Offset(
                                          0,
                                          -6 *
                                              math.sin(
                                                _float.value * math.pi / 2,
                                              ),
                                        ),
                                        child: child,
                                      ),
                                  child: Container(
                                    width: small ? 58 : 86,
                                    height: small ? 58 : 86,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: primary.withValues(alpha: 0.12),
                                      border: Border.all(
                                        color: primary.withValues(alpha: 0.3),
                                      ),
                                    ),
                                    child: Icon(
                                      widget.video
                                          ? Icons.video_library_outlined
                                          : Icons.add_photo_alternate_outlined,
                                      color: primary,
                                      size: small ? 30 : 42,
                                    ),
                                  ),
                                ),
                                SizedBox(height: small ? 12 : 22),
                                Text(
                                  widget.video ? '松开以导入视频' : '松开以添加人脸',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    color: primary,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  widget.video
                                      ? '一次一个视频 · 自动读取素材'
                                      : '支持多张图片 · 自动识别人脸',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
