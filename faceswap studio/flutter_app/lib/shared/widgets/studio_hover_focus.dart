import 'dart:ui' as ui;

import 'package:flutter/material.dart';

const studioHoverFocusCurve = Cubic(0.22, 1, 0.36, 1);

/// 页面内容统一虚化；Tooltip 的 Overlay 仍在页面之上清晰绘制。
class StudioHoverFocus extends StatefulWidget {
  const StudioHoverFocus({super.key, required this.child});

  final Widget child;

  static ValueChanged<bool>? handlerOf(BuildContext context, Object owner) {
    final state = context.findAncestorStateOfType<_StudioHoverFocusState>();
    return state == null ? null : (active) => state.setActive(owner, active);
  }

  @override
  State<StudioHoverFocus> createState() => _StudioHoverFocusState();
}

class _StudioHoverFocusState extends State<StudioHoverFocus> {
  final Set<Object> _owners = {};

  void setActive(Object owner, bool active) {
    if (!mounted) return;
    final changed = active ? _owners.add(owner) : _owners.remove(owner);
    if (changed) setState(() {});
  }

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    key: const ValueKey('studio-page-focus'),
    tween: Tween(begin: 0, end: _owners.isEmpty ? 0 : 2),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 240),
    curve: studioHoverFocusCurve,
    child: widget.child,
    builder: (context, sigma, child) => ClipRect(
      child: ImageFiltered(
        key: const ValueKey('studio-page-blur'),
        imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        enabled: sigma > 0,
        child: child,
      ),
    ),
  );
}
