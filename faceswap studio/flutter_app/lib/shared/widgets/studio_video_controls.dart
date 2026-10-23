import 'studio_frame_scrubber.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

String formatStudioVideoTime(Duration value) {
  final seconds = value.inSeconds.clamp(0, 1 << 53);
  final mm = (seconds ~/ 60 % 60).toString().padLeft(2, '0');
  final ss = (seconds % 60).toString().padLeft(2, '0');
  return seconds >= 3600 ? '${seconds ~/ 3600}:$mm:$ss' : '$mm:$ss';
}

Duration clampStudioVideoPosition(Duration value, Duration duration) =>
    Duration(
      milliseconds: value.inMilliseconds.clamp(
        0,
        duration.inMilliseconds.clamp(0, 1 << 53),
      ),
    );

/// 队列小格只保留居中的悬浮按钮；单击与双击由同一手势层区分。
class StudioVideoThumbnailSurface extends StatefulWidget {
  const StudioVideoThumbnailSurface({
    super.key,
    required this.child,
    required this.playing,
    required this.onTogglePlayback,
    required this.onFullscreen,
  });

  final Widget child;
  final bool playing;
  final VoidCallback onTogglePlayback;
  final VoidCallback onFullscreen;

  @override
  State<StudioVideoThumbnailSurface> createState() =>
      _StudioVideoThumbnailSurfaceState();
}

class _StudioVideoThumbnailSurfaceState
    extends State<StudioVideoThumbnailSurface> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: Semantics(
      button: true,
      label: widget.playing ? '暂停视频' : '播放视频',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTogglePlayback,
        onDoubleTap: widget.onFullscreen,
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            IgnorePointer(
              child: Center(
                child: AnimatedOpacity(
                  key: const ValueKey('thumbnail-play-button'),
                  opacity: _hovered ? 1 : 0,
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 150),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.62),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white30),
                    ),
                    child: SizedBox.square(
                      dimension: 40,
                      child: Icon(
                        widget.playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 仅在播放器获得焦点时处理快捷键，避免影响其他页面输入。
class StudioVideoHotkeys extends StatelessWidget {
  const StudioVideoHotkeys({
    required this.child,
    required this.onTogglePlayback,
    required this.onSeekRelative,
    this.onFullscreen,
    this.onDismiss,
    this.focusNode,
    this.autofocus = false,
    super.key,
  });

  final Widget child;
  final VoidCallback onTogglePlayback;
  final ValueChanged<Duration> onSeekRelative;
  final VoidCallback? onFullscreen;
  final VoidCallback? onDismiss;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: focusNode,
    autofocus: autofocus,
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      final keyboard = HardwareKeyboard.instance;
      if (keyboard.isControlPressed ||
          keyboard.isAltPressed ||
          keyboard.isMetaPressed) {
        return KeyEventResult.ignored;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        onSeekRelative(const Duration(seconds: -5));
      } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        onSeekRelative(const Duration(seconds: 5));
      } else if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.space) {
        onTogglePlayback();
      } else if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.keyF &&
          onFullscreen != null) {
        onFullscreen!();
      } else if (event.logicalKey == LogicalKeyboardKey.escape &&
          onDismiss != null) {
        onDismiss!();
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    },
    child: child,
  );
}

/// 工作台已导入的视频信息；取帧沿用 Bridge 的只读缩略图接口。
class StudioVideoFramePreview {
  const StudioVideoFramePreview({
    required this.videoKey,
    required this.frameTotal,
    required this.loadFrame,
  });

  final String videoKey;
  final int frameTotal;
  final Future<Uint8List> Function(int) loadFrame;

  int frameAt(int milliseconds, Duration duration) =>
      duration.inMilliseconds <= 0 || frameTotal <= 1
      ? 0
      : (milliseconds * frameTotal ~/ duration.inMilliseconds).clamp(
          0,
          frameTotal - 1,
        );
}

/// 内嵌、独立全屏与视频对比共用的响应式播放控制条。
class StudioVideoControls extends StatefulWidget {
  const StudioVideoControls({
    required this.position,
    required this.duration,
    required this.playing,
    required this.onTogglePlayback,
    required this.onSeek,
    this.onFullscreen,
    this.fullscreen = false,
    this.enabled = true,
    this.framePreview,
    super.key,
  });

  final Duration position;
  final Duration duration;
  final bool playing;
  final VoidCallback onTogglePlayback;
  final Future<void> Function(Duration) onSeek;
  final VoidCallback? onFullscreen;
  final bool fullscreen;
  final bool enabled;
  final StudioVideoFramePreview? framePreview;

  @override
  State<StudioVideoControls> createState() => _StudioVideoControlsState();
}

class _StudioVideoControlsState extends State<StudioVideoControls> {
  Duration? _dragPosition;

  @override
  void didUpdateWidget(covariant StudioVideoControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.framePreview?.videoKey != widget.framePreview?.videoKey ||
        !widget.enabled) {
      _dragPosition = null;
    }
  }

  Future<void> _seek(Duration value) async {
    final target = clampStudioVideoPosition(value, widget.duration);
    setState(() => _dragPosition = target);
    try {
      await widget.onSeek(target);
    } finally {
      if (mounted) setState(() => _dragPosition = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final position = clampStudioVideoPosition(
      _dragPosition ?? widget.position,
      widget.duration,
    );
    final hasDuration = widget.duration > Duration.zero;
    final canSeek = widget.enabled && hasDuration;
    final preview = widget.framePreview;
    final canInspect = preview != null && preview.frameTotal > 0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 360;
        Widget button(IconData icon, String tooltip, VoidCallback? onPressed) =>
            IconButton(
              onPressed: onPressed,
              tooltip: tooltip,
              icon: Icon(icon, size: 20),
              style: IconButton.styleFrom(
                foregroundColor: Colors.white,
                disabledForegroundColor: Colors.white38,
                minimumSize: const Size(32, 32),
                padding: const EdgeInsets.all(6),
                visualDensity: VisualDensity.compact,
              ),
            );
        return Material(
          type: MaterialType.transparency,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      button(
                        widget.playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        widget.playing ? '暂停（Space）' : '播放（Space）',
                        widget.enabled ? widget.onTogglePlayback : null,
                      ),
                      if (wide)
                        button(
                          Icons.replay_5_rounded,
                          '快退 5 秒（←）',
                          canSeek
                              ? () =>
                                    _seek(position - const Duration(seconds: 5))
                              : null,
                        ),
                      Expanded(
                        child: Text(
                          '${formatStudioVideoTime(position)} / ${formatStudioVideoTime(widget.duration)}',
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            height: 1,
                          ),
                        ),
                      ),
                      if (wide)
                        button(
                          Icons.forward_5_rounded,
                          '快进 5 秒（→）',
                          canSeek
                              ? () =>
                                    _seek(position + const Duration(seconds: 5))
                              : null,
                        ),
                      if (widget.onFullscreen != null)
                        button(
                          widget.fullscreen
                              ? Icons.fullscreen_exit_rounded
                              : Icons.fullscreen_rounded,
                          widget.fullscreen ? '退出全屏（Esc）' : '全屏播放',
                          widget.onFullscreen,
                        ),
                    ],
                  ),
                  SizedBox(
                    height: 20,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: Colors.white,
                        inactiveTrackColor: Colors.white30,
                        thumbColor: Colors.white,
                        overlayColor: Colors.white12,
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 5,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 10,
                        ),
                      ),
                      child: canInspect
                          ? StudioFrameScrubber(
                              videoKey: preview.videoKey,
                              value: position.inMilliseconds.toDouble(),
                              max: hasDuration
                                  ? widget.duration.inMilliseconds
                                  : 1,
                              height: 20,
                              horizontalPadding: 10,
                              discrete: false,
                              sliderKey: const ValueKey(
                                'studio-video-progress',
                              ),
                              formatLabel: (value) => formatStudioVideoTime(
                                Duration(milliseconds: value),
                              ),
                              loadFrame: (value) => preview.loadFrame(
                                preview.frameAt(value, widget.duration),
                              ),
                              onChanged: canSeek
                                  ? (value) => setState(
                                      () => _dragPosition = Duration(
                                        milliseconds: value.round(),
                                      ),
                                    )
                                  : null,
                              onChangeEnd: canSeek
                                  ? (value) => _seek(
                                      Duration(milliseconds: value.round()),
                                    )
                                  : null,
                            )
                          : Slider(
                              key: const ValueKey('studio-video-progress'),
                              value: hasDuration
                                  ? position.inMilliseconds.toDouble()
                                  : 0,
                              max: hasDuration
                                  ? widget.duration.inMilliseconds.toDouble()
                                  : 1,
                              label: formatStudioVideoTime(position),
                              semanticFormatterCallback: (value) =>
                                  formatStudioVideoTime(
                                    Duration(milliseconds: value.round()),
                                  ),
                              onChanged: canSeek
                                  ? (value) => setState(
                                      () => _dragPosition = Duration(
                                        milliseconds: value.round(),
                                      ),
                                    )
                                  : null,
                              onChangeEnd: canSeek
                                  ? (value) => _seek(
                                      Duration(milliseconds: value.round()),
                                    )
                                  : null,
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
