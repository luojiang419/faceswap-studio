import 'dart:async';
import 'dart:io';

import 'package:faceswap_studio/shared/services/bridge_client.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:super_clipboard/super_clipboard.dart';

class WorksPage extends StatefulWidget {
  const WorksPage({super.key});

  @override
  State<WorksPage> createState() => _WorksPageState();
}

class _WorksPageState extends State<WorksPage> {
  final BridgeClient _client = BridgeClient();
  Timer? _pollTimer;

  String _outputRoot = '';
  bool _loading = true;
  List<_WorkItem> _works = <_WorkItem>[];
  List<_WorkItem> _favorites = <_WorkItem>[];

  @override
  void initState() {
    super.initState();
    _refresh();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final works = await _client.getWorks();
      final favorites = await _client.getFavorites();
      if (!mounted) {
        return;
      }
      setState(() {
        _outputRoot = '${works['output_root'] ?? ''}';
        _works =
            (works['items'] as List<dynamic>? ?? const <dynamic>[])
                .cast<Map<String, dynamic>>()
                .map(_WorkItem.fromJson)
                .toList();
        _favorites =
            (favorites['items'] as List<dynamic>? ?? const <dynamic>[])
                .cast<Map<String, dynamic>>()
                .map(_WorkItem.fromJson)
                .toList();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _toggleFavorite(_WorkItem item) async {
    try {
      if (item.isFavorite) {
        await _client.unfavoriteWork(item.id);
      } else {
        await _client.favoriteWork(item.id);
      }
    } catch (_) {
    } finally {
      await _refresh();
    }
  }

  Future<void> _deleteWork(_WorkItem item) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除作品'),
        content: Text('确定删除 ${item.fileName} 以及对应的本地文件吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm != true) {
      return;
    }
    try {
      await _client.deleteWork(item.id);
    } catch (_) {
    } finally {
      await _refresh();
    }
  }

  Future<void> _downloadWork(_WorkItem item) async {
    final location = await getSaveLocation(suggestedName: item.fileName);
    if (location == null) {
      return;
    }
    await File(item.path).copy(location.path);
  }

  Future<void> _copyImageToClipboard(_WorkItem item) async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) {
      return;
    }
    final rawBytes = await File(item.path).readAsBytes();
    final decoded = img.decodeImage(rawBytes);
    if (decoded == null) {
      return;
    }
    final pngBytes = Uint8List.fromList(img.encodePng(decoded));
    final writer = DataWriterItem()..add(Formats.png(pngBytes));
    await clipboard.write([writer]);
  }

  Future<void> _showContextMenu(BuildContext context, Offset position, _WorkItem item) async {
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: [
        const PopupMenuItem<String>(value: 'download', child: Text('下载')),
        if (item.mediaType == 'image')
          const PopupMenuItem<String>(value: 'copy', child: Text('复制')),
        PopupMenuItem<String>(
          value: 'favorite',
          child: Text(item.isFavorite ? '取消收藏' : '收藏'),
        ),
        const PopupMenuItem<String>(value: 'delete', child: Text('删除')),
      ],
    );
    switch (action) {
      case 'download':
        await _downloadWork(item);
      case 'copy':
        await _copyImageToClipboard(item);
      case 'favorite':
        await _toggleFavorite(item);
      case 'delete':
        await _deleteWork(item);
      default:
        break;
    }
  }

  Future<void> _openViewer(_WorkItem item) async {
    if (item.mediaType == 'image') {
      await showDialog<void>(
        context: context,
        barrierColor: Colors.black87,
        builder: (context) => _ImageViewerDialog(item: item),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) => _VideoViewerDialog(item: item),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('作品管理', style: theme.textTheme.headlineMedium)),
            IconButton(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh_rounded),
              tooltip: '刷新作品',
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _outputRoot.isEmpty ? '这里会展示生成的图片和视频作品。' : '当前输出目录：$_outputRoot',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 18),
        Expanded(
          child: DefaultTabController(
            length: 2,
            child: Column(
              children: [
                const TabBar(
                  tabs: [
                    Tab(text: '作品管理'),
                    Tab(text: '收藏'),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: TabBarView(
                    children: [
                      _buildWorksGrid(theme, _works),
                      _buildWorksGrid(theme, _favorites),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWorksGrid(ThemeData theme, List<_WorkItem> items) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (items.isEmpty) {
      return Card(
        child: Center(
          child: Text(
            '当前没有可显示的作品。',
            style: theme.textTheme.titleMedium,
          ),
        ),
      );
    }
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
        childAspectRatio: 1.08,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return GestureDetector(
          onTap: () => _openViewer(item),
          onSecondaryTapDown: (details) => _showContextMenu(context, details.globalPosition, item),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: Container(
                        width: double.infinity,
                        color: theme.brightness == Brightness.dark
                            ? const Color(0xFF0A1420)
                            : const Color(0xFFEAF2F8),
                        child: item.mediaType == 'image'
                            ? Image.file(
                                File(item.path),
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
                              )
                            : Stack(
                                fit: StackFit.expand,
                                children: [
                                  Container(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: theme.brightness == Brightness.dark
                                            ? const [Color(0xFF12263A), Color(0xFF0A1522)]
                                            : const [Color(0xFFD6EEF6), Color(0xFFF6FBFD)],
                                      ),
                                    ),
                                  ),
                                  const Center(
                                    child: Icon(Icons.play_circle_fill_rounded, size: 56),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.fileName,
                          style: theme.textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (item.isFavorite)
                        const Icon(Icons.favorite_rounded, color: Color(0xFFE11D48)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    item.modifiedAt,
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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

class _ImageViewerDialog extends StatelessWidget {
  const _ImageViewerDialog({required this.item});

  final _WorkItem item;

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Stack(
        children: [
          Center(
            child: InteractiveViewer(
              minScale: 0.25,
              maxScale: 8.0,
              child: Image.file(
                File(item.path),
                fit: BoxFit.contain,
              ),
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
    );
  }
}

class _VideoViewerDialog extends StatefulWidget {
  const _VideoViewerDialog({required this.item});

  final _WorkItem item;

  @override
  State<_VideoViewerDialog> createState() => _VideoViewerDialogState();
}

class _VideoViewerDialogState extends State<_VideoViewerDialog> {
  late final Player _player;
  late final VideoController _controller;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _player.open(Media(widget.item.path));
  }

  @override
  void dispose() {
    _focusNode.dispose();
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

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: KeyboardListener(
        autofocus: true,
        focusNode: _focusNode,
        onKeyEvent: (event) {
          if (event.logicalKey == LogicalKeyboardKey.space && event is KeyDownEvent) {
            _togglePlayback();
          }
        },
        child: Stack(
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Video(controller: _controller),
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

class _WorkItem {
  const _WorkItem({
    required this.id,
    required this.path,
    required this.fileName,
    required this.mediaType,
    required this.modifiedAt,
    required this.sizeBytes,
    required this.isFavorite,
  });

  factory _WorkItem.fromJson(Map<String, dynamic> json) {
    return _WorkItem(
      id: '${json['id'] ?? ''}',
      path: '${json['path'] ?? ''}',
      fileName: '${json['file_name'] ?? ''}',
      mediaType: '${json['media_type'] ?? 'image'}',
      modifiedAt: '${json['modified_at'] ?? ''}',
      sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
      isFavorite: json['is_favorite'] == true,
    );
  }

  final String id;
  final String path;
  final String fileName;
  final String mediaType;
  final String modifiedAt;
  final int sizeBytes;
  final bool isFavorite;
}
