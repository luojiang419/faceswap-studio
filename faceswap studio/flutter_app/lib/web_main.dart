import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:faceswap_studio/app/theme/studio_theme.dart';
import 'package:faceswap_studio/features/workspace/presentation/workspace_options_panel.dart';
import 'package:faceswap_studio/shared/services/bridge_client.dart';
import 'package:faceswap_studio/shared/widgets/studio_brand_mark.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FaceSwapStudioWebApp());
}

String _basename(String value) {
  final parts = value.split(RegExp(r'[\\/]')).where((item) => item.isNotEmpty);
  return parts.isEmpty ? value : parts.last;
}

Future<String?> _showPersonaNameDialog(BuildContext context) async {
  final controller = TextEditingController();
  try {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('保存人物形象'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '人物形象名称',
            hintText: '例如：主播正面形象',
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) {
            final name = controller.text.trim();
            if (name.isNotEmpty) {
              Navigator.of(context).pop(name);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                Navigator.of(context).pop(name);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    return result;
  } finally {
    controller.dispose();
  }
}

Future<bool> _confirmQueueTaskCancelDialog(
  BuildContext context, {
  required String jobId,
  required bool isActive,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(isActive ? '取消运行中任务' : '取消队列任务'),
      content: Text(
        isActive
            ? '确定取消正在生成的任务 $jobId 吗？已生成的作品文件会保留。'
            : '确定取消队列任务 $jobId 吗？此操作会将任务从生成队列移除。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('返回'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('取消任务'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

Future<bool> _confirmWorkDeleteDialog(
  BuildContext context, {
  required String label,
  required bool isQueueRecord,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(isQueueRecord ? '删除队列作品记录' : '删除作品'),
      content: Text(
        isQueueRecord
            ? '确定删除队列作品记录 $label 吗？此操作会把该记录从作品管理中移除。'
            : '确定删除作品 $label 吗？这会删除已生成的作品文件。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('返回'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('确认删除'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

Future<void> _showWorkImagePreviewDialog(
  BuildContext context, {
  required String title,
  required String imageUrl,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960, maxHeight: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭预览',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: ColoredBox(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.36),
                    child: InteractiveViewer(
                      minScale: 0.5,
                      maxScale: 4,
                      child: Image.network(
                        imageUrl,
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) => SizedBox(
                          width: 520,
                          height: 320,
                          child: Icon(
                            Icons.broken_image_outlined,
                            size: 48,
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
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

Future<void> _showWebImageViewer(
  BuildContext context, {
  required String title,
  String? imageUrl,
  Uint8List? imageBytes,
}) async {
  if (imageBytes == null && (imageUrl == null || imageUrl.isEmpty)) {
    return;
  }
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (context) => _WebImageViewerDialog(
      title: title,
      imageUrl: imageUrl,
      imageBytes: imageBytes,
    ),
  );
}

Future<void> _showWebImageComparisonViewer(
  BuildContext context, {
  required String title,
  required Uint8List beforeImageBytes,
  required Uint8List afterImageBytes,
  required Uint8List resultImageBytes,
  required String beforeLabel,
  required String afterLabel,
  required _WebPreviewComparisonMode initialMode,
  required double initialDivider,
}) async {
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (context) => _WebImageComparisonViewerDialog(
      title: title,
      beforeImageBytes: beforeImageBytes,
      afterImageBytes: afterImageBytes,
      resultImageBytes: resultImageBytes,
      beforeLabel: beforeLabel,
      afterLabel: afterLabel,
      initialMode: initialMode,
      initialDivider: initialDivider,
    ),
  );
}

Future<void> _showWebImageGalleryViewer(
  BuildContext context, {
  required List<_WebImageGalleryItem> items,
  required String title,
}) async {
  if (items.isEmpty) {
    return;
  }
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (context) =>
        _WebImageGalleryViewerDialog(items: items, title: title),
  );
}

Future<void> _showWebMediaViewer(
  BuildContext context, {
  required String title,
  required String mediaUrl,
  required String? mediaType,
}) async {
  if (mediaType == 'video') {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) =>
          _WebVideoViewerDialog(title: title, mediaUrl: mediaUrl),
    );
    return;
  }
  await _showWebImageViewer(context, title: title, imageUrl: mediaUrl);
}

class _WebImageGalleryItem {
  const _WebImageGalleryItem({required this.title, required this.imageUrl});

  final String title;
  final String imageUrl;
}

class _WebDismissViewerIntent extends Intent {
  const _WebDismissViewerIntent();
}

class _WebPreviousViewerItemIntent extends Intent {
  const _WebPreviousViewerItemIntent();
}

class _WebNextViewerItemIntent extends Intent {
  const _WebNextViewerItemIntent();
}

class _WebViewerKeyboardScope extends StatelessWidget {
  const _WebViewerKeyboardScope({
    required this.onDismiss,
    required this.child,
    this.onPrevious,
    this.onNext,
  });

  final VoidCallback onDismiss;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.escape):
            const _WebDismissViewerIntent(),
        if (onPrevious != null)
          const SingleActivator(LogicalKeyboardKey.arrowLeft):
              const _WebPreviousViewerItemIntent(),
        if (onNext != null)
          const SingleActivator(LogicalKeyboardKey.arrowRight):
              const _WebNextViewerItemIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _WebDismissViewerIntent: CallbackAction<_WebDismissViewerIntent>(
            onInvoke: (_) {
              onDismiss();
              return null;
            },
          ),
          if (onPrevious != null)
            _WebPreviousViewerItemIntent:
                CallbackAction<_WebPreviousViewerItemIntent>(
                  onInvoke: (_) {
                    onPrevious!();
                    return null;
                  },
                ),
          if (onNext != null)
            _WebNextViewerItemIntent: CallbackAction<_WebNextViewerItemIntent>(
              onInvoke: (_) {
                onNext!();
                return null;
              },
            ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}

class _WebViewerHintLabel extends StatelessWidget {
  const _WebViewerHintLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _WebImageContent extends StatelessWidget {
  const _WebImageContent({this.imageUrl, this.imageBytes});

  final String? imageUrl;
  final Uint8List? imageBytes;

  @override
  Widget build(BuildContext context) {
    final error = Icon(
      Icons.broken_image_outlined,
      size: 56,
      color: Theme.of(context).colorScheme.error,
    );
    if (imageBytes != null) {
      return Image.memory(
        imageBytes!,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => error,
      );
    }
    return Image.network(
      imageUrl!,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => error,
    );
  }
}

class _WebPreviewComparisonControls extends StatelessWidget {
  const _WebPreviewComparisonControls({
    required this.mode,
    required this.onChanged,
  });

  final _WebPreviewComparisonMode mode;
  final ValueChanged<_WebPreviewComparisonMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<_WebPreviewComparisonMode>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment<_WebPreviewComparisonMode>(
          value: _WebPreviewComparisonMode.result,
          icon: Icon(Icons.image_outlined, size: 18),
          label: Text('结果'),
        ),
        ButtonSegment<_WebPreviewComparisonMode>(
          value: _WebPreviewComparisonMode.wipe,
          icon: Icon(Icons.compare_arrows_rounded, size: 18),
          label: Text('划像'),
        ),
        ButtonSegment<_WebPreviewComparisonMode>(
          value: _WebPreviewComparisonMode.split,
          icon: Icon(Icons.splitscreen_rounded, size: 18),
          label: Text('分屏'),
        ),
      ],
      selected: <_WebPreviewComparisonMode>{mode},
      onSelectionChanged: (selection) => onChanged(selection.first),
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
    );
  }
}

class _WebImageComparisonFrame extends StatelessWidget {
  const _WebImageComparisonFrame({
    required this.beforeImageBytes,
    required this.afterImageBytes,
    required this.resultImageBytes,
    required this.mode,
    required this.divider,
    required this.onDividerChanged,
    required this.beforeLabel,
    required this.afterLabel,
  });

  final Uint8List beforeImageBytes;
  final Uint8List afterImageBytes;
  final Uint8List resultImageBytes;
  final _WebPreviewComparisonMode mode;
  final double divider;
  final ValueChanged<double> onDividerChanged;
  final String beforeLabel;
  final String afterLabel;

  void _updateDivider(BoxConstraints constraints, Offset localPosition) {
    if (constraints.maxWidth <= 0) {
      return;
    }
    onDividerChanged((localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0));
  }

  Widget _image(Uint8List bytes) {
    return Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true);
  }

  @override
  Widget build(BuildContext context) {
    final safeDivider = divider.clamp(0.0, 1.0);
    return switch (mode) {
      _WebPreviewComparisonMode.result => _image(resultImageBytes),
      _WebPreviewComparisonMode.split => Row(
        children: [
          Expanded(
            child: _WebComparisonImagePane(
              image: _image(beforeImageBytes),
              label: beforeLabel,
            ),
          ),
          const SizedBox(width: 1),
          Expanded(
            child: _WebComparisonImagePane(
              image: _image(afterImageBytes),
              label: afterLabel,
            ),
          ),
        ],
      ),
      _WebPreviewComparisonMode.wipe => LayoutBuilder(
        builder: (context, constraints) {
          return MouseRegion(
            cursor: SystemMouseCursors.resizeLeftRight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanDown: (details) =>
                  _updateDivider(constraints, details.localPosition),
              onPanUpdate: (details) =>
                  _updateDivider(constraints, details.localPosition),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _image(afterImageBytes),
                  ClipRect(
                    clipper: _WebComparisonClipper(safeDivider),
                    child: _image(beforeImageBytes),
                  ),
                  Positioned(
                    left: 10,
                    bottom: 10,
                    child: _WebPreviewComparisonLabel(beforeLabel),
                  ),
                  Positioned(
                    right: 10,
                    bottom: 10,
                    child: _WebPreviewComparisonLabel(afterLabel),
                  ),
                  Positioned(
                    left: constraints.maxWidth * safeDivider - 12,
                    top: 0,
                    bottom: 0,
                    child: const _WebComparisonDividerHandle(),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    };
  }
}

class _WebComparisonImagePane extends StatelessWidget {
  const _WebComparisonImagePane({required this.image, required this.label});

  final Widget image;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        image,
        Positioned(
          left: 10,
          bottom: 10,
          child: _WebPreviewComparisonLabel(label),
        ),
      ],
    );
  }
}

class _WebComparisonClipper extends CustomClipper<Rect> {
  const _WebComparisonClipper(this.divider);

  final double divider;

  @override
  Rect getClip(Size size) {
    return Rect.fromLTWH(0, 0, size.width * divider, size.height);
  }

  @override
  bool shouldReclip(covariant _WebComparisonClipper oldClipper) {
    return oldClipper.divider != divider;
  }
}

class _WebComparisonDividerHandle extends StatelessWidget {
  const _WebComparisonDividerHandle();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 24,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(width: 2, color: Colors.white.withValues(alpha: 0.92)),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(999),
              boxShadow: const [
                BoxShadow(
                  blurRadius: 10,
                  color: Colors.black38,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: const Padding(
              padding: EdgeInsets.all(5),
              child: Icon(
                Icons.drag_indicator_rounded,
                size: 16,
                color: Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WebPreviewComparisonLabel extends StatelessWidget {
  const _WebPreviewComparisonLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: Colors.black.withValues(alpha: 0.58),
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

class _WebImageViewerDialog extends StatelessWidget {
  const _WebImageViewerDialog({
    required this.title,
    this.imageUrl,
    this.imageBytes,
  });

  final String title;
  final String? imageUrl;
  final Uint8List? imageBytes;

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: _WebViewerKeyboardScope(
        onDismiss: () => Navigator.of(context).pop(),
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 78, 24, 24),
                child: InteractiveViewer(
                  minScale: 0.25,
                  maxScale: 8,
                  boundaryMargin: const EdgeInsets.all(120),
                  child: Center(
                    child: _WebImageContent(
                      imageUrl: imageUrl,
                      imageBytes: imageBytes,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 24,
              left: 24,
              child: _WebViewerHintLabel(label: '$title · Esc 退出'),
            ),
            Positioned(
              top: 24,
              right: 24,
              child: IconButton.filledTonal(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
                tooltip: '关闭',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WebImageComparisonViewerDialog extends StatefulWidget {
  const _WebImageComparisonViewerDialog({
    required this.title,
    required this.beforeImageBytes,
    required this.afterImageBytes,
    required this.resultImageBytes,
    required this.beforeLabel,
    required this.afterLabel,
    required this.initialMode,
    required this.initialDivider,
  });

  final String title;
  final Uint8List beforeImageBytes;
  final Uint8List afterImageBytes;
  final Uint8List resultImageBytes;
  final String beforeLabel;
  final String afterLabel;
  final _WebPreviewComparisonMode initialMode;
  final double initialDivider;

  @override
  State<_WebImageComparisonViewerDialog> createState() =>
      _WebImageComparisonViewerDialogState();
}

class _WebImageComparisonViewerDialogState
    extends State<_WebImageComparisonViewerDialog> {
  late _WebPreviewComparisonMode _mode;
  late double _divider;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    _divider = widget.initialDivider.clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: _WebViewerKeyboardScope(
        onDismiss: () => Navigator.of(context).pop(),
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 126, 24, 24),
                child: _WebImageComparisonFrame(
                  beforeImageBytes: widget.beforeImageBytes,
                  afterImageBytes: widget.afterImageBytes,
                  resultImageBytes: widget.resultImageBytes,
                  mode: _mode,
                  divider: _divider,
                  onDividerChanged: (value) {
                    setState(() {
                      _divider = value;
                    });
                  },
                  beforeLabel: widget.beforeLabel,
                  afterLabel: widget.afterLabel,
                ),
              ),
            ),
            Positioned(
              top: 24,
              left: 24,
              child: _WebViewerHintLabel(
                label: '${widget.title} · 对比预览 · Esc 退出',
              ),
            ),
            Positioned(
              top: 70,
              left: 24,
              right: 24,
              child: Center(
                child: Material(
                  color: Colors.transparent,
                  child: _WebPreviewComparisonControls(
                    mode: _mode,
                    onChanged: (mode) {
                      setState(() {
                        _mode = mode;
                      });
                    },
                  ),
                ),
              ),
            ),
            Positioned(
              top: 24,
              right: 24,
              child: IconButton.filledTonal(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
                tooltip: '关闭',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WebImageGalleryViewerDialog extends StatefulWidget {
  const _WebImageGalleryViewerDialog({
    required this.items,
    required this.title,
  });

  final List<_WebImageGalleryItem> items;
  final String title;

  @override
  State<_WebImageGalleryViewerDialog> createState() =>
      _WebImageGalleryViewerDialogState();
}

class _WebImageGalleryViewerDialogState
    extends State<_WebImageGalleryViewerDialog> {
  int _currentIndex = 0;

  void _step(int delta) {
    if (widget.items.length <= 1) {
      return;
    }
    setState(() {
      _currentIndex =
          (_currentIndex + delta + widget.items.length) % widget.items.length;
    });
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.items[_currentIndex];
    final hasMultiple = widget.items.length > 1;
    final label = hasMultiple
        ? '${widget.title} ${_currentIndex + 1}/${widget.items.length} · ←/→ 切换 · Esc 退出'
        : '${widget.title} · Esc 退出';
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: _WebViewerKeyboardScope(
        onDismiss: () => Navigator.of(context).pop(),
        onPrevious: hasMultiple ? () => _step(-1) : null,
        onNext: hasMultiple ? () => _step(1) : null,
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 78, 24, 24),
                child: InteractiveViewer(
                  key: ValueKey<String>(current.imageUrl),
                  minScale: 0.25,
                  maxScale: 8,
                  boundaryMargin: const EdgeInsets.all(120),
                  child: Center(
                    child: _WebImageContent(imageUrl: current.imageUrl),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 24,
              left: 24,
              child: _WebViewerHintLabel(label: label),
            ),
            Positioned(
              left: 24,
              bottom: 24,
              right: 24,
              child: Center(child: _WebViewerHintLabel(label: current.title)),
            ),
            Positioned(
              top: 24,
              right: 24,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasMultiple) ...[
                    IconButton.filledTonal(
                      onPressed: () => _step(-1),
                      icon: const Icon(Icons.chevron_left_rounded),
                      tooltip: '上一张',
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      onPressed: () => _step(1),
                      icon: const Icon(Icons.chevron_right_rounded),
                      tooltip: '下一张',
                    ),
                    const SizedBox(width: 8),
                  ],
                  IconButton.filledTonal(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                    tooltip: '关闭',
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

class _WebVideoViewerDialog extends StatelessWidget {
  const _WebVideoViewerDialog({required this.title, required this.mediaUrl});

  final String title;
  final String mediaUrl;

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: _WebViewerKeyboardScope(
        onDismiss: () => Navigator.of(context).pop(),
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 78, 24, 24),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _WebNativeVideo(src: mediaUrl),
                ),
              ),
            ),
            Positioned(
              top: 24,
              left: 24,
              child: _WebViewerHintLabel(label: '$title · Esc 退出'),
            ),
            Positioned(
              top: 24,
              right: 24,
              child: IconButton.filledTonal(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
                tooltip: '关闭',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class FaceSwapStudioWebApp extends StatelessWidget {
  const FaceSwapStudioWebApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FaceSwap Studio Web 工作台',
      debugShowCheckedModeBanner: false,
      theme: StudioTheme.light(),
      darkTheme: StudioTheme.dark(),
      themeMode: ThemeMode.dark,
      home: const WebWorkbenchPage(),
    );
  }
}

class WebWorkbenchPage extends StatefulWidget {
  const WebWorkbenchPage({super.key});

  @override
  State<WebWorkbenchPage> createState() => _WebWorkbenchPageState();
}

enum _WebWorkbenchSideTab { queue, works }

enum _WebWorkbenchMobileTab { workspace, queue, works }

enum _WebWorkMenuAction { copyLink, openDirectory, cancelTask, delete }

enum _WebWorkBrowserCacheState { none, caching, cached }

enum _WebPlaybackMode { output, wipe, split }

enum _WebPreviewComparisonMode { result, wipe, split }

const String _browserMediaCacheName = 'faceswap-studio-web-media-v2';

class _WebWorkbenchPageState extends State<WebWorkbenchPage> {
  static const List<String> _sourceExtensions = <String>[
    'jpg',
    'jpeg',
    'png',
    'webp',
    'bmp',
    'tiff',
    'mp3',
    'wav',
    'aac',
    'flac',
    'ogg',
    'm4a',
    'opus',
  ];
  static const List<String> _targetExtensions = <String>[
    'jpg',
    'jpeg',
    'png',
    'webp',
    'bmp',
    'tiff',
    'mp4',
    'mov',
    'mkv',
    'avi',
    'webm',
    'wmv',
    'mpeg',
    'm4v',
  ];

  final BridgeClient _client = BridgeClient();
  Timer? _queuePoller;

  bool _loading = true;
  bool _busy = false;
  bool _previewBusy = false;
  String _message = '正在连接 Bridge...';
  Map<String, dynamic> _workspace = const <String, dynamic>{};
  _WebWorkspacePreviewResult? _previewResult;
  List<Map<String, dynamic>> _queueTasks = const <Map<String, dynamic>>[];
  Map<String, dynamic> _queueRunner = const <String, dynamic>{};
  List<_WebWorkItem> _works = const <_WebWorkItem>[];
  String _worksOutputRoot = '';
  final Set<String> _browserCachedWorkIds = <String>{};
  final Set<String> _browserCachingWorkIds = <String>{};
  final Set<String> _browserCachedTaskIds = <String>{};
  final Set<String> _browserCachingTaskIds = <String>{};
  WorkspaceOptionsSchema? _optionsSchema;
  WorkspaceOptionsState _optionsState = const WorkspaceOptionsState.empty();
  double? _previewFrameSliderValue;
  _WebPreviewComparisonMode _previewComparisonMode =
      _WebPreviewComparisonMode.wipe;
  double _previewComparisonDivider = 0.5;
  _WebWorkbenchSideTab _sideTab = _WebWorkbenchSideTab.queue;
  _WebWorkbenchMobileTab _mobileTab = _WebWorkbenchMobileTab.workspace;
  bool _worksLoading = true;

  bool get _canSubmit =>
      _workspace['can_submit'] == true && !_loading && !_busy && !_previewBusy;

  @override
  void initState() {
    super.initState();
    _loadAll();
    _queuePoller = Timer.periodic(
      const Duration(seconds: 4),
      (_) => unawaited(_refreshSidePanels(silent: true)),
    );
  }

  @override
  void dispose() {
    _queuePoller?.cancel();
    super.dispose();
  }

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _message = '正在同步工作台状态...';
    });
    try {
      final results = await Future.wait<dynamic>([
        _client.getWorkspaceDraft(),
        _client.getWorkspaceOptionsSchema(),
        _client.getWorkspaceOptions(),
        _client.getQueueTasks(),
        _client.getWorks(),
      ]);
      if (!mounted) {
        return;
      }
      setState(() {
        _workspace = (results[0] as Map<String, dynamic>);
        _optionsSchema = WorkspaceOptionsSchema.fromJson(
          results[1] as Map<String, dynamic>,
        );
        _optionsState = WorkspaceOptionsState.fromJson(
          results[2] as Map<String, dynamic>,
        );
        _applyQueueState(results[3] as Map<String, dynamic>);
        _applyWorksState(results[4] as Map<String, dynamic>);
        _message = '已连接 Bridge。可上传源文件和目标文件后预览或加入队列。';
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _message = '连接失败: $error';
        _loading = false;
        _worksLoading = false;
      });
    }
  }

  Future<void> _loadWorkspace({bool silent = false}) async {
    try {
      final workspace = await _client.getWorkspaceDraft();
      if (!mounted) {
        return;
      }
      setState(() {
        _workspace = workspace;
        if (!silent) {
          _message = '工作台状态已刷新。';
        }
      });
    } catch (error) {
      if (!silent && mounted) {
        setState(() {
          _message = '刷新工作台失败: $error';
        });
      }
    }
  }

  Future<void> _loadQueue({bool silent = false}) async {
    try {
      final queue = await _client.getQueueTasks();
      if (!mounted) {
        return;
      }
      setState(() {
        _applyQueueState(queue);
        if (!silent) {
          _message = '队列状态已刷新。';
        }
      });
    } catch (error) {
      if (!silent && mounted) {
        setState(() {
          _message = '刷新队列失败: $error';
        });
      }
    }
  }

  Future<void> _loadWorks({bool silent = false}) async {
    try {
      final works = await _client.getWorks();
      if (!mounted) {
        return;
      }
      setState(() {
        _applyWorksState(works);
        if (!silent) {
          _message = '作品列表已刷新。';
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _worksLoading = false;
        if (!silent) {
          _message = '刷新作品列表失败: $error';
        }
      });
    }
  }

  void _applyQueueState(Map<String, dynamic> queue) {
    _queueTasks = (queue['tasks'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    _queueRunner =
        queue['runner'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    _scheduleQueueBrowserCache();
  }

  void _applyWorksState(Map<String, dynamic> works) {
    _works = (works['items'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(_WebWorkItem.fromJson)
        .toList(growable: false);
    _worksOutputRoot = '${works['output_root'] ?? ''}';
    _worksLoading = false;
    _scheduleWorksBrowserCache();
  }

  void _scheduleWorksBrowserCache() {
    final cacheableItems = _works
        .where(
          (item) =>
              item.canCacheInBrowser &&
              !_browserCachedWorkIds.contains(item.id) &&
              !_browserCachingWorkIds.contains(item.id),
        )
        .toList(growable: false);
    if (cacheableItems.isEmpty) {
      return;
    }
    _browserCachingWorkIds.addAll(cacheableItems.map((item) => item.id));
    unawaited(_cacheWorksInBrowser(cacheableItems));
  }

  Future<void> _cacheWorksInBrowser(List<_WebWorkItem> items) async {
    final savedIds = <String>{};
    try {
      for (final item in items) {
        final cached = await _cacheUrlsInBrowser(
          _workUrlsForBrowserCache(item),
        );
        if (!cached) {
          continue;
        }
        savedIds.add(item.id);
      }
    } catch (_) {
      // Browser cache is best-effort: normal preview and download should continue.
    } finally {
      if (mounted) {
        setState(() {
          _browserCachedWorkIds.addAll(savedIds);
          _browserCachingWorkIds.removeAll(items.map((item) => item.id));
        });
      }
    }
  }

  void _scheduleQueueBrowserCache() {
    final cacheableTasks = _queueTasks
        .where((task) {
          final taskId = '${task['job_id'] ?? ''}';
          return taskId.isNotEmpty &&
              _canPlayQueueTask(task) &&
              !_browserCachedTaskIds.contains(taskId) &&
              !_browserCachingTaskIds.contains(taskId);
        })
        .toList(growable: false);
    if (cacheableTasks.isEmpty) {
      return;
    }
    _browserCachingTaskIds.addAll(
      cacheableTasks.map((task) => '${task['job_id'] ?? ''}'),
    );
    unawaited(_cacheQueueTasksInBrowser(cacheableTasks));
  }

  Future<void> _cacheQueueTasksInBrowser(
    List<Map<String, dynamic>> tasks,
  ) async {
    final savedIds = <String>{};
    try {
      for (final task in tasks) {
        final taskId = '${task['job_id'] ?? ''}';
        final cached = await _cacheUrlsInBrowser(
          _queueTaskUrlsForBrowserCache(task),
        );
        if (cached && taskId.isNotEmpty) {
          savedIds.add(taskId);
        }
      }
    } catch (_) {
      // Browser cache is best-effort: playback falls back to Bridge media URLs.
    } finally {
      if (mounted) {
        setState(() {
          _browserCachedTaskIds.addAll(savedIds);
          _browserCachingTaskIds.removeAll(
            tasks.map((task) => '${task['job_id'] ?? ''}'),
          );
        });
      }
    }
  }

  Future<bool> _cacheUrlsInBrowser(Iterable<String> urls) async {
    final uniqueUrls = urls
        .where((url) => url.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (uniqueUrls.isEmpty) {
      return false;
    }
    try {
      final cache = await web.window.caches.open(_browserMediaCacheName).toDart;
      var allCached = true;
      for (final url in uniqueUrls) {
        try {
          await cache.add(url.toJS).toDart;
        } catch (_) {
          allCached = false;
        }
      }
      return allCached;
    } catch (_) {
      return false;
    }
  }

  List<String> _workUrlsForBrowserCache(_WebWorkItem item) {
    final urls = <String>[];
    final mediaUrl = item.mediaUrl;
    final thumbnailUrl = item.thumbnailUrl;
    if (mediaUrl != null && mediaUrl.isNotEmpty) {
      urls.add(_client.resolveUrl(mediaUrl));
      urls.add(_client.workDownloadUrl(item.id));
    }
    if (thumbnailUrl != null && thumbnailUrl.isNotEmpty) {
      urls.add(_client.resolveUrl(thumbnailUrl));
    }
    return urls;
  }

  List<String> _queueTaskUrlsForBrowserCache(Map<String, dynamic> task) {
    final urls = <String>[];
    void addResolved(Object? value) {
      final url = _resolvedUrl(value);
      if (url != null) {
        urls.add(url);
      }
    }

    addResolved(task['output_media_url']);
    addResolved(task['target_media_url']);
    addResolved(task['output_thumbnail_url']);
    addResolved(task['target_thumbnail_url']);
    addResolved(task['source_thumbnail_url']);
    for (final url in task['source_media_urls'] as List<dynamic>? ?? const []) {
      addResolved(url);
    }
    return urls;
  }

  Future<void> _refreshSidePanels({bool silent = false}) async {
    await Future.wait<void>([
      _loadQueue(silent: silent),
      _loadWorks(silent: silent),
    ]);
  }

  Future<void> _pickSourceFiles() async {
    await _runBusyAction('正在上传源文件...', () async {
      final files = await openFiles(
        acceptedTypeGroups: const <XTypeGroup>[
          XTypeGroup(label: '源文件', extensions: _sourceExtensions),
        ],
      );
      if (files.isEmpty) {
        _message = '已取消上传源文件。';
        return;
      }
      final uploads = <BridgeUploadFile>[];
      for (final file in files) {
        uploads.add(
          BridgeUploadFile(name: file.name, bytes: await file.readAsBytes()),
        );
      }
      final result = await _client.uploadWorkspaceSources(uploads);
      _workspace =
          result['workspace'] as Map<String, dynamic>? ??
          await _client.getWorkspaceDraft();
      _previewResult = null;
      _previewFrameSliderValue = null;
      _message = '${result['message'] ?? '源文件上传完成。'}';
    });
  }

  Future<void> _pickTargetFile() async {
    await _runBusyAction('正在上传目标文件...', () async {
      final file = await openFile(
        acceptedTypeGroups: const <XTypeGroup>[
          XTypeGroup(label: '目标文件', extensions: _targetExtensions),
        ],
      );
      if (file == null) {
        _message = '已取消上传目标文件。';
        return;
      }
      final result = await _client.uploadWorkspaceTarget(
        BridgeUploadFile(name: file.name, bytes: await file.readAsBytes()),
      );
      _workspace =
          result['workspace'] as Map<String, dynamic>? ??
          await _client.getWorkspaceDraft();
      _previewResult = null;
      _previewFrameSliderValue = null;
      _message = '${result['message'] ?? '目标文件上传完成。'}';
    });
  }

  Future<void> _clearSources() async {
    await _runBusyAction('正在清空源文件...', () async {
      _workspace = await _client.clearWorkspaceSourcePaths();
      _previewResult = null;
      _previewFrameSliderValue = null;
      _message = '已清空源文件。';
    });
  }

  Future<void> _clearTarget() async {
    await _runBusyAction('正在清空目标文件...', () async {
      _workspace = await _client.clearWorkspaceTargetPath();
      _previewResult = null;
      _previewFrameSliderValue = null;
      _message = '已清空目标文件。';
    });
  }

  Future<void> _pickPersona() async {
    final persona = await showDialog<_WebPersonaChoice>(
      context: context,
      builder: (context) => _WebPersonaPickerDialog(client: _client),
    );
    if (!mounted || persona == null) {
      return;
    }
    await _runBusyAction('正在加载人物形象...', () async {
      final result = await _client.usePersona(persona.id);
      _workspace =
          result['workspace'] as Map<String, dynamic>? ??
          await _client.getWorkspaceDraft();
      _previewResult = null;
      _previewFrameSliderValue = null;
      _message = '${result['message'] ?? '已加载人物形象。'}';
    });
  }

  Future<void> _savePersona() async {
    final sourcePaths =
        (_workspace['source_paths'] as List<dynamic>? ?? const <dynamic>[])
            .map((item) => '$item')
            .where((item) => item.isNotEmpty && item != 'null')
            .toList(growable: false);
    if (sourcePaths.isEmpty) {
      setState(() {
        _message = '请先准备源图片后再保存人物形象。';
      });
      return;
    }
    final name = await _showPersonaNameDialog(context);
    if (!mounted || name == null) {
      return;
    }
    await _runBusyAction('正在保存人物形象...', () async {
      final result = await _client.savePersona(name);
      _workspace =
          result['workspace'] as Map<String, dynamic>? ??
          await _client.getWorkspaceDraft();
      _message = '${result['message'] ?? '人物形象保存完成。'}';
    });
  }

  Future<void> _updateOptions(
    Map<String, dynamic> payload, {
    bool clearPreview = true,
  }) async {
    await _runBusyAction('正在更新参数...', () async {
      final results = await Future.wait<dynamic>([
        _client.updateWorkspaceOptions(payload),
        _client.getWorkspaceOptionsSchema(),
      ]);
      _optionsState = WorkspaceOptionsState.fromJson(
        results[0] as Map<String, dynamic>,
      );
      _optionsSchema = WorkspaceOptionsSchema.fromJson(
        results[1] as Map<String, dynamic>,
      );
      if (clearPreview) {
        _previewResult = null;
        _previewFrameSliderValue = null;
      }
      _message = '参数已更新。';
    });
  }

  Future<void> _resetOptions() async {
    await _runBusyAction('正在恢复默认参数...', () async {
      final results = await Future.wait<dynamic>([
        _client.resetWorkspaceOptions(),
        _client.getWorkspaceOptionsSchema(),
      ]);
      _optionsState = WorkspaceOptionsState.fromJson(
        results[0] as Map<String, dynamic>,
      );
      _optionsSchema = WorkspaceOptionsSchema.fromJson(
        results[1] as Map<String, dynamic>,
      );
      _previewResult = null;
      _previewFrameSliderValue = null;
      _message = '参数已恢复默认。';
    });
  }

  Future<void> _previewWorkspace() async {
    if (!_canSubmit) {
      return;
    }
    setState(() {
      _previewBusy = true;
      _message = '正在生成预览，请稍候...';
    });
    try {
      final result = await _client.previewWorkspace({
        'source_paths':
            _workspace['source_paths'] as List<dynamic>? ?? const <dynamic>[],
        'target_path': _workspace['target_path'],
        'options': _optionsState.options,
      });
      final workspace =
          result['workspace'] as Map<String, dynamic>? ??
          await _client.getWorkspaceDraft();
      if (!mounted) {
        return;
      }
      setState(() {
        _workspace = workspace;
        _previewFrameSliderValue = null;
        if (result['ok'] == true) {
          _previewResult = _WebWorkspacePreviewResult.fromJson(result);
          final optionsResult = result['options'];
          if (optionsResult is Map<String, dynamic>) {
            _optionsState = WorkspaceOptionsState.fromJson(optionsResult);
          }
          _message = '${result['message'] ?? '预览已更新。'}';
        } else {
          _previewResult = null;
          _previewFrameSliderValue = null;
          _message = '${result['message'] ?? '预览生成失败。'}';
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _previewResult = null;
        _previewFrameSliderValue = null;
        _message = '预览生成失败: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _previewBusy = false;
        });
      }
    }
  }

  Future<void> _previewWorkspaceAtFrame(int frameNumber) async {
    if (_previewBusy || _busy || _loading) {
      return;
    }
    setState(() {
      _busy = true;
      _message = '正在切换预览帧...';
    });
    try {
      final results = await Future.wait<dynamic>([
        _client.updateWorkspaceOptions({'preview_frame_number': frameNumber}),
        _client.getWorkspaceOptionsSchema(),
      ]);
      if (!mounted) {
        return;
      }
      setState(() {
        _optionsState = WorkspaceOptionsState.fromJson(
          results[0] as Map<String, dynamic>,
        );
        _optionsSchema = WorkspaceOptionsSchema.fromJson(
          results[1] as Map<String, dynamic>,
        );
        _message = '预览帧已更新，正在生成新预览。';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _message = '切换预览帧失败: $error';
      });
      return;
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
    if (!mounted) {
      return;
    }
    await _previewWorkspace();
  }

  Future<void> _queueWorkspace() async {
    if (!_canSubmit) {
      return;
    }
    await _runBusyAction('正在加入生成队列...', () async {
      final result = await _client.queueWorkspace();
      _workspace =
          result['workspace'] as Map<String, dynamic>? ??
          await _client.getWorkspaceDraft();
      _previewResult = null;
      _previewFrameSliderValue = null;
      _message = '${result['message'] ?? '已加入队列。'}';
      await _refreshSidePanels(silent: true);
    });
  }

  Future<void> _runWorkspace() async {
    if (!_canSubmit) {
      return;
    }
    await _runBusyAction('正在提交立即生成...', () async {
      final result = await _client.runWorkspace();
      _workspace =
          result['workspace'] as Map<String, dynamic>? ??
          await _client.getWorkspaceDraft();
      _previewResult = null;
      _previewFrameSliderValue = null;
      _message = '${result['message'] ?? '已提交生成。'}';
      await _refreshSidePanels(silent: true);
    });
  }

  Future<void> _runQueue() async {
    await _runBusyAction('正在启动队列...', () async {
      final queue = await _client.runQueue();
      _applyQueueState(queue);
      _message = '队列已启动。';
      await _refreshSidePanels(silent: true);
    });
  }

  Future<void> _clearCompletedQueue() async {
    await _runBusyAction('正在清理已完成任务...', () async {
      final result = await _client.clearCompletedQueueTasks();
      _message = '${result['message'] ?? '已清理完成任务。'}';
      await _refreshSidePanels(silent: true);
    });
  }

  Future<void> _cancelQueueTask(String jobId, {required bool isActive}) async {
    final confirmed = await _confirmQueueTaskCancelDialog(
      context,
      jobId: jobId,
      isActive: isActive,
    );
    if (!mounted || !confirmed) {
      return;
    }
    await _runBusyAction(
      isActive ? '正在取消运行中任务 $jobId...' : '正在取消队列任务 $jobId...',
      () async {
        final queue = await _client.cancelQueueTask(jobId);
        _applyQueueState(queue);
        final ok = queue['ok'] != false;
        _message = '${queue['message'] ?? (ok ? '已取消任务：$jobId' : '取消任务失败。')}';
        await _refreshSidePanels(silent: true);
      },
    );
  }

  Future<void> _deleteQueueTask(String jobId) async {
    await _runBusyAction('正在删除任务 $jobId...', () async {
      final queue = await _client.deleteQueueTask(jobId);
      _applyQueueState(queue);
      _message = '已删除任务：$jobId';
      await _refreshSidePanels(silent: true);
    });
  }

  Future<void> _openWorkDirectory(_WebWorkItem item) async {
    if (!item.canOpenDirectory) {
      setState(() {
        _message = '当前作品还没有可打开的输出目录。';
      });
      return;
    }
    await _runBusyAction('正在打开 ${item.displayName} 所在目录...', () async {
      final result = await _client.openWorkDirectory(item.id);
      final ok = result['ok'] != false;
      _message = '${result['message'] ?? (ok ? '已打开作品所在目录。' : '打开作品目录失败。')}';
    });
  }

  Future<void> _downloadWorkItem(_WebWorkItem item) async {
    if (!item.canDownload) {
      setState(() {
        _message = '当前作品还没有可下载的输出文件。';
      });
      return;
    }
    final url = _client.workDownloadUrl(item.id);
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..download = item.downloadFileName
      ..style.display = 'none';
    web.document.body?.appendChild(anchor);
    anchor.click();
    anchor.remove();
    setState(() {
      _message = '已开始下载：${item.displayName}';
    });
  }

  Future<void> _openQueueTaskPlayback(Map<String, dynamic> task) async {
    final output = _queueTaskOutputMedia(task);
    if (output == null) {
      setState(() {
        _message = '当前任务还没有可播放的生成视频。';
      });
      return;
    }
    final compare = _queueTaskCompareMedia(task, output.mediaType);
    await showDialog<void>(
      context: context,
      builder: (context) => _WebTaskPlaybackDialog(
        title: '${task['job_id'] ?? 'queue-task'}',
        output: output,
        compare: compare,
        resolveMediaUrl: _resolveCachedMediaUrl,
      ),
    );
  }

  bool _canPlayQueueTask(Map<String, dynamic> task) {
    final status = '${task['status'] ?? ''}'.trim().toLowerCase();
    final outputUrl = _resolvedUrl(task['output_media_url']);
    final outputMediaType = '${task['output_media_type'] ?? ''}';
    return status == 'completed' &&
        outputUrl != null &&
        outputMediaType == 'video';
  }

  _WebPlaybackMedia? _queueTaskOutputMedia(Map<String, dynamic> task) {
    final outputUrl = _resolvedUrl(task['output_media_url']);
    final outputMediaType = '${task['output_media_type'] ?? ''}';
    if (outputUrl == null || outputMediaType != 'video') {
      return null;
    }
    return _WebPlaybackMedia(
      label: '生成成片',
      url: outputUrl,
      mediaType: outputMediaType,
    );
  }

  _WebPlaybackMedia? _queueTaskCompareMedia(
    Map<String, dynamic> task,
    String outputMediaType,
  ) {
    final targetUrl = _resolvedUrl(task['target_media_url']);
    final targetMediaType = '${task['target_media_type'] ?? ''}';
    if (targetUrl != null &&
        outputMediaType == 'video' &&
        targetMediaType == outputMediaType) {
      return _WebPlaybackMedia(
        label: '原片',
        url: targetUrl,
        mediaType: targetMediaType,
      );
    }
    return null;
  }

  Future<void> _deleteWorkItem(_WebWorkItem item) async {
    final confirmed = await _confirmWorkDeleteDialog(
      context,
      label: item.displayName,
      isQueueRecord: item.canDeleteQueueTask,
    );
    if (!mounted || !confirmed) {
      return;
    }
    if (item.canDeleteQueueTask) {
      final jobId = item.jobId;
      if (jobId == null || jobId.isEmpty) {
        setState(() {
          _message = '队列任务编号缺失，无法删除。';
        });
        return;
      }
      await _runBusyAction('正在删除队列记录 $jobId...', () async {
        await _client.deleteQueueTask(jobId);
        _message = '已删除队列记录：$jobId';
        await _refreshSidePanels(silent: true);
      });
      return;
    }
    await _runBusyAction('正在删除作品 ${item.displayName}...', () async {
      final works = await _client.deleteWork(item.id);
      _applyWorksState(works);
      _message = '已删除作品：${item.displayName}';
    });
  }

  Future<void> _handleWorkMenuAction(
    _WebWorkItem item,
    _WebWorkMenuAction action,
  ) async {
    switch (action) {
      case _WebWorkMenuAction.copyLink:
        await _copyUrl(item.mediaUrl);
        return;
      case _WebWorkMenuAction.openDirectory:
        await _openWorkDirectory(item);
        return;
      case _WebWorkMenuAction.cancelTask:
        final jobId = item.jobId;
        if (jobId == null || jobId.isEmpty) {
          setState(() {
            _message = '队列任务编号缺失，无法取消。';
          });
          return;
        }
        await _cancelQueueTask(jobId, isActive: item.isActive);
        return;
      case _WebWorkMenuAction.delete:
        await _deleteWorkItem(item);
        return;
    }
  }

  Future<void> _copyUrl(String? url) async {
    if (url == null || url.isEmpty) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: _client.resolveUrl(url)));
    if (!mounted) {
      return;
    }
    setState(() {
      _message = '已复制链接。';
    });
  }

  Future<void> _runBusyAction(
    String busyMessage,
    Future<void> Function() action,
  ) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _message = busyMessage;
    });
    try {
      await action();
    } catch (error) {
      _message = '操作失败: $error';
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  String? _resolvedUrl(Object? value) {
    final text = '$value';
    if (value == null || text.isEmpty || text == 'null') {
      return null;
    }
    return _client.resolveUrl(text);
  }

  List<String> _workspaceStringList(String key) {
    return (_workspace[key] as List<dynamic>? ?? const <dynamic>[])
        .map((item) => '$item')
        .where((item) => item.isNotEmpty && item != 'null')
        .toList(growable: false);
  }

  int _previewFrameNumberOption() {
    final rawValue = _optionsState.options['preview_frame_number'];
    if (rawValue is num) {
      return rawValue.toInt();
    }
    return int.tryParse('$rawValue') ?? 0;
  }

  List<_WebImageGalleryItem> _sourceGalleryItems() {
    final sourcePaths = _workspaceStringList('source_paths');
    final sourceUrls = _workspaceStringList('source_media_urls');
    final items = <_WebImageGalleryItem>[];
    for (var index = 0; index < sourcePaths.length; index += 1) {
      final path = sourcePaths[index];
      final rawUrl = index < sourceUrls.length ? sourceUrls[index] : null;
      final url = _resolvedUrl(rawUrl) ?? _client.mediaUrlForPath(path);
      items.add(_WebImageGalleryItem(title: _basename(path), imageUrl: url));
    }
    return items;
  }

  Future<void> _openSourcePreview() async {
    final items = _sourceGalleryItems();
    if (!mounted || items.isEmpty) {
      return;
    }
    await _showWebImageGalleryViewer(context, items: items, title: '源文件');
  }

  Future<void> _openTargetPreview() async {
    final targetPath = '${_workspace['target_path'] ?? ''}';
    if (!mounted || targetPath.isEmpty || targetPath == 'null') {
      return;
    }
    final targetUrl =
        _resolvedUrl(_workspace['target_media_url']) ??
        _resolvedUrl(_workspace['target_thumbnail_url']) ??
        _client.mediaUrlForPath(targetPath);
    final targetMediaType = _workspace['target_media_type'] as String?;
    await _showWebMediaViewer(
      context,
      title: '目标文件',
      mediaUrl: targetUrl,
      mediaType: targetMediaType,
    );
  }

  Future<void> _openPreviewResult() async {
    final previewResult = _previewResult;
    if (!mounted || previewResult == null) {
      return;
    }
    if (previewResult.canCompare) {
      await _showWebImageComparisonViewer(
        context,
        title: '预览结果',
        beforeImageBytes: previewResult.beforeImageBytes!,
        afterImageBytes: previewResult.afterImageBytes!,
        resultImageBytes: previewResult.imageBytes!,
        beforeLabel: previewResult.beforeLabel,
        afterLabel: previewResult.afterLabel,
        initialMode: _previewComparisonMode,
        initialDivider: _previewComparisonDivider,
      );
      return;
    }
    await _showWebImageViewer(
      context,
      title: '预览结果',
      imageBytes: previewResult.imageBytes,
      imageUrl: _resolvedUrl(previewResult.mediaUrl),
    );
  }

  Future<_WebResolvedMediaUrl> _resolveCachedMediaUrl(String url) async {
    try {
      final cache = await web.window.caches.open(_browserMediaCacheName).toDart;
      final response = await cache.match(url.toJS).toDart;
      if (response != null) {
        final blob = await response.blob().toDart;
        return _WebResolvedMediaUrl(
          url: web.URL.createObjectURL(blob),
          fromBrowserCache: true,
          isObjectUrl: true,
        );
      }
    } catch (_) {
      // Playback can still use the Bridge media URL if browser cache is absent.
    }
    return _WebResolvedMediaUrl(
      url: url,
      fromBrowserCache: false,
      isObjectUrl: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.surface,
              theme.scaffoldBackgroundColor,
              const Color(0xFF061826),
            ],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, outerConstraints) {
              final compact = outerConstraints.maxWidth < 760;
              return Padding(
                padding: EdgeInsets.all(compact ? 12 : 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Header(
                      busy: _loading || _busy,
                      message: _message,
                      onRefresh: _loadAll,
                    ),
                    SizedBox(height: compact ? 12 : 18),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final wide = constraints.maxWidth >= 1180;
                          if (wide) {
                            final workspace = _buildWorkspaceCard(
                              context,
                              compact: compact,
                            );
                            final sidePanel = _buildSidePanelCard(context);
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(flex: 6, child: workspace),
                                const SizedBox(width: 18),
                                Expanded(flex: 4, child: sidePanel),
                              ],
                            );
                          }
                          return _buildMobileTabbedWorkbench(
                            context,
                            compact: compact,
                          );
                        },
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildMobileTabbedWorkbench(
    BuildContext context, {
    required bool compact,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _WorkbenchMobileTabBar(
          activeTab: _mobileTab,
          onChanged: (tab) {
            if (_mobileTab == tab) {
              return;
            }
            setState(() {
              _mobileTab = tab;
              if (tab == _WebWorkbenchMobileTab.queue) {
                _sideTab = _WebWorkbenchSideTab.queue;
              } else if (tab == _WebWorkbenchMobileTab.works) {
                _sideTab = _WebWorkbenchSideTab.works;
              }
            });
          },
        ),
        SizedBox(height: compact ? 10 : 14),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: switch (_mobileTab) {
              _WebWorkbenchMobileTab.workspace => KeyedSubtree(
                key: const ValueKey<String>('mobile-workspace-tab'),
                child: _buildWorkspaceCard(context, compact: compact),
              ),
              _WebWorkbenchMobileTab.queue => _buildMobilePanelCard(
                key: const ValueKey<String>('mobile-queue-tab'),
                compact: compact,
                child: _buildQueuePanel(context),
              ),
              _WebWorkbenchMobileTab.works => _buildMobilePanelCard(
                key: const ValueKey<String>('mobile-works-tab'),
                compact: compact,
                child: _buildWorksPanel(context),
              ),
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMobilePanelCard({
    required Key key,
    required bool compact,
    required Widget child,
  }) {
    return Card(
      key: key,
      child: Padding(padding: EdgeInsets.all(compact ? 14 : 22), child: child),
    );
  }

  Widget _buildWorkspaceCard(BuildContext context, {bool compact = false}) {
    final theme = Theme.of(context);
    final sourcePaths =
        _workspace['source_paths'] as List<dynamic>? ?? const <dynamic>[];
    final targetPath = '${_workspace['target_path'] ?? ''}';
    final sourceThumbnailUrl = _resolvedUrl(_workspace['source_thumbnail_url']);
    final targetThumbnailUrl = _resolvedUrl(_workspace['target_thumbnail_url']);
    final targetMediaType = _workspace['target_media_type'] as String?;
    final targetFrameTotal = (_workspace['target_video_frame_total'] as num?)
        ?.toInt();
    final previewResult = _previewResult;
    final previewUrl = _resolvedUrl(previewResult?.mediaUrl);
    final previewFrameTotal =
        previewResult?.videoFrameTotal ?? targetFrameTotal;
    final showPreviewFrameSlider =
        targetMediaType == 'video' &&
        previewFrameTotal != null &&
        previewFrameTotal > 1;
    final previewFrameMax = showPreviewFrameSlider ? previewFrameTotal - 1 : 1;
    final previewFrameNumber = previewResult?.targetMediaType == 'video'
        ? previewResult?.frameNumber ?? _previewFrameNumberOption()
        : _previewFrameNumberOption();
    final previewFrameValue =
        (_previewFrameSliderValue ?? previewFrameNumber.toDouble())
            .clamp(0.0, previewFrameMax.toDouble())
            .toDouble();
    final previewCanCompare = previewResult?.canCompare == true;

    return Card(
      child: Padding(
        padding: EdgeInsets.all(compact ? 14 : 22),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Web 工作台', style: theme.textTheme.headlineMedium),
              const SizedBox(height: 6),
              Text(
                '浏览器上传媒体文件，也可以直接选择或保存人物形象，再由 Bridge 生成预览、加入队列或立即生成。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : _pickPersona,
                    icon: const Icon(Icons.badge_outlined),
                    label: const Text('选择人物'),
                  ),
                  OutlinedButton.icon(
                    onPressed: sourcePaths.isEmpty || _busy
                        ? null
                        : _savePersona,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('保存人物'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 760;
                  final cards = [
                    _MediaCard(
                      title: '源文件',
                      detail: sourcePaths.isEmpty
                          ? '未选择'
                          : '${sourcePaths.length} 个文件',
                      mediaUrl: sourceThumbnailUrl,
                      mediaType: 'image',
                      onOpen: sourcePaths.isEmpty ? null : _openSourcePreview,
                      onCopyUrl: sourceThumbnailUrl == null
                          ? null
                          : () => _copyUrl(sourceThumbnailUrl),
                      actions: [
                        FilledButton.icon(
                          onPressed: _busy ? null : _pickSourceFiles,
                          icon: const Icon(Icons.person_add_alt_1_rounded),
                          label: const Text('上传源文件'),
                        ),
                        OutlinedButton.icon(
                          onPressed: sourcePaths.isEmpty || _busy
                              ? null
                              : _clearSources,
                          icon: const Icon(Icons.clear_all_rounded),
                          label: const Text('清空源文件'),
                        ),
                      ],
                    ),
                    _MediaCard(
                      title: '目标文件',
                      detail: targetPath.isEmpty || targetPath == 'null'
                          ? '未选择'
                          : targetPath.split(RegExp(r'[\\/]')).last,
                      mediaUrl: targetThumbnailUrl,
                      mediaType: targetMediaType,
                      onOpen: targetPath.isEmpty || targetPath == 'null'
                          ? null
                          : _openTargetPreview,
                      onCopyUrl: targetThumbnailUrl == null
                          ? null
                          : () => _copyUrl(targetThumbnailUrl),
                      actions: [
                        FilledButton.tonalIcon(
                          onPressed: _busy ? null : _pickTargetFile,
                          icon: const Icon(Icons.movie_filter_rounded),
                          label: const Text('上传目标文件'),
                        ),
                        OutlinedButton.icon(
                          onPressed:
                              targetPath.isEmpty ||
                                  targetPath == 'null' ||
                                  _busy
                              ? null
                              : _clearTarget,
                          icon: const Icon(Icons.backspace_outlined),
                          label: const Text('清空目标'),
                        ),
                      ],
                    ),
                    _MediaCard(
                      title: '预览结果',
                      detail: previewResult == null ? '尚未生成' : '预览已生成',
                      mediaUrl: previewUrl,
                      mediaType: targetMediaType,
                      onOpen: previewResult == null ? null : _openPreviewResult,
                      preview: _previewBusy
                          ? const _WebPreviewBusyPane()
                          : previewResult?.imageBytes == null
                          ? null
                          : previewCanCompare
                          ? _WebImageComparisonFrame(
                              beforeImageBytes:
                                  previewResult!.beforeImageBytes!,
                              afterImageBytes: previewResult.afterImageBytes!,
                              resultImageBytes: previewResult.imageBytes!,
                              mode: _previewComparisonMode,
                              divider: _previewComparisonDivider,
                              onDividerChanged: (value) {
                                setState(() {
                                  _previewComparisonDivider = value;
                                });
                              },
                              beforeLabel: previewResult.beforeLabel,
                              afterLabel: previewResult.afterLabel,
                            )
                          : Image.memory(
                              previewResult!.imageBytes!,
                              fit: BoxFit.contain,
                              width: double.infinity,
                              height: double.infinity,
                              gaplessPlayback: true,
                            ),
                      onCopyUrl: previewUrl == null
                          ? null
                          : () => _copyUrl(previewUrl),
                      actions: [
                        FilledButton.icon(
                          onPressed: _canSubmit ? _previewWorkspace : null,
                          icon: const Icon(Icons.visibility_outlined),
                          label: Text(
                            previewResult == null ? '生成预览' : '重新生成预览',
                          ),
                        ),
                      ],
                      extraContent: previewCanCompare || showPreviewFrameSlider
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (previewCanCompare)
                                  _WebPreviewComparisonControls(
                                    mode: _previewComparisonMode,
                                    onChanged: (mode) {
                                      setState(() {
                                        _previewComparisonMode = mode;
                                      });
                                    },
                                  ),
                                if (previewCanCompare && showPreviewFrameSlider)
                                  const SizedBox(height: 12),
                                if (showPreviewFrameSlider)
                                  _WebPreviewFrameSlider(
                                    value: previewFrameValue,
                                    maxFrame: previewFrameMax,
                                    enabled: _canSubmit,
                                    onChanged: (value) {
                                      setState(() {
                                        _previewFrameSliderValue = value;
                                      });
                                    },
                                    onChangeEnd: (value) async {
                                      final frameNumber = value.round();
                                      setState(() {
                                        _previewFrameSliderValue = frameNumber
                                            .toDouble();
                                      });
                                      await _previewWorkspaceAtFrame(
                                        frameNumber,
                                      );
                                      if (!mounted) {
                                        return;
                                      }
                                      setState(() {
                                        _previewFrameSliderValue = null;
                                      });
                                    },
                                  ),
                              ],
                            )
                          : null,
                    ),
                  ];
                  if (compact) {
                    return Column(
                      children: [
                        for (final card in cards) ...[
                          card,
                          const SizedBox(height: 12),
                        ],
                      ],
                    );
                  }
                  return Row(
                    children: [
                      for (final card in cards) ...[
                        Expanded(child: card),
                        if (card != cards.last) const SizedBox(width: 12),
                      ],
                    ],
                  );
                },
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _canSubmit ? _queueWorkspace : null,
                    icon: const Icon(Icons.playlist_add_rounded),
                    label: const Text('加入队列'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _canSubmit ? _runWorkspace : null,
                    icon: const Icon(Icons.bolt_rounded),
                    label: const Text('立即生成'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _loadWorkspace(),
                    icon: const Icon(Icons.sync_rounded),
                    label: const Text('刷新工作台'),
                  ),
                ],
              ),
              const Divider(height: 32),
              WorkspaceOptionsPanel(
                compact: compact,
                busy: _busy,
                targetMediaType: targetMediaType,
                targetVideoFrameTotal: targetFrameTotal,
                schema: _optionsSchema,
                state: _optionsState,
                onUpdateOptions: _updateOptions,
                onResetOptions: _resetOptions,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSidePanelCard(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('工作台侧栏', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 6),
            Text(
              _sideTab == _WebWorkbenchSideTab.queue
                  ? '在这里查看生成队列、任务进度和运行状态。'
                  : '在这里查看作品列表，并直接执行复制链接、打开目录、取消任务或删除作品。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            _WorkbenchSideTabBar(
              activeTab: _sideTab,
              onChanged: (tab) {
                if (_sideTab == tab) {
                  return;
                }
                setState(() {
                  _sideTab = tab;
                });
              },
            ),
            const SizedBox(height: 14),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: _sideTab == _WebWorkbenchSideTab.queue
                    ? _buildQueuePanel(context)
                    : _buildWorksPanel(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQueuePanel(BuildContext context) {
    final theme = Theme.of(context);
    final active = _queueRunner['active'] == true;
    final currentJobId = '${_queueRunner['current_job_id'] ?? ''}';
    return Column(
      key: const ValueKey<String>('queue-tab'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('生成队列', style: theme.textTheme.headlineMedium),
            ),
            IconButton(
              tooltip: '刷新队列',
              onPressed: _busy ? null : () => _loadQueue(),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          active
              ? '正在执行：${currentJobId.isEmpty ? '队列任务' : currentJobId}'
              : '队列待命，可启动 queued 任务。',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.icon(
              onPressed: _busy || active ? null : _runQueue,
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('启动队列'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _clearCompletedQueue,
              icon: const Icon(Icons.cleaning_services_outlined),
              label: const Text('清理完成任务'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Expanded(
          child: _queueTasks.isEmpty
              ? Center(
                  child: Text(
                    '暂无队列任务。',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: _queueTasks.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final task = _queueTasks[index];
                    final status = '${task['status'] ?? ''}';
                    final progressDetail = '${task['progress_detail'] ?? ''}';
                    final isActive = task['is_active'] == true;
                    final usesCancelAction =
                        isActive || status == 'drafted' || status == 'queued';
                    final isCancelling =
                        usesCancelAction && progressDetail.contains('取消');
                    final taskId = '${task['job_id'] ?? ''}';
                    return _QueueTaskCard(
                      task: task,
                      client: _client,
                      onCopyUrl: _copyUrl,
                      onPlay: _canPlayQueueTask(task) && !_busy
                          ? () => _openQueueTaskPlayback(task)
                          : null,
                      onCancel: usesCancelAction && !_busy && !isCancelling
                          ? () => _cancelQueueTask(
                              '${task['job_id']}',
                              isActive: isActive,
                            )
                          : null,
                      onDelete: usesCancelAction || _busy
                          ? null
                          : () => _deleteQueueTask('${task['job_id']}'),
                      browserCacheState: _browserCachedTaskIds.contains(taskId)
                          ? _WebWorkBrowserCacheState.cached
                          : _browserCachingTaskIds.contains(taskId)
                          ? _WebWorkBrowserCacheState.caching
                          : _WebWorkBrowserCacheState.none,
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildWorksPanel(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey<String>('works-tab'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('作品管理', style: theme.textTheme.headlineMedium),
            ),
            IconButton(
              tooltip: '刷新作品列表',
              onPressed: _busy ? null : () => _loadWorks(),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _worksOutputRoot.isEmpty
              ? '这里会显示已生成作品和队列中的作品记录。'
              : '输出目录：$_worksOutputRoot',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          '共 ${_works.length} 项，可直接复制链接、打开所在目录或删除。',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: _worksLoading
              ? const Center(child: CircularProgressIndicator())
              : _works.isEmpty
              ? Center(
                  child: Text(
                    '暂无作品。完成一次生成后会显示在这里。',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: _works.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final item = _works[index];
                    return _WebWorkCard(
                      item: item,
                      client: _client,
                      busy: _busy,
                      onSelected: (_WebWorkMenuAction action) =>
                          _handleWorkMenuAction(item, action),
                      onPreviewImage: item.canPreviewImage
                          ? () => _showWorkImagePreviewDialog(
                              context,
                              title: item.displayName,
                              imageUrl: _client.resolveUrl(item.mediaUrl!),
                            )
                          : null,
                      onDownload: item.canDownload && !_busy
                          ? () => _downloadWorkItem(item)
                          : null,
                      browserCacheState: _browserCachedWorkIds.contains(item.id)
                          ? _WebWorkBrowserCacheState.cached
                          : _browserCachingWorkIds.contains(item.id)
                          ? _WebWorkBrowserCacheState.caching
                          : _WebWorkBrowserCacheState.none,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.busy,
    required this.message,
    required this.onRefresh,
  });

  final bool busy;
  final String message;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(right: 12),
          child: StudioBrandMark(size: 48),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'FaceSwap Studio Web',
                style: theme.textTheme.headlineMedium,
              ),
              const SizedBox(height: 4),
              Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        if (busy)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
          )
        else
          FilledButton.tonalIcon(
            onPressed: onRefresh,
            icon: const Icon(Icons.sync_rounded),
            label: const Text('同步'),
          ),
      ],
    );
  }
}

class _WorkbenchSideTabBar extends StatelessWidget {
  const _WorkbenchSideTabBar({
    required this.activeTab,
    required this.onChanged,
  });

  final _WebWorkbenchSideTab activeTab;
  final ValueChanged<_WebWorkbenchSideTab> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.35,
        ),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          children: [
            Expanded(
              child: _WorkbenchSideTabButton(
                label: '生成队列',
                icon: Icons.playlist_play_rounded,
                selected: activeTab == _WebWorkbenchSideTab.queue,
                onTap: () => onChanged(_WebWorkbenchSideTab.queue),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _WorkbenchSideTabButton(
                label: '作品管理',
                icon: Icons.photo_library_outlined,
                selected: activeTab == _WebWorkbenchSideTab.works,
                onTap: () => onChanged(_WebWorkbenchSideTab.works),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkbenchMobileTabBar extends StatelessWidget {
  const _WorkbenchMobileTabBar({
    required this.activeTab,
    required this.onChanged,
  });

  final _WebWorkbenchMobileTab activeTab;
  final ValueChanged<_WebWorkbenchMobileTab> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.35,
        ),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          children: [
            Expanded(
              child: _WorkbenchMobileTabButton(
                label: '工作台',
                icon: Icons.dashboard_customize_outlined,
                selected: activeTab == _WebWorkbenchMobileTab.workspace,
                onTap: () => onChanged(_WebWorkbenchMobileTab.workspace),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _WorkbenchMobileTabButton(
                label: '生成队列',
                icon: Icons.playlist_play_rounded,
                selected: activeTab == _WebWorkbenchMobileTab.queue,
                onTap: () => onChanged(_WebWorkbenchMobileTab.queue),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _WorkbenchMobileTabButton(
                label: '作品管理',
                icon: Icons.photo_library_outlined,
                selected: activeTab == _WebWorkbenchMobileTab.works,
                onTap: () => onChanged(_WebWorkbenchMobileTab.works),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkbenchMobileTabButton extends StatelessWidget {
  const _WorkbenchMobileTabButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = selected
        ? theme.colorScheme.primary
        : Colors.transparent;
    final foreground = selected
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: background,
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: theme.colorScheme.primary.withValues(alpha: 0.28),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: foreground),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkbenchSideTabButton extends StatelessWidget {
  const _WorkbenchSideTabButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = selected
        ? theme.colorScheme.primary
        : Colors.transparent;
    final foreground = selected
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: background,
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: theme.colorScheme.primary.withValues(alpha: 0.28),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: foreground),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WebPersonaPickerDialog extends StatefulWidget {
  const _WebPersonaPickerDialog({required this.client});

  final BridgeClient client;

  @override
  State<_WebPersonaPickerDialog> createState() =>
      _WebPersonaPickerDialogState();
}

class _WebPersonaPickerDialogState extends State<_WebPersonaPickerDialog> {
  bool _loading = true;
  String _message = '正在加载人物形象库...';
  List<_WebPersonaChoice> _items = <_WebPersonaChoice>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _message = '正在加载人物形象库...';
    });
    try {
      final result = await widget.client.getPersonas();
      if (!mounted) {
        return;
      }
      setState(() {
        _items = (result['items'] as List<dynamic>? ?? const <dynamic>[])
            .cast<Map<String, dynamic>>()
            .map(_WebPersonaChoice.fromJson)
            .toList();
        _loading = false;
        _message = _items.isEmpty ? '人物形象库为空，请先保存人物形象。' : '';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _message = '加载人物形象库失败：$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('选择人物形象')),
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新人物形象',
          ),
        ],
      ),
      content: SizedBox(
        width: 760,
        height: 520,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _items.isEmpty
            ? Center(
                child: Text(
                  _message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 680
                      ? 3
                      : constraints.maxWidth >= 440
                      ? 2
                      : 1;
                  return GridView.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: columns == 1 ? 1.75 : 0.84,
                    ),
                    itemCount: _items.length,
                    itemBuilder: (context, index) {
                      final item = _items[index];
                      return _WebPersonaChoiceCard(
                        item: item,
                        previewUrl: item.previewPath == null
                            ? null
                            : widget.client.mediaUrlForPath(item.previewPath!),
                        onTap: () => Navigator.of(context).pop(item),
                      );
                    },
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

class _WebPersonaChoiceCard extends StatelessWidget {
  const _WebPersonaChoiceCard({
    required this.item,
    required this.previewUrl,
    required this.onTap,
  });

  final _WebPersonaChoice item;
  final String? previewUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    width: double.infinity,
                    color: theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.36,
                    ),
                    child: previewUrl == null
                        ? Icon(
                            Icons.face_retouching_natural_rounded,
                            size: 42,
                            color: theme.colorScheme.primary,
                          )
                        : Image.network(
                            previewUrl!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Icon(
                              Icons.broken_image_outlined,
                              color: theme.colorScheme.error,
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${item.faceCount} 张角度图 · ${item.updatedAt}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MediaCard extends StatelessWidget {
  const _MediaCard({
    required this.title,
    required this.detail,
    required this.mediaUrl,
    required this.mediaType,
    required this.onCopyUrl,
    this.onOpen,
    this.preview,
    this.actions = const <Widget>[],
    this.extraContent,
  });

  final String title;
  final String detail;
  final String? mediaUrl;
  final String? mediaType;
  final VoidCallback? onCopyUrl;
  final VoidCallback? onOpen;
  final Widget? preview;
  final List<Widget> actions;
  final Widget? extraContent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 10,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Material(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.42,
                  ),
                  child: InkWell(
                    onTap: onOpen,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        preview ??
                            (mediaUrl == null
                                ? Icon(
                                    Icons.image_not_supported_outlined,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  )
                                : mediaType == 'image' ||
                                      mediaUrl!.contains('.png')
                                ? Image.network(mediaUrl!, fit: BoxFit.cover)
                                : Center(
                                    child: Icon(
                                      mediaType == 'video'
                                          ? Icons.movie_creation_outlined
                                          : Icons.graphic_eq_rounded,
                                      size: 42,
                                      color: theme.colorScheme.primary,
                                    ),
                                  )),
                        if (onOpen != null)
                          const Positioned(
                            right: 8,
                            bottom: 8,
                            child: _WebOpenBadge(label: '点击全屏查看'),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '复制媒体链接',
                  onPressed: onCopyUrl,
                  icon: const Icon(Icons.link_rounded),
                ),
              ],
            ),
            Text(
              detail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
            ],
            if (extraContent != null) ...[
              const SizedBox(height: 12),
              extraContent!,
            ],
          ],
        ),
      ),
    );
  }
}

class _WebOpenBadge extends StatelessWidget {
  const _WebOpenBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: theme.colorScheme.surface.withValues(alpha: 0.9),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.zoom_out_map_rounded,
              size: 14,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WebPreviewBusyPane extends StatelessWidget {
  const _WebPreviewBusyPane();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 30,
            height: 30,
            child: CircularProgressIndicator(strokeWidth: 2.6),
          ),
          const SizedBox(height: 12),
          Text('正在生成预览', style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _WebPreviewFrameSlider extends StatelessWidget {
  const _WebPreviewFrameSlider({
    required this.value,
    required this.maxFrame,
    required this.enabled,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final double value;
  final int maxFrame;
  final bool enabled;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentFrame = value.round().clamp(0, maxFrame);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '预览帧',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            Text(
              '帧 $currentFrame / $maxFrame',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(0.0, maxFrame.toDouble()).toDouble(),
          min: 0,
          max: maxFrame.toDouble(),
          divisions: maxFrame,
          label: '$currentFrame',
          onChanged: enabled ? onChanged : null,
          onChangeEnd: enabled ? onChangeEnd : null,
        ),
      ],
    );
  }
}

class _QueueTaskCard extends StatelessWidget {
  const _QueueTaskCard({
    required this.task,
    required this.client,
    required this.onCopyUrl,
    required this.onPlay,
    required this.onCancel,
    required this.onDelete,
    required this.browserCacheState,
  });

  final Map<String, dynamic> task;
  final BridgeClient client;
  final Future<void> Function(String? url) onCopyUrl;
  final VoidCallback? onPlay;
  final VoidCallback? onCancel;
  final VoidCallback? onDelete;
  final _WebWorkBrowserCacheState browserCacheState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = '${task['status'] ?? 'queued'}';
    final progressDetail = '${task['progress_detail'] ?? status}';
    final progress = (task['progress_percent'] as num?)?.toDouble() ?? 0.0;
    final isActive = task['is_active'] == true;
    final usesCancelAction =
        isActive || status == 'drafted' || status == 'queued';
    final isCancelling = usesCancelAction && progressDetail.contains('取消');
    final thumbnailUrl =
        _resolve(task['output_thumbnail_url']) ??
        _resolve(task['target_thumbnail_url']) ??
        _resolve(task['source_thumbnail_url']);
    final outputUrl = _resolve(task['output_media_url']);
    final cacheLabel = switch (browserCacheState) {
      _WebWorkBrowserCacheState.cached => '浏览器已缓存',
      _WebWorkBrowserCacheState.caching => '缓存中',
      _ => null,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox.square(
                dimension: 76,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    thumbnailUrl == null
                        ? ColoredBox(
                            color: theme.colorScheme.surface.withValues(
                              alpha: 0.48,
                            ),
                            child: Icon(
                              Icons.work_history_outlined,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          )
                        : Image.network(thumbnailUrl, fit: BoxFit.cover),
                    if (onPlay != null)
                      Positioned(
                        right: 6,
                        bottom: 6,
                        child: Tooltip(
                          message: '播放成片 / 对比',
                          child: Material(
                            color: theme.colorScheme.primary,
                            shape: const CircleBorder(),
                            elevation: 4,
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: onPlay,
                              child: SizedBox.square(
                                dimension: 32,
                                child: Icon(
                                  Icons.play_arrow_rounded,
                                  size: 20,
                                  color: theme.colorScheme.onPrimary,
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
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${task['job_id'] ?? 'queue-task'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    progressDetail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: (progress / 100).clamp(0, 1)),
                  const SizedBox(height: 6),
                  Text(
                    cacheLabel == null
                        ? '$status · ${progress.toStringAsFixed(1)}%'
                        : '$status · ${progress.toStringAsFixed(1)}% · $cacheLabel',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Column(
              children: [
                IconButton(
                  tooltip: '复制输出链接',
                  onPressed: outputUrl == null
                      ? null
                      : () => onCopyUrl(outputUrl),
                  icon: const Icon(Icons.link_rounded),
                ),
                if (usesCancelAction)
                  IconButton(
                    tooltip: isCancelling
                        ? '取消中'
                        : isActive
                        ? '取消运行中任务'
                        : '取消任务',
                    onPressed: onCancel,
                    icon: Icon(
                      isCancelling
                          ? Icons.hourglass_top_rounded
                          : Icons.cancel_outlined,
                    ),
                  )
                else
                  IconButton(
                    tooltip: '删除任务',
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String? _resolve(Object? value) {
    final text = '$value';
    if (value == null || text.isEmpty || text == 'null') {
      return null;
    }
    return client.resolveUrl(text);
  }
}

class _WebPlaybackMedia {
  const _WebPlaybackMedia({
    required this.label,
    required this.url,
    required this.mediaType,
  });

  final String label;
  final String url;
  final String mediaType;
}

class _WebResolvedMediaUrl {
  const _WebResolvedMediaUrl({
    required this.url,
    required this.fromBrowserCache,
    required this.isObjectUrl,
  });

  final String url;
  final bool fromBrowserCache;
  final bool isObjectUrl;
}

class _WebWorkspacePreviewResult {
  const _WebWorkspacePreviewResult({
    required this.message,
    required this.imageBytes,
    required this.beforeImageBytes,
    required this.afterImageBytes,
    required this.frameNumber,
    required this.videoFrameTotal,
    required this.targetMediaType,
    required this.mediaUrl,
  });

  factory _WebWorkspacePreviewResult.fromJson(Map<String, dynamic> json) {
    return _WebWorkspacePreviewResult(
      message: '${json['message'] ?? '预览已生成。'}',
      imageBytes: _decodeImageBytes(json['image_base64']),
      beforeImageBytes: _decodeImageBytes(json['before_image_base64']),
      afterImageBytes: _decodeImageBytes(json['after_image_base64']),
      frameNumber: _readInt(json['frame_number']) ?? 0,
      videoFrameTotal: _readInt(json['video_frame_total']),
      targetMediaType: _readNullableString(json['target_media_type']),
      mediaUrl: _readNullableString(json['media_url']),
    );
  }

  final String message;
  final Uint8List? imageBytes;
  final Uint8List? beforeImageBytes;
  final Uint8List? afterImageBytes;
  final int frameNumber;
  final int? videoFrameTotal;
  final String? targetMediaType;
  final String? mediaUrl;

  bool get canCompare =>
      imageBytes?.isNotEmpty == true &&
      beforeImageBytes?.isNotEmpty == true &&
      afterImageBytes?.isNotEmpty == true;

  String get beforeLabel => targetMediaType == 'video' ? '原视频帧' : '原图';

  String get afterLabel => '换脸结果';

  static Uint8List? _decodeImageBytes(Object? value) {
    final text = _readNullableString(value);
    if (text == null) {
      return null;
    }
    try {
      return base64Decode(text);
    } on FormatException {
      return null;
    }
  }

  static int? _readInt(Object? value) {
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse('$value');
  }

  static String? _readNullableString(Object? value) {
    final text = '$value';
    if (value == null || text.isEmpty || text == 'null') {
      return null;
    }
    return text;
  }
}

class _WebTaskPlaybackDialog extends StatefulWidget {
  const _WebTaskPlaybackDialog({
    required this.title,
    required this.output,
    required this.compare,
    required this.resolveMediaUrl,
  });

  final String title;
  final _WebPlaybackMedia output;
  final _WebPlaybackMedia? compare;
  final Future<_WebResolvedMediaUrl> Function(String url) resolveMediaUrl;

  @override
  State<_WebTaskPlaybackDialog> createState() => _WebTaskPlaybackDialogState();
}

class _WebTaskPlaybackDialogState extends State<_WebTaskPlaybackDialog> {
  _WebPlaybackMode _mode = _WebPlaybackMode.output;
  _WebResolvedMediaUrl? _outputUrl;
  _WebResolvedMediaUrl? _compareUrl;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadMediaUrls());
  }

  @override
  void dispose() {
    _revokeObjectUrl(_outputUrl);
    _revokeObjectUrl(_compareUrl);
    super.dispose();
  }

  Future<void> _loadMediaUrls() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final outputUrl = await widget.resolveMediaUrl(widget.output.url);
      final compare = widget.compare;
      final compareUrl = compare == null
          ? null
          : await widget.resolveMediaUrl(compare.url);
      if (!mounted) {
        _revokeObjectUrl(outputUrl);
        _revokeObjectUrl(compareUrl);
        return;
      }
      setState(() {
        _outputUrl = outputUrl;
        _compareUrl = compareUrl;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = '播放资源准备失败：$error';
      });
    }
  }

  void _revokeObjectUrl(_WebResolvedMediaUrl? mediaUrl) {
    if (mediaUrl?.isObjectUrl == true) {
      web.URL.revokeObjectURL(mediaUrl!.url);
    }
  }

  bool get _hasCompare => widget.compare != null && _compareUrl != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final width = (size.width * 0.92).clamp(360.0, 1040.0).toDouble();
    final height = (size.height * 0.86).clamp(420.0, 760.0).toDouble();
    final outputUrl = _outputUrl;
    final compareUrl = _compareUrl;
    final mode = _hasCompare ? _mode : _WebPlaybackMode.output;

    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 8, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭播放',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  if (!_loading && _error == null && _hasCompare) ...[
                    const SizedBox(height: 8),
                    SegmentedButton<_WebPlaybackMode>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment<_WebPlaybackMode>(
                          value: _WebPlaybackMode.output,
                          icon: Icon(Icons.play_arrow_rounded),
                          label: Text('成片'),
                        ),
                        ButtonSegment<_WebPlaybackMode>(
                          value: _WebPlaybackMode.wipe,
                          icon: Icon(Icons.compare_arrows_rounded),
                          label: Text('划像'),
                        ),
                        ButtonSegment<_WebPlaybackMode>(
                          value: _WebPlaybackMode.split,
                          icon: Icon(Icons.splitscreen_rounded),
                          label: Text('分屏'),
                        ),
                      ],
                      selected: <_WebPlaybackMode>{mode},
                      onSelectionChanged: (selection) {
                        setState(() {
                          _mode = selection.first;
                        });
                      },
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                    ? Center(
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      )
                    : outputUrl == null
                    ? Center(
                        child: Text(
                          '未找到可播放的生成视频。',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : mode != _WebPlaybackMode.output &&
                          widget.compare != null &&
                          compareUrl != null
                    ? _WebCompareMediaBody(
                        before: widget.compare!,
                        beforeUrl: compareUrl,
                        after: widget.output,
                        afterUrl: outputUrl,
                        mode: mode,
                      )
                    : _WebMediaPane(media: widget.output, mediaUrl: outputUrl),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WebCompareMediaBody extends StatelessWidget {
  const _WebCompareMediaBody({
    required this.before,
    required this.beforeUrl,
    required this.after,
    required this.afterUrl,
    required this.mode,
  });

  final _WebPlaybackMedia before;
  final _WebResolvedMediaUrl beforeUrl;
  final _WebPlaybackMedia after;
  final _WebResolvedMediaUrl afterUrl;
  final _WebPlaybackMode mode;

  @override
  Widget build(BuildContext context) {
    return _WebSyncedVideoComparison(
      before: before,
      beforeUrl: beforeUrl,
      after: after,
      afterUrl: afterUrl,
      mode: mode,
    );
  }
}

class _WebSyncedVideoComparison extends StatefulWidget {
  const _WebSyncedVideoComparison({
    required this.before,
    required this.beforeUrl,
    required this.after,
    required this.afterUrl,
    required this.mode,
  });

  final _WebPlaybackMedia before;
  final _WebResolvedMediaUrl beforeUrl;
  final _WebPlaybackMedia after;
  final _WebResolvedMediaUrl afterUrl;
  final _WebPlaybackMode mode;

  @override
  State<_WebSyncedVideoComparison> createState() =>
      _WebSyncedVideoComparisonState();
}

class _WebSyncedVideoComparisonState extends State<_WebSyncedVideoComparison> {
  static const Duration _syncInterval = Duration(milliseconds: 250);
  static const Duration _syncThreshold = Duration(milliseconds: 75);

  web.HTMLVideoElement? _beforeVideo;
  web.HTMLVideoElement? _afterVideo;
  web.HTMLDivElement? _wipeAfterLayer;
  Timer? _syncTimer;
  double _divider = 0.5;
  double _positionSeconds = 0;
  double _durationSeconds = 0;
  double? _dragSeconds;
  bool _playing = false;
  bool _dragWasPlaying = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _syncTimer = Timer.periodic(_syncInterval, (_) => _tick());
  }

  @override
  void didUpdateWidget(_WebSyncedVideoComparison oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.beforeUrl.url != widget.beforeUrl.url ||
        oldWidget.afterUrl.url != widget.afterUrl.url) {
      _beforeVideo = null;
      _afterVideo = null;
      _wipeAfterLayer = null;
      _positionSeconds = 0;
      _durationSeconds = 0;
      _playing = false;
      _dragSeconds = null;
      _error = null;
    }
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _beforeVideo?.pause();
    _afterVideo?.pause();
    super.dispose();
  }

  void _attachBefore(web.HTMLVideoElement video) {
    _beforeVideo = video;
    _applyInitialVideoState(video, muted: true);
    _syncBeforeToAfter(force: true);
  }

  void _attachAfter(web.HTMLVideoElement video) {
    _afterVideo = video;
    _applyInitialVideoState(video, muted: false);
    _syncBeforeToAfter(force: true);
  }

  void _applyInitialVideoState(
    web.HTMLVideoElement video, {
    required bool muted,
  }) {
    video.muted = muted;
    video.preload = 'auto';
    _setVideoTime(video, _positionSeconds);
    if (_playing) {
      unawaited(video.play().toDart.catchError((_) => null));
    }
  }

  void _tick() {
    final after = _afterVideo;
    if (after == null) {
      return;
    }
    if (!after.paused) {
      _syncBeforeToAfter();
    }
    final nextDuration = _safeDuration(after);
    final nextPosition = _safeCurrentTime(after);
    final nextPlaying = !after.paused;
    if (!mounted) {
      return;
    }
    setState(() {
      _durationSeconds = nextDuration;
      if (_dragSeconds == null) {
        _positionSeconds = nextPosition;
      }
      _playing = nextPlaying;
    });
  }

  double _safeDuration(web.HTMLVideoElement video) {
    final duration = video.duration;
    if (!duration.isFinite || duration <= 0) {
      return 0;
    }
    return duration;
  }

  double _safeCurrentTime(web.HTMLVideoElement video) {
    final currentTime = video.currentTime;
    if (!currentTime.isFinite || currentTime < 0) {
      return 0;
    }
    return currentTime;
  }

  double _clampBeforeTime(double seconds) {
    final before = _beforeVideo;
    if (before == null) {
      return seconds < 0 ? 0 : seconds;
    }
    final beforeDuration = _safeDuration(before);
    if (beforeDuration <= 0) {
      return seconds < 0 ? 0 : seconds;
    }
    return seconds.clamp(0.0, beforeDuration).toDouble();
  }

  void _setVideoTime(web.HTMLVideoElement video, double seconds) {
    try {
      video.currentTime = seconds < 0 ? 0 : seconds;
    } catch (_) {
      // Metadata may not be ready yet; the next sync tick will retry.
    }
  }

  void _syncBeforeToAfter({bool force = false}) {
    final before = _beforeVideo;
    final after = _afterVideo;
    if (before == null || after == null) {
      return;
    }
    final target = _clampBeforeTime(_safeCurrentTime(after));
    final drift = (_safeCurrentTime(before) - target).abs();
    if (force || drift * 1000 > _syncThreshold.inMilliseconds) {
      _setVideoTime(before, target);
    }
  }

  Future<void> _setPlaying(bool playing) async {
    final before = _beforeVideo;
    final after = _afterVideo;
    if (before == null || after == null) {
      return;
    }
    try {
      if (playing) {
        await _seekBoth(_dragSeconds ?? _safeCurrentTime(after));
        await Future.wait([before.play().toDart, after.play().toDart]);
      } else {
        before.pause();
        after.pause();
        _syncBeforeToAfter(force: true);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _playing = playing;
        _error = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = '视频播放失败：$error';
        _playing = false;
      });
    }
  }

  Future<void> _togglePlaying() async {
    await _setPlaying(!_playing);
  }

  Future<void> _seekBoth(double seconds) async {
    final before = _beforeVideo;
    final after = _afterVideo;
    if (before == null || after == null) {
      return;
    }
    final target = seconds < 0 ? 0.0 : seconds;
    _setVideoTime(after, target);
    _setVideoTime(before, _clampBeforeTime(target));
    _syncBeforeToAfter(force: true);
    if (!mounted) {
      return;
    }
    setState(() {
      _positionSeconds = target;
    });
  }

  void _beginSeekDrag(double value) {
    final before = _beforeVideo;
    final after = _afterVideo;
    _dragWasPlaying = _playing;
    before?.pause();
    after?.pause();
    setState(() {
      _playing = false;
      _dragSeconds = value;
    });
  }

  void _updateSeekDrag(double value) {
    setState(() {
      _dragSeconds = value;
    });
  }

  Future<void> _endSeekDrag(double value) async {
    await _seekBoth(value);
    if (!mounted) {
      return;
    }
    setState(() {
      _dragSeconds = null;
    });
    if (_dragWasPlaying) {
      await _setPlaying(true);
    }
  }

  void _dragDivider(double deltaX, double width) {
    if (width <= 0) {
      return;
    }
    setState(() {
      _divider = ((_divider * width + deltaX) / width)
          .clamp(0.05, 0.95)
          .toDouble();
    });
    _applyWipeClip();
  }

  void _applyWipeClip() {
    final afterLayer = _wipeAfterLayer;
    if (afterLayer == null) {
      return;
    }
    final hiddenRightPercent = ((1 - _divider) * 100).clamp(0, 100);
    afterLayer.style.setProperty(
      'clip-path',
      'inset(0 ${hiddenRightPercent.toStringAsFixed(3)}% 0 0)',
    );
  }

  web.HTMLVideoElement _createComparisonVideo({
    required String src,
    required bool muted,
  }) {
    final video = web.HTMLVideoElement()
      ..src = src
      ..controls = false
      ..autoplay = false
      ..muted = muted
      ..preload = 'auto'
      ..playsInline = true
      ..style.cssText =
          'position:absolute;'
          'inset:0;'
          'width:100%;'
          'height:100%;'
          'background:#000;'
          'object-fit:contain;'
          'pointer-events:none;';
    return video;
  }

  Widget _buildNativeWipeView() {
    return HtmlElementView.fromTagName(
      key: ValueKey<String>(
        'wipe-native-${widget.beforeUrl.url}-${widget.afterUrl.url}',
      ),
      tagName: 'div',
      onElementCreated: (element) {
        final container = element as web.HTMLDivElement;
        container
          ..textContent = ''
          ..style.cssText =
              'position:relative;'
              'width:100%;'
              'height:100%;'
              'overflow:hidden;'
              'background:#000;'
              'pointer-events:none;';

        final beforeVideo = _createComparisonVideo(
          src: widget.beforeUrl.url,
          muted: true,
        );
        final afterLayer = web.HTMLDivElement()
          ..style.cssText =
              'position:absolute;'
              'inset:0;'
              'width:100%;'
              'height:100%;'
              'overflow:hidden;'
              'pointer-events:none;';
        final afterVideo = _createComparisonVideo(
          src: widget.afterUrl.url,
          muted: false,
        );
        afterLayer.appendChild(afterVideo);
        container
          ..appendChild(beforeVideo)
          ..appendChild(afterLayer);

        _wipeAfterLayer = afterLayer;
        _attachBefore(beforeVideo);
        _attachAfter(afterVideo);
        _applyWipeClip();
      },
    );
  }

  Widget _buildViewport(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: DecoratedBox(
            decoration: const BoxDecoration(color: Colors.black),
            child: widget.mode == _WebPlaybackMode.split
                ? Row(
                    children: [
                      Expanded(
                        child: _WebComparisonVideoPane(
                          label: widget.before.label,
                          cacheLabel: widget.beforeUrl.fromBrowserCache
                              ? '浏览器缓存'
                              : '服务器链接',
                          child: _WebNativeVideo(
                            key: ValueKey<String>(
                              'before-split-${widget.beforeUrl.url}',
                            ),
                            src: widget.beforeUrl.url,
                            controls: false,
                            muted: true,
                            onCreated: _attachBefore,
                          ),
                        ),
                      ),
                      Container(
                        width: 1,
                        color: Colors.white.withValues(alpha: 0.28),
                      ),
                      Expanded(
                        child: _WebComparisonVideoPane(
                          label: widget.after.label,
                          cacheLabel: widget.afterUrl.fromBrowserCache
                              ? '浏览器缓存'
                              : '服务器链接',
                          child: _WebNativeVideo(
                            key: ValueKey<String>(
                              'after-split-${widget.afterUrl.url}',
                            ),
                            src: widget.afterUrl.url,
                            controls: false,
                            muted: false,
                            onCreated: _attachAfter,
                          ),
                        ),
                      ),
                    ],
                  )
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildNativeWipeView(),
                      Positioned(
                        left: (constraints.maxWidth * _divider) - 1,
                        top: 0,
                        bottom: 0,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.resizeLeftRight,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onHorizontalDragUpdate: (details) => _dragDivider(
                              details.delta.dx,
                              constraints.maxWidth,
                            ),
                            child: SizedBox(
                              width: 28,
                              child: Center(
                                child: Container(
                                  width: 2,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 12,
                        top: 12,
                        child: _WebComparisonBadge(
                          label: widget.before.label,
                          detail: widget.beforeUrl.fromBrowserCache
                              ? '浏览器缓存'
                              : '服务器链接',
                        ),
                      ),
                      Positioned(
                        right: 12,
                        top: 12,
                        child: _WebComparisonBadge(
                          label: widget.after.label,
                          detail: widget.afterUrl.fromBrowserCache
                              ? '浏览器缓存'
                              : '服务器链接',
                        ),
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }

  Widget _buildControls(BuildContext context) {
    final theme = Theme.of(context);
    final duration = _durationSeconds <= 0 ? 1.0 : _durationSeconds;
    final displayPosition = (_dragSeconds ?? _positionSeconds)
        .clamp(0.0, duration)
        .toDouble();
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: theme.colorScheme.surface.withValues(alpha: 0.92),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            IconButton.filledTonal(
              tooltip: _playing ? '暂停' : '播放',
              onPressed: _beforeVideo == null || _afterVideo == null
                  ? null
                  : _togglePlaying,
              icon: Icon(
                _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Slider(
                value: displayPosition,
                min: 0,
                max: duration,
                onChangeStart: _beforeVideo == null || _afterVideo == null
                    ? null
                    : _beginSeekDrag,
                onChanged: _beforeVideo == null || _afterVideo == null
                    ? null
                    : _updateSeekDrag,
                onChangeEnd: _beforeVideo == null || _afterVideo == null
                    ? null
                    : (value) => unawaited(_endSeekDrag(value)),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '${_formatWebDuration(displayPosition)} / ${_formatWebDuration(_durationSeconds)}',
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Expanded(child: _buildViewport(context)),
        const SizedBox(height: 12),
        _buildControls(context),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}

class _WebComparisonVideoPane extends StatelessWidget {
  const _WebComparisonVideoPane({
    required this.label,
    required this.cacheLabel,
    required this.child,
  });

  final String label;
  final String cacheLabel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Positioned(
          left: 12,
          top: 12,
          child: _WebComparisonBadge(label: label, detail: cacheLabel),
        ),
      ],
    );
  }
}

class _WebComparisonBadge extends StatelessWidget {
  const _WebComparisonBadge({required this.label, required this.detail});

  final String label;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: Colors.black.withValues(alpha: 0.68),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          '$label · $detail',
          style: theme.textTheme.labelMedium?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _WebMediaPane extends StatelessWidget {
  const _WebMediaPane({required this.media, required this.mediaUrl});

  final _WebPlaybackMedia media;
  final _WebResolvedMediaUrl mediaUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cacheLabel = mediaUrl.fromBrowserCache ? '浏览器缓存' : '服务器链接';
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.28,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    media.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                _WebWorkTag(label: cacheLabel),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: ColoredBox(
                  color: Colors.black,
                  child: media.mediaType == 'video'
                      ? _WebNativeVideo(src: mediaUrl.url)
                      : Image.network(
                          mediaUrl.url,
                          fit: BoxFit.contain,
                          width: double.infinity,
                          height: double.infinity,
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WebNativeVideo extends StatelessWidget {
  const _WebNativeVideo({
    super.key,
    required this.src,
    this.controls = true,
    this.muted = false,
    this.onCreated,
  });

  final String src;
  final bool controls;
  final bool muted;
  final ValueChanged<web.HTMLVideoElement>? onCreated;

  @override
  Widget build(BuildContext context) {
    return HtmlElementView.fromTagName(
      key: ValueKey<String>(src),
      tagName: 'video',
      onElementCreated: (element) {
        final video = element as web.HTMLVideoElement;
        video
          ..src = src
          ..controls = controls
          ..autoplay = false
          ..muted = muted
          ..preload = 'auto'
          ..playsInline = true
          ..style.width = '100%'
          ..style.height = '100%'
          ..style.backgroundColor = '#000000'
          ..style.objectFit = 'contain';
        if (!controls) {
          video.style.pointerEvents = 'none';
        }
        onCreated?.call(video);
      },
    );
  }
}

String _formatWebDuration(double seconds) {
  if (!seconds.isFinite || seconds <= 0) {
    return '00:00';
  }
  final totalSeconds = seconds.floor();
  final minutes = totalSeconds ~/ 60;
  final remainingSeconds = totalSeconds % 60;
  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:'
        '${remainingMinutes.toString().padLeft(2, '0')}:'
        '${remainingSeconds.toString().padLeft(2, '0')}';
  }
  return '${remainingMinutes.toString().padLeft(2, '0')}:'
      '${remainingSeconds.toString().padLeft(2, '0')}';
}

class _WebWorkCard extends StatelessWidget {
  const _WebWorkCard({
    required this.item,
    required this.client,
    required this.busy,
    required this.onSelected,
    required this.onPreviewImage,
    required this.onDownload,
    required this.browserCacheState,
  });

  final _WebWorkItem item;
  final BridgeClient client;
  final bool busy;
  final ValueChanged<_WebWorkMenuAction> onSelected;
  final VoidCallback? onPreviewImage;
  final VoidCallback? onDownload;
  final _WebWorkBrowserCacheState browserCacheState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final previewUrl = item.previewUrl == null
        ? null
        : client.resolveUrl(item.previewUrl!);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: onPreviewImage,
                      child: SizedBox.square(
                        dimension: 82,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface.withValues(
                              alpha: 0.5,
                            ),
                          ),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              previewUrl == null
                                  ? Icon(
                                      item.mediaIcon,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    )
                                  : Image.network(
                                      previewUrl,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => Icon(
                                        Icons.broken_image_outlined,
                                        color: theme.colorScheme.error,
                                      ),
                                    ),
                              if (onPreviewImage != null)
                                Align(
                                  alignment: Alignment.bottomRight,
                                  child: Padding(
                                    padding: const EdgeInsets.all(6),
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                        color: theme.colorScheme.surface
                                            .withValues(alpha: 0.88),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.all(4),
                                        child: Icon(
                                          Icons.zoom_out_map_rounded,
                                          size: 14,
                                          color: theme.colorScheme.primary,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _WebWorkStatusBadge(item: item),
                          _WebWorkTag(label: item.sourceLabel),
                          if (browserCacheState !=
                              _WebWorkBrowserCacheState.none)
                            _WebWorkTag(
                              label:
                                  browserCacheState ==
                                      _WebWorkBrowserCacheState.cached
                                  ? '浏览器已缓存'
                                  : '缓存中',
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        item.metaLabel,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '下载作品',
                      onPressed: onDownload,
                      icon: const Icon(Icons.download_rounded),
                    ),
                    if (item.hasActions)
                      PopupMenuButton<_WebWorkMenuAction>(
                        enabled: !busy,
                        tooltip: '作品操作',
                        onSelected: onSelected,
                        itemBuilder: (context) {
                          final items = <PopupMenuEntry<_WebWorkMenuAction>>[];
                          if (item.canCopyLink) {
                            items.add(
                              const PopupMenuItem<_WebWorkMenuAction>(
                                value: _WebWorkMenuAction.copyLink,
                                child: Text('复制作品链接'),
                              ),
                            );
                          }
                          if (item.canOpenDirectory) {
                            items.add(
                              const PopupMenuItem<_WebWorkMenuAction>(
                                value: _WebWorkMenuAction.openDirectory,
                                child: Text('打开所在目录'),
                              ),
                            );
                          }
                          if (item.canCancelTask) {
                            items.add(
                              const PopupMenuItem<_WebWorkMenuAction>(
                                value: _WebWorkMenuAction.cancelTask,
                                child: Text('取消任务'),
                              ),
                            );
                          }
                          if (item.canDelete) {
                            items.add(
                              PopupMenuItem<_WebWorkMenuAction>(
                                value: _WebWorkMenuAction.delete,
                                child: Text(item.deleteLabel),
                              ),
                            );
                          }
                          return items;
                        },
                        icon: const Icon(Icons.more_vert_rounded),
                      )
                    else
                      const SizedBox(width: 40),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              item.detailLabel,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            if (item.showProgress) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(value: item.progressValue),
              const SizedBox(height: 6),
              Text(
                item.progressSummary,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WebWorkStatusBadge extends StatelessWidget {
  const _WebWorkStatusBadge({required this.item});

  final _WebWorkItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = switch (item.queueStatusKey) {
      'completed' => theme.colorScheme.primaryContainer,
      'failed' => theme.colorScheme.errorContainer,
      'running' => theme.colorScheme.tertiaryContainer,
      'queued' || 'drafted' => theme.colorScheme.surfaceContainerHighest,
      'canceled' => theme.colorScheme.secondaryContainer,
      _ => theme.colorScheme.surfaceContainerHighest,
    };
    final foreground = switch (item.queueStatusKey) {
      'completed' => theme.colorScheme.onPrimaryContainer,
      'failed' => theme.colorScheme.onErrorContainer,
      'running' => theme.colorScheme.onTertiaryContainer,
      'queued' || 'drafted' => theme.colorScheme.onSurfaceVariant,
      'canceled' => theme.colorScheme.onSecondaryContainer,
      _ => theme.colorScheme.onSurfaceVariant,
    };
    return _WebWorkTag(
      label: item.statusLabel,
      background: background,
      foreground: foreground,
    );
  }
}

class _WebWorkTag extends StatelessWidget {
  const _WebWorkTag({required this.label, this.background, this.foreground});

  final String label;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color:
            background ??
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: foreground ?? theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _WebWorkItem {
  const _WebWorkItem({
    required this.id,
    required this.path,
    required this.fileName,
    required this.mediaType,
    required this.mediaUrl,
    required this.thumbnailUrl,
    required this.modifiedAt,
    required this.sizeBytes,
    required this.source,
    required this.queueStatus,
    required this.jobId,
    required this.progressPercent,
    required this.progressPhase,
    required this.progressDetail,
    required this.canOpenOutput,
    required this.isActive,
    required this.outputPath,
    required this.targetPath,
    required this.outputMediaType,
    required this.targetMediaType,
    required this.sourcePaths,
  });

  factory _WebWorkItem.fromJson(Map<String, dynamic> json) {
    return _WebWorkItem(
      id: '${json['id'] ?? ''}',
      path: '${json['path'] ?? ''}',
      fileName: '${json['file_name'] ?? ''}',
      mediaType: '${json['media_type'] ?? 'image'}',
      mediaUrl: _readNullableString(json['media_url']),
      thumbnailUrl: _readNullableString(json['thumbnail_url']),
      modifiedAt: '${json['modified_at'] ?? ''}',
      sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
      source: '${json['source'] ?? 'file'}',
      queueStatus: '${json['queue_status'] ?? 'completed'}',
      jobId: _readNullableString(json['job_id']),
      progressPercent: (json['progress_percent'] as num?)?.toDouble() ?? 0.0,
      progressPhase: '${json['progress_phase'] ?? ''}',
      progressDetail: '${json['progress_detail'] ?? ''}',
      canOpenOutput: json['can_open_output'] == true,
      isActive: json['is_active'] == true,
      outputPath: _readNullableString(json['output_path']),
      targetPath: _readNullableString(json['target_path']),
      outputMediaType: _readNullableString(json['output_media_type']),
      targetMediaType: _readNullableString(json['target_media_type']),
      sourcePaths: (json['source_paths'] as List<dynamic>? ?? const <dynamic>[])
          .map((item) => '$item')
          .where((item) => item.isNotEmpty && item != 'null')
          .toList(growable: false),
    );
  }

  final String id;
  final String path;
  final String fileName;
  final String mediaType;
  final String? mediaUrl;
  final String? thumbnailUrl;
  final String modifiedAt;
  final int sizeBytes;
  final String source;
  final String queueStatus;
  final String? jobId;
  final double progressPercent;
  final String progressPhase;
  final String progressDetail;
  final bool canOpenOutput;
  final bool isActive;
  final String? outputPath;
  final String? targetPath;
  final String? outputMediaType;
  final String? targetMediaType;
  final List<String> sourcePaths;

  static String? _readNullableString(Object? value) {
    final text = '$value';
    if (value == null || text.isEmpty || text == 'null') {
      return null;
    }
    return text;
  }

  static String _basename(String value) =>
      value.split(RegExp(r'[\\/]')).where((item) => item.isNotEmpty).isEmpty
      ? value
      : value.split(RegExp(r'[\\/]')).where((item) => item.isNotEmpty).last;

  static String _formatBytes(int bytes) {
    if (bytes <= 0) {
      return '';
    }
    const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var index = 0;
    while (value >= 1024 && index < units.length - 1) {
      value /= 1024;
      index += 1;
    }
    final digits = value >= 100
        ? 0
        : value >= 10
        ? 1
        : 2;
    return '${value.toStringAsFixed(digits)} ${units[index]}';
  }

  bool get isQueueBacked => source == 'queue';

  bool get hasOutputFile => path.isNotEmpty || (mediaUrl?.isNotEmpty ?? false);

  bool get canCopyLink => mediaUrl?.isNotEmpty == true;

  bool get canCancelTask =>
      isQueueBacked &&
      (isActive || queueStatusKey == 'drafted' || queueStatusKey == 'queued');

  bool get canDeleteQueueTask =>
      isQueueBacked &&
      !canCancelTask &&
      !hasOutputFile &&
      (jobId?.isNotEmpty == true);

  bool get canDelete => canDeleteQueueTask || hasOutputFile;

  bool get canOpenDirectory =>
      canOpenOutput && hasOutputFile && !canDeleteQueueTask;

  bool get isImage => mediaLabel == '图片';

  bool get canPreviewImage => isImage && mediaUrl?.isNotEmpty == true;

  bool get canDownload => hasOutputFile && mediaUrl?.isNotEmpty == true;

  bool get canCacheInBrowser =>
      canDownload && queueStatusKey == 'completed' && !canDeleteQueueTask;

  bool get hasActions =>
      canCopyLink || canOpenDirectory || canCancelTask || canDelete;

  bool get showProgress =>
      isQueueBacked &&
      (isActive || queueStatusKey != 'completed' || progressPercent < 100.0);

  double? get progressValue =>
      showProgress ? (progressPercent / 100).clamp(0.0, 1.0) : null;

  String get queueStatusKey => queueStatus.trim().toLowerCase();

  String get displayName => fileName.isNotEmpty
      ? fileName
      : (jobId?.isNotEmpty == true ? jobId! : '未命名作品');

  String get sourceLabel => isQueueBacked ? '队列记录' : '输出作品';

  String get statusLabel => switch (queueStatusKey) {
    'completed' => '已完成',
    'failed' => '失败',
    'running' => '生成中',
    'queued' => '排队中',
    'drafted' => '待提交',
    'canceled' => '已取消',
    _ => queueStatus.isEmpty ? '未知状态' : queueStatus,
  };

  String get mediaLabel =>
      (outputMediaType ?? targetMediaType ?? mediaType) == 'video'
      ? '视频'
      : '图片';

  IconData get mediaIcon =>
      mediaLabel == '视频' ? Icons.movie_creation_outlined : Icons.image_outlined;

  String get modifiedAtLabel => modifiedAt.replaceFirst('T', ' ');

  String get metaLabel {
    final parts = <String>[mediaLabel];
    if (modifiedAtLabel.isNotEmpty) {
      parts.add(modifiedAtLabel);
    }
    final sizeLabel = _formatBytes(sizeBytes);
    if (sizeLabel.isNotEmpty) {
      parts.add(sizeLabel);
    }
    return parts.join(' · ');
  }

  String get detailLabel {
    if (progressDetail.isNotEmpty && progressDetail != 'null') {
      return progressDetail;
    }
    if (targetPath != null && targetPath!.isNotEmpty) {
      return '目标文件：${_basename(targetPath!)}';
    }
    if (sourcePaths.isNotEmpty) {
      return '源文件 ${sourcePaths.length} 个';
    }
    return '暂无更多信息。';
  }

  String get progressSummary =>
      '$statusLabel · ${progressPercent.toStringAsFixed(progressPercent >= 100 ? 0 : 1)}%';

  String get deleteLabel => canDeleteQueueTask ? '删除队列记录' : '删除作品';

  String get downloadFileName => displayName;

  String? get previewUrl => thumbnailUrl ?? mediaUrl;
}

class _WebPersonaChoice {
  const _WebPersonaChoice({
    required this.id,
    required this.name,
    required this.previewPath,
    required this.faceCount,
    required this.updatedAt,
  });

  factory _WebPersonaChoice.fromJson(Map<String, dynamic> json) {
    final facePaths =
        (json['face_paths'] as List<dynamic>? ?? const <dynamic>[])
            .map((item) => '$item')
            .where((item) => item.isNotEmpty && item != 'null')
            .toList(growable: false);
    return _WebPersonaChoice(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? '未命名人物'}',
      previewPath: json['preview_path'] as String?,
      faceCount:
          (json['face_count'] as num?)?.toInt() ??
          (facePaths.isEmpty ? 0 : facePaths.length),
      updatedAt: '${json['updated_at'] ?? ''}',
    );
  }

  final String id;
  final String name;
  final String? previewPath;
  final int faceCount;
  final String updatedAt;
}
