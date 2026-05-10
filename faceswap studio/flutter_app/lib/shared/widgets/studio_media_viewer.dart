import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

Future<void> showStudioImageViewer(
  BuildContext context, {
  String? filePath,
  Uint8List? imageBytes,
  String? title,
}) async {
  assert(filePath != null || imageBytes != null);
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (context) => _StudioImageViewerDialog(
      filePath: filePath,
      imageBytes: imageBytes,
      title: title,
    ),
  );
}

Future<void> showStudioVideoViewer(
  BuildContext context, {
  required String filePath,
  String? title,
}) async {
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (context) =>
        _StudioVideoViewerDialog(filePath: filePath, title: title),
  );
}

class _DismissViewerIntent extends Intent {
  const _DismissViewerIntent();
}

class _TogglePlaybackIntent extends Intent {
  const _TogglePlaybackIntent();
}

class _ViewerKeyboardScope extends StatelessWidget {
  const _ViewerKeyboardScope({
    required this.onDismiss,
    required this.child,
    this.onTogglePlayback,
  });

  final VoidCallback onDismiss;
  final VoidCallback? onTogglePlayback;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.escape):
            const _DismissViewerIntent(),
        if (onTogglePlayback != null)
          const SingleActivator(LogicalKeyboardKey.space):
              const _TogglePlaybackIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _DismissViewerIntent: CallbackAction<_DismissViewerIntent>(
            onInvoke: (_) {
              onDismiss();
              return null;
            },
          ),
          if (onTogglePlayback != null)
            _TogglePlaybackIntent: CallbackAction<_TogglePlaybackIntent>(
              onInvoke: (_) {
                onTogglePlayback!();
                return null;
              },
            ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}

class _StudioImageViewerDialog extends StatelessWidget {
  const _StudioImageViewerDialog({this.filePath, this.imageBytes, this.title});

  final String? filePath;
  final Uint8List? imageBytes;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: _ViewerKeyboardScope(
        onDismiss: () => Navigator.of(context).pop(),
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                minScale: 0.25,
                maxScale: 8.0,
                child: filePath != null
                    ? Image.file(File(filePath!), fit: BoxFit.contain)
                    : Image.memory(imageBytes!, fit: BoxFit.contain),
              ),
            ),
            Positioned(
              top: 24,
              left: 24,
              child: _ViewerHintLabel(
                label: title == null ? '图片全屏预览 · Esc 退出' : '$title · Esc 退出',
              ),
            ),
            Positioned(
              top: 24,
              right: 24,
              child: IconButton.filledTonal(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StudioVideoViewerDialog extends StatefulWidget {
  const _StudioVideoViewerDialog({required this.filePath, this.title});

  final String filePath;
  final String? title;

  @override
  State<_StudioVideoViewerDialog> createState() =>
      _StudioVideoViewerDialogState();
}

class _StudioVideoViewerDialogState extends State<_StudioVideoViewerDialog> {
  late final Player _player;
  late final VideoController _controller;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _player.open(Media(widget.filePath));
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    if (_player.state.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: _ViewerKeyboardScope(
        onDismiss: () => Navigator.of(context).pop(),
        onTogglePlayback: () {
          _togglePlayback();
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: Video(
                  controller: _controller,
                  fit: BoxFit.contain,
                  controls: AdaptiveVideoControls,
                ),
              ),
            ),
            Positioned(
              top: 24,
              left: 24,
              child: _ViewerHintLabel(
                label: widget.title == null
                    ? '视频全屏播放 · Space 播放/暂停 · Esc 退出'
                    : '${widget.title} · Space 播放/暂停 · Esc 退出',
              ),
            ),
            Positioned(
              top: 24,
              right: 24,
              child: IconButton.filledTonal(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ViewerHintLabel extends StatelessWidget {
  const _ViewerHintLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(color: Colors.white),
        ),
      ),
    );
  }
}
