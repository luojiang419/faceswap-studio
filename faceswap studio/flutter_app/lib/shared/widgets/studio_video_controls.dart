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

  @override
  State<StudioVideoControls> createState() => _StudioVideoControlsState();
}

class _StudioVideoControlsState extends State<StudioVideoControls> {
  Duration? _dragPosition;

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
                      child: Slider(
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
                            ? (value) =>
                                  _seek(Duration(milliseconds: value.round()))
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
