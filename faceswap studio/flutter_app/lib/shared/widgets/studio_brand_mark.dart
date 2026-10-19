import 'package:flutter/material.dart';

/// 所有应用品牌入口共用同一份透明标志，遵循系统减少动画偏好。
class StudioBrandMark extends StatelessWidget {
  const StudioBrandMark({this.size = 52, this.animate = true, super.key});

  final double size;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final moving = animate && !MediaQuery.disableAnimationsOf(context);
    return Image.asset(
      moving
          ? 'assets/branding/studio-mark-animated.webp'
          : 'assets/branding/studio-mark.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      semanticLabel: 'FaceSwap Studio',
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
    );
  }
}
