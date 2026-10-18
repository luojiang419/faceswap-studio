import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

enum StudioComparisonMode { wipe, split, single }

enum _StudioPanButtons { primary, middleOrSecondary }

typedef _StudioComparisonChildBuilder = Widget Function();

String _formatViewerDuration(Duration duration) {
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

bool _mediaKitReady = false;

void _ensureMediaKitReady() {
  if (_mediaKitReady) {
    return;
  }
  MediaKit.ensureInitialized();
  _mediaKitReady = true;
}

class _StudioZoomPanViewport extends StatefulWidget {
  const _StudioZoomPanViewport({
    super.key,
    required this.child,
    this.panButtons = _StudioPanButtons.primary,
  });

  final Widget child;
  final _StudioPanButtons panButtons;

  @override
  State<_StudioZoomPanViewport> createState() => _StudioZoomPanViewportState();
}

class _StudioZoomPanViewportState extends State<_StudioZoomPanViewport> {
  static const double _minScale = 0.25;
  static const double _maxScale = 8.0;

  double _scale = 1.0;
  Offset _offset = Offset.zero;
  Offset? _lastPanPosition;
  bool _panning = false;

  bool _canPanWithButtons(int buttons) {
    return switch (widget.panButtons) {
      _StudioPanButtons.primary => buttons & kPrimaryMouseButton != 0,
      _StudioPanButtons.middleOrSecondary =>
        buttons & (kMiddleMouseButton | kSecondaryMouseButton) != 0,
    };
  }

  void _resetTransform() {
    setState(() {
      _scale = 1.0;
      _offset = Offset.zero;
      _lastPanPosition = null;
      _panning = false;
    });
  }

  void _zoomAt(Offset focalPoint, Size size, double factor) {
    final nextScale = (_scale * factor).clamp(_minScale, _maxScale);
    if (nextScale == _scale) {
      return;
    }

    final center = Offset(size.width / 2, size.height / 2);
    final contentPoint = (focalPoint - center - _offset) / _scale;
    setState(() {
      _scale = nextScale;
      _offset = focalPoint - center - contentPoint * nextScale;
    });
  }

  void _handlePointerSignal(PointerSignalEvent event, Size size) {
    if (event is! PointerScrollEvent) {
      return;
    }
    final scrollDelta = event.scrollDelta.dy;
    if (scrollDelta == 0) {
      return;
    }
    final factor = math.pow(1.0018, -scrollDelta).toDouble();
    _zoomAt(event.localPosition, size, factor);
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (!_canPanWithButtons(event.buttons)) {
      return;
    }
    setState(() {
      _panning = true;
      _lastPanPosition = event.localPosition;
    });
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (!_panning || !_canPanWithButtons(event.buttons)) {
      _lastPanPosition = null;
      _panning = false;
      return;
    }
    final lastPanPosition = _lastPanPosition;
    if (lastPanPosition == null) {
      _lastPanPosition = event.localPosition;
      return;
    }
    setState(() {
      _offset += event.localPosition - lastPanPosition;
      _lastPanPosition = event.localPosition;
    });
  }

  void _handlePointerEnd(PointerEvent event) {
    if (!_panning && _lastPanPosition == null) {
      return;
    }
    setState(() {
      _panning = false;
      _lastPanPosition = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cursor = _panning
        ? SystemMouseCursors.grabbing
        : SystemMouseCursors.grab;

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
        return MouseRegion(
          cursor: cursor,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerSignal: (event) =>
                _handlePointerSignal(event, viewportSize),
            onPointerDown: _handlePointerDown,
            onPointerMove: _handlePointerMove,
            onPointerUp: _handlePointerEnd,
            onPointerCancel: _handlePointerEnd,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onDoubleTap: _resetTransform,
              child: ClipRect(
                child: Transform.translate(
                  offset: _offset,
                  child: Transform.scale(
                    scale: _scale,
                    alignment: Alignment.center,
                    child: SizedBox.expand(child: widget.child),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _StudioInteractiveComparisonViewport extends StatefulWidget {
  const _StudioInteractiveComparisonViewport({
    required this.mode,
    required this.divider,
    required this.onDividerChanged,
    required this.beforeBuilder,
    required this.afterBuilder,
    required this.singleBuilder,
    required this.beforeLabel,
    required this.afterLabel,
  });

  final StudioComparisonMode mode;
  final double divider;
  final ValueChanged<double> onDividerChanged;
  final _StudioComparisonChildBuilder beforeBuilder;
  final _StudioComparisonChildBuilder afterBuilder;
  final _StudioComparisonChildBuilder singleBuilder;
  final String beforeLabel;
  final String afterLabel;

  @override
  State<_StudioInteractiveComparisonViewport> createState() =>
      _StudioInteractiveComparisonViewportState();
}

class _StudioInteractiveComparisonViewportState
    extends State<_StudioInteractiveComparisonViewport> {
  static const double _minScale = 0.25;
  static const double _maxScale = 8.0;
  static const double _splitDividerThickness = 1.0;

  double _scale = 1.0;
  Offset _offset = Offset.zero;
  Offset? _lastPanPosition;
  bool _panning = false;
  bool _draggingDivider = false;

  bool _canPanWithButtons(int buttons) {
    if (widget.mode == StudioComparisonMode.wipe) {
      return buttons & (kMiddleMouseButton | kSecondaryMouseButton) != 0;
    }
    return buttons & kPrimaryMouseButton != 0;
  }

  void _resetTransform() {
    setState(() {
      _scale = 1.0;
      _offset = Offset.zero;
      _lastPanPosition = null;
      _panning = false;
      _draggingDivider = false;
    });
  }

  void _zoomAt(Offset focalPoint, Size size, double factor) {
    final nextScale = (_scale * factor).clamp(_minScale, _maxScale);
    if (nextScale == _scale) {
      return;
    }

    final center = Offset(size.width / 2, size.height / 2);
    final contentPoint = (focalPoint - center - _offset) / _scale;
    setState(() {
      _scale = nextScale;
      _offset = focalPoint - center - contentPoint * nextScale;
    });
  }

  Size _transformViewportSize(Size size) {
    if (widget.mode != StudioComparisonMode.split) {
      return size;
    }
    final paneWidth = math.max(0.0, (size.width - _splitDividerThickness) / 2);
    return Size(paneWidth, size.height);
  }

  Offset _transformFocalPoint(Size size, Offset localPosition) {
    if (widget.mode != StudioComparisonMode.split) {
      return localPosition;
    }
    final paneWidth = math.max(0.0, (size.width - _splitDividerThickness) / 2);
    if (paneWidth <= 0) {
      return Offset.zero;
    }
    final localY = localPosition.dy.clamp(0.0, size.height).toDouble();
    if (localPosition.dx <= paneWidth) {
      return Offset(localPosition.dx.clamp(0.0, paneWidth).toDouble(), localY);
    }
    final rightLocalX = (localPosition.dx - paneWidth - _splitDividerThickness)
        .clamp(0.0, paneWidth)
        .toDouble();
    return Offset(rightLocalX, localY);
  }

  void _handlePointerSignal(PointerSignalEvent event, Size size) {
    if (event is! PointerScrollEvent) {
      return;
    }
    final scrollDelta = event.scrollDelta.dy;
    if (scrollDelta == 0) {
      return;
    }
    final factor = math.pow(1.0018, -scrollDelta).toDouble();
    _zoomAt(
      _transformFocalPoint(size, event.localPosition),
      _transformViewportSize(size),
      factor,
    );
  }

  void _updateDivider(Size size, Offset localPosition) {
    if (size.width <= 0) {
      return;
    }
    widget.onDividerChanged(
      (localPosition.dx / size.width).clamp(0.0, 1.0).toDouble(),
    );
  }

  void _handlePointerDown(PointerDownEvent event, Size size) {
    if (widget.mode == StudioComparisonMode.wipe &&
        event.buttons & kPrimaryMouseButton != 0) {
      setState(() {
        _draggingDivider = true;
        _panning = false;
        _lastPanPosition = null;
      });
      _updateDivider(size, event.localPosition);
      return;
    }
    if (!_canPanWithButtons(event.buttons)) {
      return;
    }
    setState(() {
      _draggingDivider = false;
      _panning = true;
      _lastPanPosition = event.localPosition;
    });
  }

  void _handlePointerMove(PointerMoveEvent event, Size size) {
    if (_draggingDivider) {
      _updateDivider(size, event.localPosition);
      return;
    }
    if (!_panning || !_canPanWithButtons(event.buttons)) {
      if (_panning || _lastPanPosition != null) {
        setState(() {
          _panning = false;
          _lastPanPosition = null;
        });
      }
      return;
    }
    final lastPanPosition = _lastPanPosition;
    if (lastPanPosition == null) {
      _lastPanPosition = event.localPosition;
      return;
    }
    setState(() {
      _offset += event.localPosition - lastPanPosition;
      _lastPanPosition = event.localPosition;
    });
  }

  void _handlePointerEnd(PointerEvent event) {
    if (!_panning && !_draggingDivider && _lastPanPosition == null) {
      return;
    }
    setState(() {
      _panning = false;
      _draggingDivider = false;
      _lastPanPosition = null;
    });
  }

  Widget _buildTransformedLayer(_StudioComparisonChildBuilder builder) {
    return Transform.translate(
      offset: _offset,
      child: Transform.scale(
        scale: _scale,
        alignment: Alignment.center,
        child: SizedBox.expand(child: builder()),
      ),
    );
  }

  Widget _buildSplitPane({
    required _StudioComparisonChildBuilder builder,
    required String label,
    required bool alignLeft,
  }) {
    return Expanded(
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildTransformedLayer(builder),
            Positioned(
              left: alignLeft ? 18 : null,
              right: alignLeft ? null : 18,
              bottom: 18,
              child: _ComparisonLabel(label),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildViewportContent(Size size) {
    final safeDivider = widget.divider.clamp(0.0, 1.0);
    return switch (widget.mode) {
      StudioComparisonMode.single => ClipRect(
        child: _buildTransformedLayer(widget.singleBuilder),
      ),
      StudioComparisonMode.split => Row(
        children: [
          _buildSplitPane(
            builder: widget.beforeBuilder,
            label: widget.beforeLabel,
            alignLeft: true,
          ),
          Container(
            width: _splitDividerThickness,
            color: Colors.white.withValues(alpha: 0.22),
          ),
          _buildSplitPane(
            builder: widget.afterBuilder,
            label: widget.afterLabel,
            alignLeft: false,
          ),
        ],
      ),
      StudioComparisonMode.wipe => Stack(
        fit: StackFit.expand,
        children: [
          ClipRect(child: _buildTransformedLayer(widget.afterBuilder)),
          ClipRect(
            clipper: _StudioComparisonClipper(safeDivider),
            child: _buildTransformedLayer(widget.beforeBuilder),
          ),
          Positioned(
            left: 18,
            bottom: 18,
            child: _ComparisonLabel(widget.beforeLabel),
          ),
          Positioned(
            right: 18,
            bottom: 18,
            child: _ComparisonLabel(widget.afterLabel),
          ),
          Positioned(
            left: size.width * safeDivider - 22,
            top: 0,
            bottom: 0,
            child: const _ComparisonDividerHandle(),
          ),
        ],
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final cursor = _draggingDivider
        ? SystemMouseCursors.resizeColumn
        : _panning
        ? SystemMouseCursors.grabbing
        : widget.mode == StudioComparisonMode.wipe
        ? SystemMouseCursors.resizeColumn
        : SystemMouseCursors.grab;

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
        return MouseRegion(
          cursor: cursor,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerSignal: (event) =>
                _handlePointerSignal(event, viewportSize),
            onPointerDown: (event) => _handlePointerDown(event, viewportSize),
            onPointerMove: (event) => _handlePointerMove(event, viewportSize),
            onPointerUp: _handlePointerEnd,
            onPointerCancel: _handlePointerEnd,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onDoubleTap: _resetTransform,
              child: ClipRect(child: _buildViewportContent(viewportSize)),
            ),
          ),
        );
      },
    );
  }
}

class StudioImageComparisonFrame extends StatelessWidget {
  const StudioImageComparisonFrame({
    super.key,
    required this.beforeImage,
    required this.afterImage,
    required this.singleImage,
    required this.mode,
    required this.divider,
    required this.onDividerChanged,
    this.followPointer = false,
    this.beforeLabel = '原始',
    this.afterLabel = '结果',
  });

  final ImageProvider beforeImage;
  final ImageProvider afterImage;
  final ImageProvider singleImage;
  final StudioComparisonMode mode;
  final double divider;
  final ValueChanged<double> onDividerChanged;
  final bool followPointer;
  final String beforeLabel;
  final String afterLabel;

  @override
  Widget build(BuildContext context) {
    return switch (mode) {
      StudioComparisonMode.split => _StudioSplitComparisonFrame(
        beforeImage: beforeImage,
        afterImage: afterImage,
        beforeLabel: beforeLabel,
        afterLabel: afterLabel,
      ),
      StudioComparisonMode.single => Image(
        image: singleImage,
        fit: BoxFit.contain,
        gaplessPlayback: true,
      ),
      StudioComparisonMode.wipe => _StudioWipeComparisonFrame(
        beforeImage: beforeImage,
        afterImage: afterImage,
        beforeLabel: beforeLabel,
        afterLabel: afterLabel,
        divider: divider,
        onDividerChanged: onDividerChanged,
        followPointer: followPointer,
      ),
    };
  }
}

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

Future<void> showStudioImageGalleryViewer(
  BuildContext context, {
  required List<String> filePaths,
  int initialIndex = 0,
  String? title,
}) async {
  assert(filePaths.isNotEmpty);
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (context) => _StudioImageGalleryViewerDialog(
      filePaths: filePaths,
      initialIndex: initialIndex,
      title: title,
    ),
  );
}

Future<void> showStudioImageComparisonViewer(
  BuildContext context, {
  String? beforeFilePath,
  String? afterFilePath,
  Uint8List? beforeImageBytes,
  Uint8List? afterImageBytes,
  Uint8List? singleImageBytes,
  String? title,
}) async {
  assert(beforeFilePath != null || beforeImageBytes != null);
  assert(afterFilePath != null || afterImageBytes != null);
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (context) => _StudioImageComparisonViewerDialog(
      beforeFilePath: beforeFilePath,
      afterFilePath: afterFilePath,
      beforeImageBytes: beforeImageBytes,
      afterImageBytes: afterImageBytes,
      singleImageBytes: singleImageBytes,
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

Future<void> showStudioVideoComparisonViewer(
  BuildContext context, {
  required String beforeFilePath,
  required String afterFilePath,
  String? title,
}) async {
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (context) => _StudioVideoComparisonViewerDialog(
      beforeFilePath: beforeFilePath,
      afterFilePath: afterFilePath,
      title: title,
    ),
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

    _ensureMediaKitReady();
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

class _StudioWipeComparisonFrame extends StatelessWidget {
  const _StudioWipeComparisonFrame({
    required this.beforeImage,
    required this.afterImage,
    required this.beforeLabel,
    required this.afterLabel,
    required this.divider,
    required this.onDividerChanged,
    required this.followPointer,
  });

  final ImageProvider beforeImage;
  final ImageProvider afterImage;
  final String beforeLabel;
  final String afterLabel;
  final double divider;
  final ValueChanged<double> onDividerChanged;
  final bool followPointer;

  void _updateDivider(BoxConstraints constraints, Offset localPosition) {
    if (constraints.maxWidth <= 0) {
      return;
    }
    onDividerChanged((localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final safeDivider = divider.clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        return MouseRegion(
          cursor: SystemMouseCursors.resizeLeftRight,
          onHover: followPointer
              ? (event) => _updateDivider(constraints, event.localPosition)
              : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanDown: (details) =>
                _updateDivider(constraints, details.localPosition),
            onPanUpdate: (details) =>
                _updateDivider(constraints, details.localPosition),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image(image: afterImage, fit: BoxFit.contain),
                ClipRect(
                  clipper: _StudioComparisonClipper(safeDivider),
                  child: Image(image: beforeImage, fit: BoxFit.contain),
                ),
                Positioned(
                  left: 18,
                  bottom: 18,
                  child: _ComparisonLabel(beforeLabel),
                ),
                Positioned(
                  right: 18,
                  bottom: 18,
                  child: _ComparisonLabel(afterLabel),
                ),
                Positioned(
                  left: constraints.maxWidth * safeDivider - 22,
                  top: 0,
                  bottom: 0,
                  child: const _ComparisonDividerHandle(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StudioSplitComparisonFrame extends StatelessWidget {
  const _StudioSplitComparisonFrame({
    required this.beforeImage,
    required this.afterImage,
    required this.beforeLabel,
    required this.afterLabel,
  });

  final ImageProvider beforeImage;
  final ImageProvider afterImage;
  final String beforeLabel;
  final String afterLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image(image: beforeImage, fit: BoxFit.contain),
              Positioned(
                left: 18,
                bottom: 18,
                child: _ComparisonLabel(beforeLabel),
              ),
            ],
          ),
        ),
        Container(width: 1, color: Colors.white.withValues(alpha: 0.22)),
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image(image: afterImage, fit: BoxFit.contain),
              Positioned(
                right: 18,
                bottom: 18,
                child: _ComparisonLabel(afterLabel),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StudioComparisonClipper extends CustomClipper<Rect> {
  const _StudioComparisonClipper(this.divider);

  final double divider;

  @override
  Rect getClip(Size size) {
    return Rect.fromLTWH(0, 0, size.width * divider, size.height);
  }

  @override
  bool shouldReclip(covariant _StudioComparisonClipper oldClipper) {
    return oldClipper.divider != divider;
  }
}

class _ComparisonDividerHandle extends StatelessWidget {
  const _ComparisonDividerHandle();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: Center(
              child: Container(
                width: 4,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.52),
                      blurRadius: 14,
                    ),
                  ],
                ),
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.black.withValues(alpha: 0.22)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.38),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: const SizedBox(
              width: 38,
              height: 38,
              child: Icon(
                Icons.drag_indicator_rounded,
                color: Colors.black87,
                size: 24,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ComparisonLabel extends StatelessWidget {
  const _ComparisonLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _ComparisonModeButtons extends StatelessWidget {
  const _ComparisonModeButtons({
    required this.mode,
    required this.onChanged,
    this.compact = false,
  });

  final StudioComparisonMode mode;
  final ValueChanged<StudioComparisonMode> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<StudioComparisonMode>(
      segments: [
        ButtonSegment<StudioComparisonMode>(
          value: StudioComparisonMode.wipe,
          icon: Icon(Icons.compare_arrows_rounded, size: compact ? 16 : 18),
          label: const Text('划像'),
        ),
        ButtonSegment<StudioComparisonMode>(
          value: StudioComparisonMode.split,
          icon: Icon(Icons.splitscreen_rounded, size: compact ? 16 : 18),
          label: const Text('双屏'),
        ),
        ButtonSegment<StudioComparisonMode>(
          value: StudioComparisonMode.single,
          icon: Icon(Icons.image_outlined, size: compact ? 16 : 18),
          label: const Text('单图'),
        ),
      ],
      selected: {mode},
      onSelectionChanged: (selection) => onChanged(selection.first),
      showSelectedIcon: false,
      style: ButtonStyle(
        visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
      ),
    );
  }
}

class _DismissViewerIntent extends Intent {
  const _DismissViewerIntent();
}

class _PreviousViewerItemIntent extends Intent {
  const _PreviousViewerItemIntent();
}

class _NextViewerItemIntent extends Intent {
  const _NextViewerItemIntent();
}

class _TogglePlaybackIntent extends Intent {
  const _TogglePlaybackIntent();
}

class _ViewerKeyboardScope extends StatelessWidget {
  const _ViewerKeyboardScope({
    required this.onDismiss,
    required this.child,
    this.onPreviousItem,
    this.onNextItem,
    this.onTogglePlayback,
  });

  final VoidCallback onDismiss;
  final VoidCallback? onPreviousItem;
  final VoidCallback? onNextItem;
  final VoidCallback? onTogglePlayback;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.escape):
            const _DismissViewerIntent(),
        if (onPreviousItem != null)
          const SingleActivator(LogicalKeyboardKey.arrowLeft):
              const _PreviousViewerItemIntent(),
        if (onNextItem != null)
          const SingleActivator(LogicalKeyboardKey.arrowRight):
              const _NextViewerItemIntent(),
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
          if (onPreviousItem != null)
            _PreviousViewerItemIntent:
                CallbackAction<_PreviousViewerItemIntent>(
                  onInvoke: (_) {
                    onPreviousItem!();
                    return null;
                  },
                ),
          if (onNextItem != null)
            _NextViewerItemIntent: CallbackAction<_NextViewerItemIntent>(
              onInvoke: (_) {
                onNextItem!();
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
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 78, 24, 24),
                child: _StudioZoomPanViewport(
                  panButtons: _StudioPanButtons.primary,
                  child: filePath != null
                      ? Image.file(File(filePath!), fit: BoxFit.contain)
                      : Image.memory(imageBytes!, fit: BoxFit.contain),
                ),
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

class _StudioImageGalleryViewerDialog extends StatefulWidget {
  const _StudioImageGalleryViewerDialog({
    required this.filePaths,
    required this.initialIndex,
    this.title,
  });

  final List<String> filePaths;
  final int initialIndex;
  final String? title;

  @override
  State<_StudioImageGalleryViewerDialog> createState() =>
      _StudioImageGalleryViewerDialogState();
}

class _StudioImageGalleryViewerDialogState
    extends State<_StudioImageGalleryViewerDialog> {
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, widget.filePaths.length - 1);
  }

  void _stepIndex(int delta) {
    if (widget.filePaths.length <= 1) {
      return;
    }
    setState(() {
      _currentIndex =
          (_currentIndex + delta + widget.filePaths.length) %
          widget.filePaths.length;
    });
  }

  @override
  Widget build(BuildContext context) {
    final currentPath = widget.filePaths[_currentIndex];
    final title = widget.title ?? '图片全屏预览';
    final hintLabel = widget.filePaths.length <= 1
        ? '$title · Esc 退出'
        : '$title ${_currentIndex + 1}/${widget.filePaths.length} · ←/→ 切换 · Esc 退出';

    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: _ViewerKeyboardScope(
        onDismiss: () => Navigator.of(context).pop(),
        onPreviousItem: widget.filePaths.length > 1
            ? () => _stepIndex(-1)
            : null,
        onNextItem: widget.filePaths.length > 1 ? () => _stepIndex(1) : null,
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 78, 24, 24),
                child: _StudioZoomPanViewport(
                  key: ValueKey(currentPath),
                  panButtons: _StudioPanButtons.primary,
                  child: Image.file(File(currentPath), fit: BoxFit.contain),
                ),
              ),
            ),
            Positioned(
              top: 24,
              left: 24,
              child: _ViewerHintLabel(label: hintLabel),
            ),
            Positioned(
              top: 24,
              right: 24,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.filePaths.length > 1) ...[
                    IconButton.filledTonal(
                      onPressed: () => _stepIndex(-1),
                      icon: const Icon(Icons.chevron_left_rounded),
                      tooltip: '上一张',
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      onPressed: () => _stepIndex(1),
                      icon: const Icon(Icons.chevron_right_rounded),
                      tooltip: '下一张',
                    ),
                    const SizedBox(width: 8),
                  ],
                  IconButton.filledTonal(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StudioImageComparisonViewerDialog extends StatefulWidget {
  const _StudioImageComparisonViewerDialog({
    this.beforeFilePath,
    this.afterFilePath,
    this.beforeImageBytes,
    this.afterImageBytes,
    this.singleImageBytes,
    this.title,
  });

  final String? beforeFilePath;
  final String? afterFilePath;
  final Uint8List? beforeImageBytes;
  final Uint8List? afterImageBytes;
  final Uint8List? singleImageBytes;
  final String? title;

  @override
  State<_StudioImageComparisonViewerDialog> createState() =>
      _StudioImageComparisonViewerDialogState();
}

class _StudioImageComparisonViewerDialogState
    extends State<_StudioImageComparisonViewerDialog> {
  StudioComparisonMode _mode = StudioComparisonMode.wipe;
  double _divider = 0.5;

  ImageProvider get _beforeImage => widget.beforeImageBytes != null
      ? MemoryImage(widget.beforeImageBytes!)
      : FileImage(File(widget.beforeFilePath!));

  ImageProvider get _afterImage => widget.afterImageBytes != null
      ? MemoryImage(widget.afterImageBytes!)
      : FileImage(File(widget.afterFilePath!));

  ImageProvider get _singleImage => widget.singleImageBytes == null
      ? _afterImage
      : MemoryImage(widget.singleImageBytes!);

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: _ViewerKeyboardScope(
        onDismiss: () => Navigator.of(context).pop(),
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 78, 24, 92),
                child: _StudioInteractiveComparisonViewport(
                  mode: _mode,
                  divider: _divider,
                  onDividerChanged: (value) {
                    setState(() {
                      _divider = value;
                    });
                  },
                  beforeBuilder: () => Image(
                    image: _beforeImage,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                  afterBuilder: () => Image(
                    image: _afterImage,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                  singleBuilder: () => Image(
                    image: _singleImage,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                  beforeLabel: '原始',
                  afterLabel: '结果',
                ),
              ),
            ),
            Positioned(
              top: 24,
              left: 24,
              child: _ViewerHintLabel(
                label: widget.title == null
                    ? '对比预览 · Esc 退出'
                    : '${widget.title} · Esc 退出',
              ),
            ),
            Positioned(
              right: 24,
              bottom: 24,
              child: _ComparisonModeButtons(
                mode: _mode,
                onChanged: (mode) {
                  setState(() {
                    _mode = mode;
                  });
                },
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
  Duration? _dragPosition;

  @override
  void initState() {
    super.initState();
    _ensureMediaKitReady();
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

  Future<void> _seek(Duration position) async {
    await _player.seek(position < Duration.zero ? Duration.zero : position);
  }

  Widget _buildControls() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StreamBuilder<bool>(
              stream: _player.stream.playing,
              initialData: _player.state.playing,
              builder: (context, snapshot) {
                final playing = snapshot.data == true;
                return IconButton.filledTonal(
                  onPressed: _togglePlayback,
                  tooltip: playing ? '暂停' : '播放',
                  icon: Icon(
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  ),
                );
              },
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 360,
              child: StreamBuilder<Duration>(
                stream: _player.stream.duration,
                initialData: _player.state.duration,
                builder: (context, durationSnapshot) {
                  final duration = durationSnapshot.data ?? Duration.zero;
                  return StreamBuilder<Duration>(
                    stream: _player.stream.position,
                    initialData: _player.state.position,
                    builder: (context, positionSnapshot) {
                      final position =
                          _dragPosition ??
                          positionSnapshot.data ??
                          Duration.zero;
                      final maxMilliseconds = duration.inMilliseconds;
                      final value = position.inMilliseconds
                          .clamp(0, maxMilliseconds)
                          .toDouble();
                      return Slider(
                        value: maxMilliseconds <= 0 ? 0.0 : value,
                        min: 0,
                        max: maxMilliseconds <= 0
                            ? 1.0
                            : maxMilliseconds.toDouble(),
                        onChanged: maxMilliseconds <= 0
                            ? null
                            : (nextValue) {
                                setState(() {
                                  _dragPosition = Duration(
                                    milliseconds: nextValue.round(),
                                  );
                                });
                              },
                        onChangeEnd: maxMilliseconds <= 0
                            ? null
                            : (nextValue) async {
                                final nextPosition = Duration(
                                  milliseconds: nextValue.round(),
                                );
                                await _seek(nextPosition);
                                if (!mounted) {
                                  return;
                                }
                                setState(() {
                                  _dragPosition = null;
                                });
                              },
                      );
                    },
                  );
                },
              ),
            ),
            const SizedBox(width: 10),
            StreamBuilder<Duration>(
              stream: _player.stream.position,
              initialData: _player.state.position,
              builder: (context, snapshot) {
                final position =
                    _dragPosition ?? snapshot.data ?? Duration.zero;
                return Text(
                  _formatViewerDuration(position),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
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
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 78, 24, 112),
                child: _StudioZoomPanViewport(
                  child: Video(
                    controller: _controller,
                    fit: BoxFit.contain,
                    controls: NoVideoControls,
                  ),
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
              bottom: 24,
              left: 24,
              right: 24,
              child: Center(child: _buildControls()),
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

class _StudioVideoComparisonViewerDialog extends StatefulWidget {
  const _StudioVideoComparisonViewerDialog({
    required this.beforeFilePath,
    required this.afterFilePath,
    this.title,
  });

  final String beforeFilePath;
  final String afterFilePath;
  final String? title;

  @override
  State<_StudioVideoComparisonViewerDialog> createState() =>
      _StudioVideoComparisonViewerDialogState();
}

class _StudioVideoComparisonViewerDialogState
    extends State<_StudioVideoComparisonViewerDialog> {
  static const Duration _syncInterval = Duration(milliseconds: 250);
  static const Duration _syncThreshold = Duration(milliseconds: 75);

  late final Player _beforePlayer;
  late final Player _afterPlayer;
  late final VideoController _beforeController;
  late final VideoController _afterController;
  Timer? _syncTimer;

  StudioComparisonMode _mode = StudioComparisonMode.wipe;
  double _divider = 0.5;
  bool _opening = true;
  bool _failed = false;
  bool _syncing = false;
  Duration? _dragPosition;

  @override
  void initState() {
    super.initState();
    _ensureMediaKitReady();
    _beforePlayer = Player();
    _afterPlayer = Player();
    _beforeController = VideoController(_beforePlayer);
    _afterController = VideoController(_afterPlayer);
    _openVideos();
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _beforePlayer.dispose();
    _afterPlayer.dispose();
    super.dispose();
  }

  Future<void> _openVideos() async {
    try {
      await Future.wait([
        _beforePlayer.open(Media(widget.beforeFilePath), play: false),
        _afterPlayer.open(Media(widget.afterFilePath), play: false),
      ]);
      if (!mounted) {
        return;
      }
      await _seekSynced(Duration.zero);
      setState(() {
        _opening = false;
      });
      _startSyncTimer();
      await _setPlaying(true);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _opening = false;
        _failed = true;
      });
    }
  }

  void _startSyncTimer() {
    _syncTimer ??= Timer.periodic(_syncInterval, (_) {
      if (_opening || _failed || !_afterPlayer.state.playing) {
        return;
      }
      unawaited(_syncBeforeToAfter());
    });
  }

  Duration _clampBeforePosition(Duration position) {
    if (position < Duration.zero) {
      return Duration.zero;
    }
    final beforeDuration = _beforePlayer.state.duration;
    if (beforeDuration > Duration.zero && position > beforeDuration) {
      return beforeDuration;
    }
    return position;
  }

  Future<void> _syncBeforeToAfter({bool force = false}) async {
    if (_opening || _failed || _syncing) {
      return;
    }

    final afterPosition = _afterPlayer.state.position;
    final beforeTarget = _clampBeforePosition(afterPosition);
    final beforePosition = _beforePlayer.state.position;
    final driftMilliseconds =
        (beforePosition.inMilliseconds - beforeTarget.inMilliseconds).abs();
    if (!force && driftMilliseconds <= _syncThreshold.inMilliseconds) {
      return;
    }

    _syncing = true;
    try {
      await _beforePlayer.seek(beforeTarget);
    } finally {
      _syncing = false;
    }
  }

  Future<void> _seekSynced(Duration position) async {
    final targetPosition = position < Duration.zero ? Duration.zero : position;
    await Future.wait([
      _afterPlayer.seek(targetPosition),
      _beforePlayer.seek(_clampBeforePosition(targetPosition)),
    ]);
  }

  Future<void> _setPlaying(bool playing) async {
    if (playing) {
      await _seekSynced(_afterPlayer.state.position);
      _startSyncTimer();
      await Future.wait([_afterPlayer.play(), _beforePlayer.play()]);
      await _syncBeforeToAfter(force: true);
    } else {
      await Future.wait([_afterPlayer.pause(), _beforePlayer.pause()]);
      await _syncBeforeToAfter(force: true);
    }
  }

  Future<void> _togglePlayback() async {
    if (_opening || _failed) {
      return;
    }
    final playing = _afterPlayer.state.playing;
    await _setPlaying(!playing);
  }

  Future<void> _seek(Duration position) async {
    final wasPlaying = _afterPlayer.state.playing;
    if (wasPlaying) {
      await Future.wait([_afterPlayer.pause(), _beforePlayer.pause()]);
    }
    await _seekSynced(position);
    await _syncBeforeToAfter(force: true);
    if (wasPlaying) {
      await Future.wait([_afterPlayer.play(), _beforePlayer.play()]);
    }
  }

  Widget _buildVideoComparison() {
    if (_opening) {
      return const Center(
        child: SizedBox(
          width: 34,
          height: 34,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      );
    }
    if (_failed) {
      return const Center(
        child: _InlineVideoBadge(
          icon: Icons.error_outline_rounded,
          label: '对比视频打开失败',
          color: Colors.white,
        ),
      );
    }

    return _StudioInteractiveComparisonViewport(
      mode: _mode,
      divider: _divider,
      onDividerChanged: (value) {
        setState(() {
          _divider = value;
        });
      },
      beforeBuilder: () => Video(
        controller: _beforeController,
        fit: BoxFit.contain,
        controls: NoVideoControls,
      ),
      afterBuilder: () => Video(
        controller: _afterController,
        fit: BoxFit.contain,
        controls: NoVideoControls,
      ),
      singleBuilder: () => Video(
        controller: _afterController,
        fit: BoxFit.contain,
        controls: NoVideoControls,
      ),
      beforeLabel: '原始',
      afterLabel: '结果',
    );
  }

  Widget _buildControls() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StreamBuilder<bool>(
              stream: _afterPlayer.stream.playing,
              initialData: _afterPlayer.state.playing,
              builder: (context, snapshot) {
                final playing = snapshot.data == true;
                return IconButton.filledTonal(
                  onPressed: _failed || _opening ? null : _togglePlayback,
                  tooltip: playing ? '暂停' : '播放',
                  icon: Icon(
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  ),
                );
              },
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 360,
              child: StreamBuilder<Duration>(
                stream: _afterPlayer.stream.duration,
                initialData: _afterPlayer.state.duration,
                builder: (context, durationSnapshot) {
                  final duration = durationSnapshot.data ?? Duration.zero;
                  return StreamBuilder<Duration>(
                    stream: _afterPlayer.stream.position,
                    initialData: _afterPlayer.state.position,
                    builder: (context, positionSnapshot) {
                      final position =
                          _dragPosition ??
                          positionSnapshot.data ??
                          Duration.zero;
                      final maxMilliseconds = duration.inMilliseconds;
                      final value = position.inMilliseconds
                          .clamp(0, maxMilliseconds)
                          .toDouble();
                      return Slider(
                        value: maxMilliseconds <= 0 ? 0.0 : value,
                        min: 0,
                        max: maxMilliseconds <= 0
                            ? 1.0
                            : maxMilliseconds.toDouble(),
                        onChanged: _failed || _opening || maxMilliseconds <= 0
                            ? null
                            : (nextValue) {
                                setState(() {
                                  _dragPosition = Duration(
                                    milliseconds: nextValue.round(),
                                  );
                                });
                              },
                        onChangeEnd: _failed || _opening || maxMilliseconds <= 0
                            ? null
                            : (nextValue) async {
                                final nextPosition = Duration(
                                  milliseconds: nextValue.round(),
                                );
                                await _seek(nextPosition);
                                if (!mounted) {
                                  return;
                                }
                                setState(() {
                                  _dragPosition = null;
                                });
                              },
                      );
                    },
                  );
                },
              ),
            ),
            const SizedBox(width: 10),
            StreamBuilder<Duration>(
              stream: _afterPlayer.stream.position,
              initialData: _afterPlayer.state.position,
              builder: (context, snapshot) {
                final position =
                    _dragPosition ?? snapshot.data ?? Duration.zero;
                return Text(
                  _formatDuration(position),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                );
              },
            ),
            const SizedBox(width: 16),
            _ComparisonModeButtons(
              mode: _mode,
              onChanged: (mode) {
                setState(() {
                  _mode = mode;
                });
              },
              compact: true,
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    return _formatViewerDuration(duration);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: _ViewerKeyboardScope(
        onDismiss: () => Navigator.of(context).pop(),
        onTogglePlayback: _togglePlayback,
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 78, 24, 112),
                child: _buildVideoComparison(),
              ),
            ),
            Positioned(
              top: 24,
              left: 24,
              child: _ViewerHintLabel(
                label: widget.title == null
                    ? '视频对比 · Space 播放/暂停 · Esc 退出'
                    : '${widget.title} · Space 播放/暂停 · Esc 退出',
              ),
            ),
            Positioned(
              bottom: 24,
              left: 24,
              right: 24,
              child: Center(child: _buildControls()),
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
