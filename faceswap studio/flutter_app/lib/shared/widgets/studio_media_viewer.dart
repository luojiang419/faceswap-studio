import 'package:faceswap_studio/shared/widgets/studio_video_controls.dart';
import 'package:faceswap_studio/shared/widgets/studio_media_loading.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../services/studio_fullscreen.dart';

enum StudioComparisonMode { wipe, split, single }

enum _StudioPanButtons { primary, middleOrSecondary }

typedef _StudioComparisonChildBuilder = Widget Function();

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
    this.onOpenFullscreen,
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
  final VoidCallback? onOpenFullscreen;

  @override
  Widget build(BuildContext context) {
    return switch (mode) {
      StudioComparisonMode.split => _StudioSplitComparisonFrame(
        beforeImage: beforeImage,
        afterImage: afterImage,
        beforeLabel: beforeLabel,
        afterLabel: afterLabel,
        onOpenFullscreen: onOpenFullscreen,
      ),
      StudioComparisonMode.single => Stack(
        fit: StackFit.expand,
        children: [
          Image(image: singleImage, fit: BoxFit.contain, gaplessPlayback: true),
          if (onOpenFullscreen != null)
            Positioned(
              right: 18,
              bottom: 18,
              child: _ComparisonResultLabel(
                afterLabel,
                onOpenFullscreen: onOpenFullscreen,
              ),
            ),
        ],
      ),
      StudioComparisonMode.wipe => _StudioWipeComparisonFrame(
        beforeImage: beforeImage,
        afterImage: afterImage,
        beforeLabel: beforeLabel,
        afterLabel: afterLabel,
        divider: divider,
        onDividerChanged: onDividerChanged,
        followPointer: followPointer,
        onOpenFullscreen: onOpenFullscreen,
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
}) => _showStudioVideoFullscreen(context, filePath: filePath, title: title);

Future<void> _showStudioVideoFullscreen(
  BuildContext context, {
  required String filePath,
  String? title,
  Player? player,
  VideoController? controller,
  StudioVideoFramePreview? framePreview,
}) async {
  final appFullscreen = StudioFullscreen.active.value;
  if (!appFullscreen) await defaultEnterNativeFullscreen();
  try {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) => _StudioVideoViewerDialog(
        filePath: filePath,
        title: title,
        sharedPlayer: player,
        sharedController: controller,
        framePreview: framePreview,
      ),
    );
  } finally {
    if (!appFullscreen) await defaultExitNativeFullscreen();
  }
}

Future<void> showStudioVideoComparisonViewer(
  BuildContext context, {
  required String beforeFilePath,
  required String afterFilePath,
  String? title,
}) async {
  final appFullscreen = StudioFullscreen.active.value;
  if (!appFullscreen) await defaultEnterNativeFullscreen();
  try {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) => _StudioVideoComparisonViewerDialog(
        beforeFilePath: beforeFilePath,
        afterFilePath: afterFilePath,
        title: title,
      ),
    );
  } finally {
    if (!appFullscreen) await defaultExitNativeFullscreen();
  }
}

class _StudioPlayerTransport extends StatelessWidget {
  const _StudioPlayerTransport({
    this.framePreview,
    required this.player,
    required this.onTogglePlayback,
    required this.onSeek,
    this.onFullscreen,
    this.fullscreen = false,
    this.enabled = true,
  });

  final Player? player;
  final StudioVideoFramePreview? framePreview;
  final VoidCallback onTogglePlayback;
  final Future<void> Function(Duration) onSeek;
  final VoidCallback? onFullscreen;
  final bool fullscreen;
  final bool enabled;

  @override
  Widget build(BuildContext context) => StreamBuilder<Duration>(
    stream: player?.stream.duration,
    initialData: player?.state.duration ?? Duration.zero,
    builder: (context, duration) => StreamBuilder<Duration>(
      stream: player?.stream.position,
      initialData: player?.state.position ?? Duration.zero,
      builder: (context, position) => StreamBuilder<bool>(
        stream: player?.stream.playing,
        initialData: player?.state.playing ?? false,
        builder: (context, playing) => StudioVideoControls(
          duration: duration.data ?? Duration.zero,
          position: position.data ?? Duration.zero,
          playing: playing.data == true,
          enabled: enabled && player != null,
          onTogglePlayback: onTogglePlayback,
          onSeek: onSeek,
          onFullscreen: onFullscreen,
          fullscreen: fullscreen,
          framePreview: framePreview,
        ),
      ),
    ),
  );
}

class StudioInlineVideoPlayer extends StatefulWidget {
  const StudioInlineVideoPlayer({
    super.key,
    this.framePreview,
    required this.filePath,
    this.thumbnailPath,
    this.fit = BoxFit.cover,
    this.onOpenFullscreen,
    this.showFullscreenButton = true,
    this.thumbnailControls = false,
    this.initialPosition = Duration.zero,
  });

  final String filePath;
  final StudioVideoFramePreview? framePreview;
  final String? thumbnailPath;
  final BoxFit fit;
  final VoidCallback? onOpenFullscreen;
  final bool showFullscreenButton;
  final bool thumbnailControls;
  final Duration initialPosition;

  @override
  State<StudioInlineVideoPlayer> createState() =>
      _StudioInlineVideoPlayerState();
}

class _StudioInlineVideoPlayerState extends State<StudioInlineVideoPlayer> {
  Player? _player;
  VideoController? _controller;
  bool _opening = false;
  bool _waitingForFirstFrame = true;
  bool _failed = false;
  bool _playWhenReady = false;
  final FocusNode _focusNode = FocusNode();
  bool _fullscreenOpen = false;
  int _openGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.thumbnailControls) {
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
      _waitingForFirstFrame = true;
      _failed = false;
      _playWhenReady = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !widget.thumbnailControls) {
          _preparePlayer(playAfterOpen: false);
        }
      });
    }
  }

  @override
  void dispose() {
    _disposePlayer();
    _focusNode.dispose();
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
      _waitingForFirstFrame = true;
      _failed = false;
      _playWhenReady = playAfterOpen;
    });

    Player? player;
    VideoController? controller;
    try {
      _ensureMediaKitReady();
      player = Player();
      controller = VideoController(player);
      await player.open(
        Media(widget.filePath, start: widget.initialPosition),
        play: false,
      );
    } catch (_) {
      await player?.dispose();
      if (!mounted || generation != _openGeneration) {
        return null;
      }
      setState(() {
        _opening = false;
        _waitingForFirstFrame = false;
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
    // open() 只代表媒体已打开。保持 SVG，直到原生纹理报告首帧已渲染。
    unawaited(_waitForFirstFrame(controller, player, generation));

    if (shouldPlay) {
      await player.play();
    } else {
      await player.pause();
    }
    return player;
  }

  Future<void> _waitForFirstFrame(
    VideoController controller,
    Player player,
    int generation,
  ) async {
    try {
      await controller.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 30),
      );
      if (!mounted ||
          generation != _openGeneration ||
          !identical(player, _player)) {
        return;
      }
      setState(() => _waitingForFirstFrame = false);
    } catch (_) {
      if (!mounted ||
          generation != _openGeneration ||
          !identical(player, _player)) {
        return;
      }
      _disposePlayer();
      setState(() {
        _waitingForFirstFrame = false;
        _failed = true;
      });
    }
  }

  Future<void> _togglePlayback() async {
    if (_opening) {
      setState(() {
        _playWhenReady = true;
      });
      return;
    }

    if (_player == null) {
      await _preparePlayer(playAfterOpen: true);
      return;
    }
    final player = _player!;
    if (player.state.playing) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  Future<void> _seek(Duration value) async {
    final player = _player;
    if (player == null) return;
    await player.seek(clampStudioVideoPosition(value, player.state.duration));
  }

  Future<void> _openFullscreen() async {
    if (_fullscreenOpen || _opening) return;
    _focusNode.requestFocus();
    final player =
        _player ??
        await _preparePlayer(playAfterOpen: widget.thumbnailControls);
    if (!mounted) return;
    if (player == null || _controller == null) {
      widget.onOpenFullscreen?.call();
      return;
    }
    if (widget.thumbnailControls && !player.state.playing) await player.play();
    if (!mounted) return;
    setState(() => _fullscreenOpen = true);
    try {
      await _showStudioVideoFullscreen(
        context,
        filePath: widget.filePath,
        player: player,
        controller: _controller,
        framePreview: widget.framePreview,
      );
    } finally {
      if (mounted) {
        setState(() => _fullscreenOpen = false);
        _focusNode.requestFocus();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final player = _player;
    final controller = _controller;
    final video = ColoredBox(
      color: Colors.black,
      child: player != null && controller != null && !_fullscreenOpen
          ? Video(
              controller: controller,
              fit: widget.fit,
              controls: NoVideoControls,
            )
          : widget.thumbnailPath != null
          ? Image.file(
              File(widget.thumbnailPath!),
              fit: widget.fit,
              errorBuilder: (_, _, _) => _InlineVideoPlaceholder(
                icon: Icons.movie_creation_outlined,
                color: theme.colorScheme.primary,
              ),
            )
          : _InlineVideoPlaceholder(
              icon: Icons.movie_creation_outlined,
              color: theme.colorScheme.primary,
            ),
    );
    void toggle() {
      _focusNode.requestFocus();
      _togglePlayback();
    }

    final media = Stack(
      fit: StackFit.expand,
      children: [
        video,
        if (_failed)
          Align(
            alignment: widget.thumbnailControls
                ? Alignment.bottomCenter
                : Alignment.center,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: FittedBox(
                child: _InlineVideoBadge(
                  icon: Icons.error_outline_rounded,
                  label: '播放失败',
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ),
        if (!_failed &&
            (_opening ||
                (_waitingForFirstFrame &&
                    (!widget.thumbnailControls || player != null))))
          Positioned.fill(
            key: const ValueKey('inline-video-loading'),
            child: IgnorePointer(
              child: ColoredBox(
                color: theme.brightness == Brightness.dark
                    ? const Color(0xFF20201E)
                    : theme.colorScheme.surfaceContainer,
                child: const StudioMediaLoading(
                  kind: StudioMediaLoadingKind.video,
                ),
              ),
            ),
          ),
      ],
    );
    return StudioVideoHotkeys(
      focusNode: _focusNode,
      onTogglePlayback: _togglePlayback,
      onSeekRelative: (delta) =>
          _seek((_player?.state.position ?? Duration.zero) + delta),
      onFullscreen: _openFullscreen,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.thumbnailControls)
            StreamBuilder<bool>(
              stream: player?.stream.playing,
              initialData: player?.state.playing ?? false,
              builder: (context, playing) => StudioVideoThumbnailSurface(
                playing: playing.data == true,
                onTogglePlayback: toggle,
                onFullscreen: _openFullscreen,
                child: media,
              ),
            )
          else
            GestureDetector(
              key: const ValueKey('studio-video-surface'),
              behavior: HitTestBehavior.opaque,
              onTap: toggle,
              onDoubleTap: _openFullscreen,
              child: media,
            ),
          if (!widget.thumbnailControls)
            Positioned(
              left: 6,
              right: 6,
              bottom: 6,
              child: _StudioPlayerTransport(
                player: player,
                framePreview: _fullscreenOpen ? null : widget.framePreview,
                enabled: !_opening && !_waitingForFirstFrame && !_failed,
                onTogglePlayback: () {
                  _focusNode.requestFocus();
                  _togglePlayback();
                },
                onSeek: _seek,
                onFullscreen: widget.showFullscreenButton
                    ? _openFullscreen
                    : null,
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
    this.onOpenFullscreen,
  });

  final ImageProvider beforeImage;
  final ImageProvider afterImage;
  final String beforeLabel;
  final String afterLabel;
  final double divider;
  final ValueChanged<double> onDividerChanged;
  final bool followPointer;
  final VoidCallback? onOpenFullscreen;

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
      builder: (context, constraints) => Stack(
        fit: StackFit.expand,
        children: [
          MouseRegion(
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
                    left: constraints.maxWidth * safeDivider - 22,
                    top: 0,
                    bottom: 0,
                    child: const _ComparisonDividerHandle(),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            right: 18,
            bottom: 18,
            child: _ComparisonResultLabel(
              afterLabel,
              onOpenFullscreen: onOpenFullscreen,
            ),
          ),
        ],
      ),
    );
  }
}

class _StudioSplitComparisonFrame extends StatelessWidget {
  const _StudioSplitComparisonFrame({
    required this.beforeImage,
    required this.afterImage,
    required this.beforeLabel,
    required this.afterLabel,
    this.onOpenFullscreen,
  });

  final ImageProvider beforeImage;
  final ImageProvider afterImage;
  final String beforeLabel;
  final String afterLabel;
  final VoidCallback? onOpenFullscreen;

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
                child: _ComparisonResultLabel(
                  afterLabel,
                  onOpenFullscreen: onOpenFullscreen,
                ),
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

class _ComparisonResultLabel extends StatelessWidget {
  const _ComparisonResultLabel(this.label, {this.onOpenFullscreen});

  final String label;
  final VoidCallback? onOpenFullscreen;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (onOpenFullscreen != null) ...[
        IconButton(
          key: const ValueKey('preview-fullscreen-action'),
          tooltip: '全屏查看',
          onPressed: onOpenFullscreen,
          icon: const Icon(Icons.wb_sunny_outlined, size: 17),
          style: IconButton.styleFrom(
            foregroundColor: Colors.white,
            backgroundColor: Colors.black.withValues(alpha: .68),
            minimumSize: const Size(30, 30),
            padding: const EdgeInsets.all(6),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: CircleBorder(
              side: BorderSide(color: Colors.white.withValues(alpha: .28)),
            ),
          ),
        ),
        const SizedBox(width: 6),
      ],
      _ComparisonLabel(label),
    ],
  );
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

class _ViewerKeyboardScope extends StatelessWidget {
  const _ViewerKeyboardScope({
    required this.onDismiss,
    required this.child,
    this.onPreviousItem,
    this.onNextItem,
  });

  final VoidCallback onDismiss;
  final VoidCallback? onPreviousItem;
  final VoidCallback? onNextItem;
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
  const _StudioVideoViewerDialog({
    this.framePreview,
    required this.filePath,
    this.title,
    this.sharedPlayer,
    this.sharedController,
  });

  final String filePath;
  final StudioVideoFramePreview? framePreview;
  final String? title;
  final Player? sharedPlayer;
  final VideoController? sharedController;

  @override
  State<_StudioVideoViewerDialog> createState() =>
      _StudioVideoViewerDialogState();
}

class _StudioVideoViewerDialogState extends State<_StudioVideoViewerDialog> {
  late final Player _player;
  late final VideoController _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _ensureMediaKitReady();
    _player = widget.sharedPlayer ?? Player();
    _controller = widget.sharedController ?? VideoController(_player);
    if (widget.sharedPlayer == null) _openVideo();
  }

  Future<void> _openVideo() async {
    try {
      await _player.open(Media(widget.filePath));
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    if (widget.sharedPlayer == null) _player.dispose();
    super.dispose();
  }

  Future<void> _seek(Duration value) =>
      _player.seek(clampStudioVideoPosition(value, _player.state.duration));

  void _dismiss() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    backgroundColor: Colors.black,
    child: StudioVideoHotkeys(
      autofocus: true,
      onDismiss: _dismiss,
      onTogglePlayback: () => _player.playOrPause(),
      onSeekRelative: (delta) => _seek(_player.state.position + delta),
      onFullscreen: _dismiss,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: _dismiss,
              child: _failed
                  ? const Center(
                      child: Text(
                        '视频播放失败，请检查文件是否可用。',
                        style: TextStyle(color: Colors.white),
                      ),
                    )
                  : Video(
                      controller: _controller,
                      fit: BoxFit.contain,
                      controls: NoVideoControls,
                    ),
            ),
          ),
          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: _StudioPlayerTransport(
                  player: _player,
                  framePreview: widget.framePreview,
                  enabled: !_failed,
                  onTogglePlayback: () => _player.playOrPause(),
                  onSeek: _seek,
                  fullscreen: true,
                  onFullscreen: _dismiss,
                ),
              ),
            ),
          ),
          Positioned(
            top: 16,
            right: 16,
            child: IconButton.filledTonal(
              tooltip: '退出全屏（Esc）',
              onPressed: _dismiss,
              icon: const Icon(Icons.close_rounded),
            ),
          ),
        ],
      ),
    ),
  );
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

  Widget _buildControls() => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 760),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ComparisonModeButtons(
          mode: _mode,
          compact: true,
          onChanged: (mode) => setState(() => _mode = mode),
        ),
        const SizedBox(height: 8),
        _StudioPlayerTransport(
          player: _afterPlayer,
          enabled: !_failed && !_opening,
          onTogglePlayback: _togglePlayback,
          onSeek: _seek,
          fullscreen: true,
          onFullscreen: () => Navigator.of(context).pop(),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: StudioVideoHotkeys(
        autofocus: true,
        onSeekRelative: (delta) => _seek(_afterPlayer.state.position + delta),
        onFullscreen: () => Navigator.of(context).pop(),
        onDismiss: () => Navigator.of(context).pop(),
        onTogglePlayback: _togglePlayback,
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 78, 24, 156),
                child: _buildVideoComparison(),
              ),
            ),
            Positioned(
              top: 24,
              left: 24,
              right: 76,
              child: _ViewerHintLabel(
                label: widget.title == null
                    ? '视频对比 · Space 播放/暂停 · ←/→ 5 秒 · Esc 退出'
                    : '${widget.title} · Space 播放/暂停 · ←/→ 5 秒 · Esc 退出',
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
