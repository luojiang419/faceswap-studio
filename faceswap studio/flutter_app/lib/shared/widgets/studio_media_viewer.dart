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

class StudioInlineVideoPlayer extends StatefulWidget {
  const StudioInlineVideoPlayer({
    super.key,
    required this.filePath,
    this.thumbnailPath,
    this.fit = BoxFit.cover,
    this.onOpenFullscreen,
    this.showVideoBadge = true,
    this.showFullscreenButton = true,
  });

  final String filePath;
  final String? thumbnailPath;
  final BoxFit fit;
  final VoidCallback? onOpenFullscreen;
  final bool showVideoBadge;
  final bool showFullscreenButton;

  @override
  State<StudioInlineVideoPlayer> createState() =>
      _StudioInlineVideoPlayerState();
}

class _StudioInlineVideoPlayerState extends State<StudioInlineVideoPlayer> {
  Player? _player;
  VideoController? _controller;
  bool _opening = false;
  bool _failed = false;
  bool _playWhenReady = false;
  bool _hoveringControls = false;
  int _openGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _preparePlayer(playAfterOpen: false);
      }
    });
  }

  @override
  void didUpdateWidget(covariant StudioInlineVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath) {
      _openGeneration++;
      _disposePlayer();
      _opening = false;
      _failed = false;
      _playWhenReady = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _preparePlayer(playAfterOpen: false);
        }
      });
    }
  }

  @override
  void dispose() {
    _disposePlayer();
    super.dispose();
  }

  void _disposePlayer() {
    final player = _player;
    _player = null;
    _controller = null;
    player?.dispose();
  }

  Future<Player?> _preparePlayer({required bool playAfterOpen}) async {
    final existingPlayer = _player;
    if (existingPlayer != null) {
      return existingPlayer;
    }
    if (_opening) {
      setState(() {
        _playWhenReady = _playWhenReady || playAfterOpen;
      });
      return null;
    }

    final generation = ++_openGeneration;
    setState(() {
      _opening = true;
      _failed = false;
      _playWhenReady = playAfterOpen;
    });

    final player = Player();
    final controller = VideoController(player);
    try {
      await player.open(Media(widget.filePath), play: false);
    } catch (_) {
      await player.dispose();
      if (!mounted || generation != _openGeneration) {
        return null;
      }
      setState(() {
        _opening = false;
        _failed = true;
      });
      return null;
    }

    if (!mounted || generation != _openGeneration) {
      await player.dispose();
      return null;
    }

    final shouldPlay = _playWhenReady || playAfterOpen;
    setState(() {
      _player = player;
      _controller = controller;
      _opening = false;
      _playWhenReady = false;
    });

    if (shouldPlay) {
      await player.play();
    } else {
      await player.pause();
    }
    return player;
  }

  Future<void> _togglePlayback() async {
    if (_opening) {
      setState(() {
        _playWhenReady = true;
      });
      return;
    }

    final player = _player ?? await _preparePlayer(playAfterOpen: true);
    if (player == null) {
      return;
    }
    if (player.state.playing) {
      await player.pause();
    } else {
      await player.play();
    }
    _setHoveringControls(false);
  }

  void _setHoveringControls(bool hovering) {
    if (!mounted) {
      return;
    }
    if (_hoveringControls == hovering) {
      return;
    }
    setState(() {
      _hoveringControls = hovering;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final player = _player;
    final controller = _controller;

    return MouseRegion(
      onEnter: (_) => _setHoveringControls(true),
      onHover: (_) => _setHoveringControls(true),
      onExit: (_) => _setHoveringControls(false),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (player != null && controller != null)
            Video(
              controller: controller,
              fit: widget.fit,
              controls: NoVideoControls,
            )
          else if (widget.thumbnailPath != null)
            Image.file(
              File(widget.thumbnailPath!),
              fit: widget.fit,
              errorBuilder: (_, _, _) => _InlineVideoPlaceholder(
                icon: Icons.movie_creation_outlined,
                color: theme.colorScheme.primary,
              ),
            )
          else
            _InlineVideoPlaceholder(
              icon: Icons.movie_creation_outlined,
              color: theme.colorScheme.primary,
            ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.08),
                    Colors.black.withValues(alpha: 0.36),
                  ],
                ),
              ),
            ),
          ),
          if (_failed)
            Center(
              child: _InlineVideoBadge(
                icon: Icons.error_outline_rounded,
                label: '播放失败',
                color: theme.colorScheme.error,
              ),
            )
          else if (_opening)
            const Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
            )
          else if (_hoveringControls)
            Center(
              child: StreamBuilder<bool>(
                stream: player?.stream.playing,
                initialData: player?.state.playing ?? false,
                builder: (context, snapshot) {
                  final playing = snapshot.data == true;
                  return IconButton.filled(
                    onPressed: _togglePlayback,
                    iconSize: 34,
                    tooltip: playing ? '暂停' : '播放',
                    icon: Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    ),
                  );
                },
              ),
            ),
          if (widget.showVideoBadge)
            Positioned(
              left: 8,
              bottom: 8,
              child: _InlineVideoBadge(
                icon: Icons.movie_creation_outlined,
                label: '视频',
                color: Colors.white,
              ),
            ),
          if (widget.showFullscreenButton && widget.onOpenFullscreen != null)
            Positioned(
              right: 8,
              bottom: 8,
              child: IconButton.filledTonal(
                onPressed: widget.onOpenFullscreen,
                iconSize: 20,
                tooltip: '全屏播放',
                icon: const Icon(Icons.fullscreen_rounded),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black.withValues(alpha: 0.68),
                  foregroundColor: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _InlineVideoPlaceholder extends StatelessWidget {
  const _InlineVideoPlaceholder({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(child: Icon(icon, size: 52, color: color));
  }
}

class _InlineVideoBadge extends StatelessWidget {
  const _InlineVideoBadge({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
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
