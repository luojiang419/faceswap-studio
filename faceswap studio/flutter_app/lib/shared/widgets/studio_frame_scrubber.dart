import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/theme/studio_depth.dart';
import 'studio_hover_focus.dart';

/// 原视频帧浮层只负责检查位置；正式选帧仍由滑杆的结束回调提交。
class StudioFrameScrubber extends StatefulWidget {
  const StudioFrameScrubber({
    super.key,
    required this.videoKey,
    required this.value,
    required this.max,
    required this.onChanged,
    required this.onChangeEnd,
    required this.loadFrame,
    this.height = 48,
    this.horizontalPadding = 24,
    this.sliderKey,
    this.formatLabel,
    this.discrete = true,
  });

  final String? videoKey;
  final double value;
  final int max;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final Future<Uint8List> Function(int)? loadFrame;
  final double height;
  final double horizontalPadding;
  final Key? sliderKey;
  final String Function(int)? formatLabel;
  final bool discrete;

  @override
  State<StudioFrameScrubber> createState() => _StudioFrameScrubberState();
}

class _StudioFrameScrubberState extends State<StudioFrameScrubber> {
  final _trackKey = GlobalKey();
  final _focusOwner = Object();
  final _cache = <int, Uint8List>{};
  OverlayEntry? _overlay;
  ValueChanged<bool>? _focus;
  Timer? _debounce;
  int? _frame;
  int? _imageFrame;
  Uint8List? _image;
  bool _failed = false;
  bool _reading = false;
  bool _dragging = false;
  int _generation = 0;

  bool get _enabled => widget.onChanged != null && widget.max > 0;
  bool get _canInspect =>
      _enabled && widget.videoKey != null && widget.loadFrame != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _focus = StudioHoverFocus.handlerOf(context, _focusOwner);
    if (!TickerMode.of(context) ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      _hide(deferFocus: true);
    }
  }

  @override
  void didUpdateWidget(covariant StudioFrameScrubber oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.videoKey != oldWidget.videoKey ||
        widget.max != oldWidget.max ||
        !_canInspect) {
      _hide(deferFocus: true);
      _cache.clear();
      _dragging = false;
    }
  }

  @override
  void dispose() {
    _hide(deferFocus: true);
    super.dispose();
  }

  void _hide({bool deferFocus = false}) {
    _debounce?.cancel();
    _generation++;
    _frame = null;
    _image = null;
    _imageFrame = null;
    _overlay?.remove();
    _overlay?.dispose();
    _overlay = null;
    final focus = _focus;
    if (deferFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_overlay == null) focus?.call(false);
      });
    } else {
      focus?.call(false);
    }
  }

  void _inspect(int frame) {
    if (!_canInspect) return;
    frame = frame.clamp(0, widget.max);
    if (_frame == frame && _overlay != null) return;
    _frame = frame;
    final cached = _cache.remove(frame);
    if (cached != null) {
      _cache[frame] = cached;
      _image = cached;
      _imageFrame = frame;
    }
    _failed = false;
    if (_overlay == null) {
      _overlay = OverlayEntry(builder: _buildOverlay);
      Overlay.of(context, rootOverlay: true).insert(_overlay!);
      _focus?.call(true);
    } else {
      _overlay!.markNeedsBuild();
    }
    // 持续移动也按间隔读取最新帧，不能每次移动都重置计时而一直等不到图。
    if (_imageFrame != frame && !(_debounce?.isActive ?? false)) {
      _debounce = Timer(const Duration(milliseconds: 70), _readLatest);
    }
  }

  Future<void> _readLatest() async {
    if (_reading ||
        _frame == null ||
        _overlay == null ||
        _imageFrame == _frame) {
      return;
    }
    final frame = _frame!;
    final generation = _generation;
    final video = widget.videoKey;
    _reading = true;
    try {
      final image = await widget.loadFrame!(frame);
      if (!mounted || video != widget.videoKey || generation != _generation) {
        return;
      }
      if (image.isEmpty) throw StateError('空视频帧');
      _cache[frame] = image;
      while (_cache.length > 36) {
        _cache.remove(_cache.keys.first);
      }
      // 持续搓擦时保留最近完成的画面及真实帧号，避免一直闪烁加载占位。
      // 已命中当前帧缓存时，不让较旧请求回退画面。
      if (_imageFrame != _frame || _frame == frame) {
        _image = image;
        _imageFrame = frame;
      }
    } catch (_) {
      if (mounted && generation == _generation && _frame == frame) {
        _failed = true;
      }
    } finally {
      _reading = false;
      if (mounted && _overlay != null) {
        _overlay!.markNeedsBuild();
        // 慢请求完成后直接读取最新位置，不积压中间每一帧。
        if (_frame != frame || generation != _generation) {
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 70), _readLatest);
        }
      }
    }
  }

  void _hover(Offset position) {
    if (_dragging || !_canInspect) return;
    final box = _trackKey.currentContext?.findRenderObject() as RenderBox?;
    final padding = widget.horizontalPadding;
    if (box == null || box.size.width <= padding * 2) return;
    var fraction = ((position.dx - padding) / (box.size.width - padding * 2))
        .clamp(0.0, 1.0);
    if (Directionality.of(context) == TextDirection.rtl) {
      fraction = 1 - fraction;
    }
    _inspect((fraction * widget.max).round());
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final track = _trackKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context, rootOverlay: true).context.findRenderObject()
            as RenderBox?;
    if (track == null || overlay == null || _frame == null) {
      return const SizedBox();
    }
    final origin = overlay.globalToLocal(track.localToGlobal(Offset.zero));
    final width = math.min(192.0, overlay.size.width - 16);
    final height = math.min(148.0, overlay.size.height - 16);
    var fraction = _frame! / widget.max;
    if (Directionality.of(context) == TextDirection.rtl) {
      fraction = 1 - fraction;
    }
    final padding = widget.horizontalPadding;
    final center =
        origin.dx + padding + fraction * (track.size.width - padding * 2);
    final left = (center - width / 2).clamp(
      8.0,
      math.max(8.0, overlay.size.width - width - 8),
    );
    final top = (origin.dy - height - 8).clamp(
      8.0,
      math.max(8.0, overlay.size.height - height - 8),
    );
    final theme = Theme.of(context);
    return Positioned(
      left: left.toDouble(),
      top: top.toDouble(),
      width: width,
      height: height,
      child: IgnorePointer(
        child: Theme(
          data: theme,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 240),
            curve: studioHoverFocusCurve,
            builder: (_, value, child) => Opacity(
              opacity: value.clamp(0, 1),
              child: Transform.scale(scale: .94 + .06 * value, child: child),
            ),
            child: Container(
              key: const ValueKey('frame-scrub-thumbnail'),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: StudioDepth.borderColor(context)),
                boxShadow: StudioDepth.shadows(context, floating: true),
              ),
              child: Column(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox.expand(
                        child: ColoredBox(
                          color: theme.colorScheme.surfaceContainer,
                          child: _image != null
                              ? Image.memory(
                                  _image!,
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, _, _) => const Center(
                                    child: Icon(Icons.broken_image_outlined),
                                  ),
                                )
                              : Center(
                                  child: _failed
                                      ? const Text('此帧暂不可用')
                                      : const SizedBox.square(
                                          dimension: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        ),
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    height: 20,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.formatLabel?.call(_imageFrame ?? _frame!) ??
                                '帧 ${_imageFrame ?? _frame} / ${widget.max}',
                            style: theme.textTheme.labelSmall,
                          ),
                          if (_image != null && _imageFrame != _frame) ...[
                            const SizedBox(width: 6),
                            _failed
                                ? const Icon(Icons.error_outline, size: 12)
                                : const SizedBox.square(
                                    dimension: 10,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1,
                                    ),
                                  ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (event) => _hover(event.localPosition),
    onHover: (event) => _hover(event.localPosition),
    onExit: (_) {
      if (!_dragging) _hide();
    },
    child: Listener(
      onPointerCancel: (_) {
        _dragging = false;
        _hide();
      },
      child: SizedBox(
        key: _trackKey,
        height: widget.height,
        child: SliderTheme(
          data: SliderTheme.of(
            context,
          ).copyWith(showValueIndicator: ShowValueIndicator.never),
          child: Slider(
            key: widget.sliderKey,
            padding: EdgeInsets.symmetric(horizontal: widget.horizontalPadding),
            value: widget.value.clamp(0, widget.max.toDouble()),
            min: 0,
            max: widget.max.toDouble(),
            divisions: widget.discrete ? math.max(1, widget.max) : null,
            semanticFormatterCallback: (value) =>
                widget.formatLabel?.call(value.round()) ?? '帧 ${value.round()}',
            onChangeStart: !_enabled
                ? null
                : (value) {
                    _dragging = true;
                    _inspect(value.round());
                  },
            onChanged: !_enabled
                ? null
                : (value) {
                    widget.onChanged!(value);
                    _inspect(value.round());
                  },
            onChangeEnd: !_enabled
                ? null
                : (value) {
                    _dragging = false;
                    _hide();
                    widget.onChangeEnd?.call(value);
                  },
          ),
        ),
      ),
    ),
  );
}
