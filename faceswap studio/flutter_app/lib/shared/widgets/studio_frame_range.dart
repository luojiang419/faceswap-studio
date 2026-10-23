import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 界面 O 点包含该帧；提交给引擎的 end 是排除边界（O + 1）。
class StudioFrameRange extends StatefulWidget {
  const StudioFrameRange({
    super.key,
    required this.total,
    required this.currentFrame,
    required this.start,
    required this.end,
    required this.onChanged,
  });
  final int total;
  final int currentFrame;
  final int? start;
  final int? end;
  final void Function(int? start, int? end)? onChanged;
  @override
  State<StudioFrameRange> createState() => _StudioFrameRangeState();
}

class _StudioFrameRangeState extends State<StudioFrameRange> {
  RangeValues? _drag;
  int get _max => widget.total - 1;
  int get _start => (widget.start ?? 0).clamp(0, _max);
  int get _end => ((widget.end ?? widget.total) - 1).clamp(_start, _max);
  bool get _enabled => widget.onChanged != null && widget.total > 1;
  void _markIn() {
    final value = widget.currentFrame.clamp(0, _max);
    widget.onChanged?.call(value, (_end < value ? value : _end) + 1);
  }

  void _markOut() {
    final value = widget.currentFrame.clamp(0, _max);
    widget.onChanged?.call(_start > value ? value : _start, value + 1);
  }

  @override
  void didUpdateWidget(covariant StudioFrameRange oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.total != widget.total ||
        oldWidget.start != widget.start ||
        oldWidget.end != widget.end) {
      _drag = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.total < 2) return const SizedBox();
    final range = _drag ?? RangeValues(_start.toDouble(), _end.toDouble());
    return CallbackShortcuts(
      bindings: {
        if (_enabled) const SingleActivator(LogicalKeyboardKey.keyI): _markIn,
        if (_enabled) const SingleActivator(LogicalKeyboardKey.keyO): _markOut,
      },
      child: Focus(
        child: Builder(
          builder: (context) => GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => Focus.of(context).requestFocus(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 4,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '片段 I ${range.start.round()} → O ${range.end.round()}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    Tooltip(
                      message: '将当前预览帧设为入点（I）',
                      child: TextButton(
                        key: const ValueKey('clip-mark-in'),
                        onPressed: _enabled ? _markIn : null,
                        child: const Text('I 入点'),
                      ),
                    ),
                    Tooltip(
                      message: '将当前预览帧设为出点，包含该帧（O）',
                      child: TextButton(
                        key: const ValueKey('clip-mark-out'),
                        onPressed: _enabled ? _markOut : null,
                        child: const Text('O 出点'),
                      ),
                    ),
                    TextButton(
                      key: const ValueKey('clip-reset'),
                      onPressed: _enabled
                          ? () => widget.onChanged!(null, null)
                          : null,
                      child: const Text('全片'),
                    ),
                  ],
                ),
                SizedBox(
                  height: 28,
                  child: RangeSlider(
                    key: const ValueKey('clip-range'),
                    values: range,
                    min: 0,
                    max: _max.toDouble(),
                    divisions: _max,
                    labels: RangeLabels(
                      'I ${range.start.round()}',
                      'O ${range.end.round()}',
                    ),
                    onChanged: !_enabled
                        ? null
                        : (value) => setState(() => _drag = value),
                    onChangeEnd: !_enabled
                        ? null
                        : (value) {
                            widget.onChanged!(
                              value.start.round(),
                              value.end.round() + 1,
                            );
                            setState(() => _drag = null);
                          },
                  ),
                ),
                Text(
                  '生成所选 ${range.end.round() - range.start.round() + 1} 帧 · O 点包含该帧',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
