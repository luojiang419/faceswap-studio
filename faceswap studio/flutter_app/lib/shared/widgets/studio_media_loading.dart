import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

enum StudioMediaLoadingKind { face, video }

/// 格子内部的等待反馈。动画只重绘独立区域，数字仅由真实任务进度驱动。
class StudioMediaLoading extends StatefulWidget {
  const StudioMediaLoading({
    super.key,
    required this.kind,
    this.processed = 0,
    this.total = 1,
    this.recognized = 0,
    this.skipped = 0,
    this.message,
  });

  final StudioMediaLoadingKind kind;
  final int processed;
  final int total;
  final int recognized;
  final int skipped;
  final String? message;

  @override
  State<StudioMediaLoading> createState() => _StudioMediaLoadingState();
}

class _StudioMediaLoadingState extends State<StudioMediaLoading>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) || !TickerMode.of(context)) {
      _motion.stop();
      _motion.value = .35;
    } else {
      _motion.repeat();
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final face = widget.kind == StudioMediaLoadingKind.face;
    final title = widget.message ?? (face ? '正在识别人脸' : '视频加载中');
    final processed = widget.processed.clamp(0, widget.total);
    final detail = face && widget.total > 1
        ? '已识别 $processed 张 / 共 ${widget.total} 张'
        : (face ? '正在检测与裁切，请稍候' : '正在准备画面与播放信息');
    return Semantics(
      liveRegion: true,
      label: '$title，$detail',
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final small = constraints.maxHeight < 170;
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!small)
                      Flexible(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: 300,
                            maxHeight: 180,
                          ),
                          child: AspectRatio(
                            aspectRatio: 16 / 9,
                            child: RepaintBoundary(
                              child: face
                                  ? CustomPaint(
                                      painter: _FaceParticles(
                                        _motion,
                                        theme.colorScheme.primary,
                                      ),
                                    )
                                  : AnimatedBuilder(
                                      animation: _motion,
                                      child: SvgPicture.asset(
                                        'assets/loading/video_loading.svg',
                                        excludeFromSemantics: true,
                                      ),
                                      builder: (_, child) =>
                                          Transform.translate(
                                            offset: Offset(
                                              0,
                                              math.sin(
                                                    _motion.value * math.pi * 2,
                                                  ) *
                                                  3,
                                            ),
                                            child: Stack(
                                              fit: StackFit.expand,
                                              children: [
                                                child!,
                                                CustomPaint(
                                                  painter: _VideoScan(
                                                    _motion.value,
                                                    theme.colorScheme.primary,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      detail,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (face && widget.total > 1) ...[
                      const SizedBox(height: 14),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 190),
                        child: LinearProgressIndicator(
                          value: processed / widget.total,
                          minHeight: 3,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ],
                    if (widget.skipped > 0 && !small) ...[
                      const SizedBox(height: 10),
                      Text(
                        '${widget.recognized} 张检测到人脸 · ${widget.skipped} 张未检测到可用人脸',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _FaceParticles extends CustomPainter {
  _FaceParticles(this.motion, this.color) : super(repaint: motion);
  final Animation<double> motion;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 320, size.height / 180);
    final t = motion.value * math.pi * 2;
    final glow = Paint()
      ..shader = RadialGradient(
        colors: [color.withValues(alpha: .14), color.withValues(alpha: 0)],
      ).createShader(const Rect.fromLTWH(10, 0, 300, 180));
    canvas.drawOval(const Rect.fromLTWH(10, 0, 300, 180), glow);
    final points = <Offset>[];
    // 轮廓、双眼、鼻梁与嘴唇组成可辨识的点阵人脸。
    for (var i = 0; i < 40; i++) {
      final a = i * math.pi * 2 / 40;
      points.add(
        Offset(math.cos(a) * 31 * (1 - .12 * math.sin(a)), math.sin(a) * 48),
      );
    }
    for (final x in [-12.0, 12.0]) {
      for (var i = 0; i < 8; i++) {
        final a = i * math.pi * 2 / 8;
        points.add(Offset(x + math.cos(a) * 7, -10 + math.sin(a) * 3));
      }
    }
    for (var i = 0; i < 7; i++) {
      points.add(Offset(math.sin(i * .6) * 4, -3 + i * 2.5));
    }
    for (var i = 0; i < 12; i++) {
      final a = i * math.pi * 2 / 12;
      points.add(Offset(math.cos(a) * 12, 25 + math.sin(a) * 4));
    }
    final ink = Paint();
    for (final centerX in [91.0, 229.0]) {
      for (var i = 0; i < points.length; i++) {
        final pulse = .5 + .5 * math.sin(t + i * .23);
        final point = points[i] + Offset(centerX, 86);
        ink.color = color.withValues(alpha: .28 + pulse * .48);
        canvas.drawCircle(point, 1.1 + pulse * .5, ink);
      }
      ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = .7
        ..color = color.withValues(alpha: .12);
      canvas.drawOval(
        Rect.fromCenter(center: Offset(centerX, 86), width: 88, height: 126),
        ink,
      );
      ink.style = PaintingStyle.fill;
    }
    for (var i = 0; i < 44; i++) {
      final p = (motion.value + i / 44) % 1;
      final eased = .5 - .5 * math.cos(p * math.pi);
      final origin = points[(i * 7) % points.length];
      final x = 91 + origin.dx + eased * 138;
      final y =
          86 + origin.dy + math.sin(p * math.pi) * math.sin(i * 2.4 + t) * 16;
      final alpha = math.pow(math.sin(p * math.pi), 2).toDouble();
      ink.color = color.withValues(alpha: alpha * .82);
      canvas.drawCircle(Offset(x, y), 1.2 + alpha, ink);
      ink.color = color.withValues(alpha: alpha * .12);
      canvas.drawCircle(Offset(x, y), 4.5, ink);
    }
    ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: .6);
    canvas.drawPath(
      Path()
        ..moveTo(146, 149)
        ..lineTo(174, 149)
        ..moveTo(169, 145)
        ..lineTo(174, 149)
        ..lineTo(169, 153),
      ink,
    );
    canvas.drawPath(
      Path()
        ..moveTo(174, 158)
        ..lineTo(146, 158)
        ..moveTo(151, 154)
        ..lineTo(146, 158)
        ..lineTo(151, 162),
      ink,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FaceParticles oldDelegate) =>
      oldDelegate.color != color || oldDelegate.motion != motion;
}

class _VideoScan extends CustomPainter {
  _VideoScan(this.phase, this.color);
  final double phase;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 320, size.height / 180);
    canvas.clipRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(66, 37, 188, 110),
        const Radius.circular(15),
      ),
    );
    final x = 65 + phase * 190;
    canvas.drawRect(
      Rect.fromLTWH(x - 28, 36, 28, 112),
      Paint()
        ..shader = LinearGradient(
          colors: [color.withValues(alpha: 0), color.withValues(alpha: .16)],
        ).createShader(Rect.fromLTWH(x - 28, 36, 28, 112)),
    );
    canvas.drawLine(
      Offset(x, 59),
      Offset(x, 126),
      Paint()
        ..color = color.withValues(alpha: .65)
        ..strokeWidth = 1.3,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _VideoScan oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.color != color;
}
