import 'dart:async';
import 'dart:io';

import 'package:faceswap_studio/shared/services/bridge_client.dart';
import 'package:faceswap_studio/shared/widgets/studio_media_viewer.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

class WorksPage extends StatefulWidget {
  const WorksPage({super.key});

  @override
  State<WorksPage> createState() => _WorksPageState();
}

class _WorksPageState extends State<WorksPage> {
  final BridgeClient _client = BridgeClient();
  Timer? _pollTimer;

  bool _requestInFlight = false;
  String _outputRoot = '';
  bool _loading = true;
  List<_WorkItem> _works = <_WorkItem>[];
  List<_WorkItem> _favorites = <_WorkItem>[];

  @override
  void initState() {
    super.initState();
    _refresh();
    _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  Future<T> _runWithoutPolling<T>(Future<T> Function() action) async {
    _pollTimer?.cancel();
    _pollTimer = null;
    try {
      return await action();
    } finally {
      if (mounted) {
        _startPolling();
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _refresh() async {
    if (_requestInFlight) {
      return;
    }
    _requestInFlight = true;
    try {
      final works = await _client.getWorks();
      final favorites = await _client.getFavorites();
      if (!mounted) {
        return;
      }
      setState(() {
        _outputRoot = '${works['output_root'] ?? ''}';
        _works = (works['items'] as List<dynamic>? ?? const <dynamic>[])
            .cast<Map<String, dynamic>>()
            .map(_WorkItem.fromJson)
            .toList();
        _favorites = (favorites['items'] as List<dynamic>? ?? const <dynamic>[])
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
    } finally {
      _requestInFlight = false;
    }
  }

  Future<void> _toggleFavorite(_WorkItem item) async {
    if (!item.canFavorite) {
      _showMessage(item.favoriteUnavailableMessage);
      return;
    }
    try {
      if (item.isFavorite) {
        await _client.unfavoriteWork(item.id);
        _showMessage('已取消收藏 ${item.fileName}');
      } else {
        await _client.favoriteWork(item.id);
        _showMessage('已收藏 ${item.fileName}');
      }
    } catch (error) {
      _showMessage('收藏操作失败：$error');
    } finally {
      await _refresh();
    }
  }

  Future<void> _deleteWork(_WorkItem item) async {
    if (item.isQueueBacked) {
      await _deleteQueueWork(item);
      return;
    }
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
      _showMessage('已删除 ${item.fileName}');
    } catch (error) {
      _showMessage('删除失败：$error');
    } finally {
      await _refresh();
    }
  }

  Future<void> _deleteQueueWork(_WorkItem item) async {
    final jobId = item.jobId;
    if (jobId == null || jobId.isEmpty) {
      _showMessage('任务记录缺少 jobId，无法删除。');
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除任务记录'),
        content: Text('确定从作品管理中移除失败任务 ${item.fileName} 吗？此操作不会删除作品文件。'),
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
      final result = await _client.deleteQueueTask(jobId);
      if (result['ok'] == false) {
        _showMessage('${result['message'] ?? '删除任务记录失败。'}');
      } else {
        _showMessage('已删除任务记录 ${item.fileName}');
      }
    } catch (error) {
      _showMessage('删除任务记录失败：$error');
    } finally {
      await _refresh();
    }
  }

  Future<void> _downloadWork(_WorkItem item) async {
    try {
      if (!item.canOpenOutput || item.path.isEmpty) {
        _showMessage(item.openUnavailableMessage);
        return;
      }
      final sourceFile = File(item.path);
      if (!await sourceFile.exists()) {
        _showMessage('原始文件不存在，无法下载。');
        return;
      }
      await _runWithoutPolling(() async {
        await WidgetsBinding.instance.endOfFrame;
        final location = await getSaveLocation(
          suggestedName: item.fileName,
          initialDirectory: sourceFile.parent.path,
          confirmButtonText: '保存',
        );
        if (location == null) {
          return;
        }
        if (_normalizePath(sourceFile.path) == _normalizePath(location.path)) {
          _showMessage('保存路径与原文件相同，无需下载。');
          return;
        }
        await sourceFile.copy(location.path);
        _showMessage('已保存到 ${location.path}');
      });
    } on FileSystemException catch (error) {
      _showMessage('下载失败：${error.message}');
    } catch (error) {
      _showMessage('下载失败：$error');
    }
  }

  Future<void> _showContextMenu(
    BuildContext context,
    Offset position,
    _WorkItem item,
  ) async {
    if (!item.canUseWorkActions) {
      _showMessage(item.openUnavailableMessage);
      return;
    }
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: _buildWorkMenuItems(item),
    );
    await _handleWorkMenuAction(action, item);
  }

  List<PopupMenuEntry<String>> _buildWorkMenuItems(_WorkItem item) {
    final items = <PopupMenuEntry<String>>[
      const PopupMenuItem<String>(
        value: 'download',
        child: _WorkMenuLabel(icon: Icons.download_rounded, label: '下载'),
      ),
    ];
    if (item.canOpenDirectory) {
      items.add(
        const PopupMenuItem<String>(
          value: 'open-directory',
          child: _WorkMenuLabel(
            icon: Icons.folder_open_rounded,
            label: '打开所在路径',
          ),
        ),
      );
    }
    items.addAll([
      PopupMenuItem<String>(
        value: 'favorite',
        child: _WorkMenuLabel(
          icon: item.isFavorite
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          label: item.isFavorite ? '取消收藏' : '收藏',
        ),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem<String>(
        value: 'delete',
        child: _WorkMenuLabel(
          icon: Icons.delete_outline_rounded,
          label: '删除',
          destructive: true,
        ),
      ),
    ]);
    return items;
  }

  Future<void> _handleWorkMenuAction(String? action, _WorkItem item) async {
    switch (action) {
      case 'download':
        await _downloadWork(item);
        return;
      case 'open-directory':
        await _openWorkDirectory(item);
        return;
      case 'favorite':
        await _toggleFavorite(item);
        return;
      case 'delete':
        await _deleteWork(item);
        return;
      default:
        return;
    }
  }

  String _normalizePath(String path) {
    return File(path).absolute.path.replaceAll('/', '\\').toLowerCase();
  }

  Future<void> _openWorkDirectory(_WorkItem item) async {
    if (!item.canOpenDirectory) {
      _showMessage(item.directoryUnavailableMessage);
      return;
    }
    try {
      final result = await _client.openWorkDirectory(item.id);
      if (result['ok'] != true) {
        _showMessage('${result['message'] ?? '打开所在路径失败。'}');
        return;
      }
      _showMessage('已打开 ${item.fileName} 所在目录');
    } catch (error) {
      _showMessage('打开所在路径失败：$error');
    }
  }

  Future<String?> _prepareVideoPlaybackPath(String path) async {
    try {
      final result = await _client.prepareVideoPlayback(path);
      if (result['ok'] != true) {
        _showMessage('${result['message'] ?? '视频播放准备失败。'}');
        return null;
      }
      final playbackPath = '${result['playback_path'] ?? path}';
      return playbackPath.isEmpty || playbackPath == 'null'
          ? path
          : playbackPath;
    } catch (error) {
      _showMessage('视频播放准备失败：$error');
      return null;
    }
  }

  Future<void> _openViewer(_WorkItem item) async {
    if (!item.canOpenOutput || item.path.isEmpty) {
      _showMessage(item.openUnavailableMessage);
      return;
    }
    if (!await File(item.path).exists()) {
      _showMessage('生成作品文件不存在：${item.path}');
      return;
    }
    if (!mounted) {
      return;
    }
    final mediaType = item.effectiveMediaType;
    final targetPath = item.targetPath;
    final canCompareWithTarget =
        targetPath != null &&
        targetPath.isNotEmpty &&
        item.targetMediaType == mediaType &&
        await File(targetPath).exists();
    if (!mounted) {
      return;
    }

    if (mediaType == 'image') {
      if (canCompareWithTarget) {
        await showStudioImageComparisonViewer(
          context,
          beforeFilePath: targetPath,
          afterFilePath: item.path,
          title: item.fileName,
        );
        return;
      }
      await showStudioImageViewer(
        context,
        filePath: item.path,
        title: item.fileName,
      );
      return;
    }
    if (mediaType == 'video') {
      final playbackPath = await _prepareVideoPlaybackPath(item.path);
      if (!mounted || playbackPath == null) {
        return;
      }
      if (canCompareWithTarget) {
        final targetPlaybackPath = await _prepareVideoPlaybackPath(targetPath);
        if (!mounted || targetPlaybackPath == null) {
          return;
        }
        await showStudioVideoComparisonViewer(
          context,
          beforeFilePath: targetPlaybackPath,
          afterFilePath: playbackPath,
          title: item.fileName,
        );
        return;
      }
      await showStudioVideoViewer(
        context,
        filePath: playbackPath,
        title: item.fileName,
      );
      return;
    }
    _showMessage('当前输出类型暂不支持全屏预览。');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('作品管理', style: theme.textTheme.headlineMedium),
            ),
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
          child: Text('当前没有可显示的作品。', style: theme.textTheme.titleMedium),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final gridWidth = constraints.maxWidth;
        final crossAxisCount = gridWidth >= 1280
            ? 4
            : gridWidth >= 860
            ? 3
            : gridWidth >= 560
            ? 2
            : 1;
        return GridView.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 14,
            mainAxisSpacing: 14,
            childAspectRatio: crossAxisCount == 1 ? 1.16 : 0.92,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return GestureDetector(
              onTap: () => _openViewer(item),
              onSecondaryTapDown: (details) =>
                  _showContextMenu(context, details.globalPosition, item),
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
                                ? const Color(0xFF20201E)
                                : const Color(0xFFF5F5F5),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                _buildWorkPreview(theme, item),
                                if (item.shouldShowStatus)
                                  Positioned(
                                    left: 10,
                                    top: 10,
                                    child: _WorkStatusBadge(item: item),
                                  ),
                                if (item.canUseWorkActions)
                                  Positioned(
                                    right: 10,
                                    top: 10,
                                    child: _buildWorkQuickMenu(theme, item),
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
                            const Icon(
                              Icons.favorite_rounded,
                              color: Color(0xFFE11D48),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        item.modifiedAt,
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (item.shouldShowProgress) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                item.progressPhaseLabel,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              '${item.progressPercent.toStringAsFixed(1)}%',
                              style: theme.textTheme.labelLarge,
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        TweenAnimationBuilder<double>(
                          tween: Tween<double>(
                            begin: 0,
                            end: (item.progressPercent / 100).clamp(0.0, 1.0),
                          ),
                          duration: const Duration(milliseconds: 450),
                          curve: Curves.easeOutCubic,
                          builder: (context, value, _) {
                            return LinearProgressIndicator(value: value);
                          },
                        ),
                        const SizedBox(height: 6),
                        Text(
                          item.progressDetail,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildWorkQuickMenu(ThemeData theme, _WorkItem item) {
    return Material(
      color: theme.colorScheme.surface.withValues(alpha: 0.88),
      shape: const CircleBorder(),
      child: PopupMenuButton<String>(
        tooltip: '作品操作',
        onSelected: (action) => _handleWorkMenuAction(action, item),
        itemBuilder: (_) => _buildWorkMenuItems(item),
        icon: Icon(
          Icons.more_horiz_rounded,
          color: theme.colorScheme.onSurface,
        ),
      ),
    );
  }

  Widget _buildWorkPreview(ThemeData theme, _WorkItem item) {
    if (item.canOpenOutput && item.path.isNotEmpty) {
      if (item.effectiveMediaType == 'video') {
        return StudioInlineVideoPlayer(
          filePath: item.path,
          thumbnailPath: item.thumbnailPath,
          fit: BoxFit.cover,
          onOpenFullscreen: () => _openViewer(item),
        );
      }
      return Padding(
        padding: const EdgeInsets.all(10),
        child: Image.file(
          File(item.path),
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) =>
              Icon(Icons.broken_image_outlined, color: theme.colorScheme.error),
        ),
      );
    }

    final thumbnailPath = item.thumbnailPath;
    if (thumbnailPath != null && thumbnailPath.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.all(10),
        child: Image.file(
          File(thumbnailPath),
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) =>
              Icon(Icons.pending_outlined, color: theme.colorScheme.primary),
        ),
      );
    }

    return Center(
      child: Icon(
        item.queueStatus == 'failed'
            ? Icons.error_outline_rounded
            : Icons.pending_outlined,
        size: 44,
        color: item.queueStatus == 'failed'
            ? theme.colorScheme.error
            : theme.colorScheme.primary,
      ),
    );
  }
}

class _WorkMenuLabel extends StatelessWidget {
  const _WorkMenuLabel({
    required this.icon,
    required this.label,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = destructive
        ? theme.colorScheme.error
        : theme.colorScheme.onSurface;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}

class _WorkStatusBadge extends StatelessWidget {
  const _WorkStatusBadge({required this.item});

  final _WorkItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _statusColor(theme);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        item.statusLabel,
        style: theme.textTheme.labelMedium?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Color _statusColor(ThemeData theme) {
    if (item.queueStatus == 'failed') {
      return theme.colorScheme.error;
    }
    if (item.queueStatus == 'completed' && !item.canOpenOutput) {
      return const Color(0xFFF59E0B);
    }
    if (item.queueStatus == 'completed') {
      return const Color(0xFF16A34A);
    }
    if (item.isActive) {
      return theme.colorScheme.primary;
    }
    return const Color(0xFF2563EB);
  }
}

class _WorkItem {
  const _WorkItem({
    required this.id,
    required this.path,
    required this.fileName,
    required this.mediaType,
    required this.thumbnailPath,
    required this.modifiedAt,
    required this.sizeBytes,
    required this.isFavorite,
    required this.source,
    required this.queueStatus,
    required this.progressPercent,
    required this.progressPhase,
    required this.progressDetail,
    required this.canOpenOutput,
    required this.isActive,
    required this.jobId,
    required this.outputPath,
    required this.outputMediaType,
    required this.targetPath,
    required this.targetMediaType,
    required this.sourcePaths,
  });

  factory _WorkItem.fromJson(Map<String, dynamic> json) {
    final rawPath = _readText(json['path']);
    final outputPath = _readNullableText(json['output_path']);
    final targetPath = _readNullableText(json['target_path']);
    final outputMediaType =
        _readNullableText(json['output_media_type']) ??
        _mediaTypeFromPath(outputPath ?? rawPath);
    final targetMediaType =
        _readNullableText(json['target_media_type']) ??
        _mediaTypeFromPath(targetPath);
    final canOpenOutput = json.containsKey('can_open_output')
        ? json['can_open_output'] == true
        : rawPath.isNotEmpty;
    final source = _readText(json['source'], fallback: 'file');
    final queueStatus = _readText(
      json['queue_status'],
      fallback: canOpenOutput ? 'completed' : 'queued',
    );
    final progressPercent =
        ((json['progress_percent'] as num?)?.toDouble() ??
                (canOpenOutput ? 100.0 : 0.0))
            .clamp(0.0, 100.0)
            .toDouble();
    return _WorkItem(
      id: _readText(json['id']),
      path: rawPath,
      fileName: _readText(json['file_name']),
      mediaType: _readText(
        json['media_type'],
        fallback: outputMediaType ?? 'image',
      ),
      thumbnailPath: json['thumbnail_path'] as String?,
      modifiedAt: _readText(json['modified_at']),
      sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
      isFavorite: json['is_favorite'] == true,
      source: source,
      queueStatus: queueStatus,
      progressPercent: progressPercent,
      progressPhase: _readText(
        json['progress_phase'],
        fallback: queueStatus == 'completed' ? 'completed' : 'queued',
      ),
      progressDetail: _readText(
        json['progress_detail'],
        fallback: queueStatus == 'completed' ? '作品已生成。' : '等待生成。',
      ),
      canOpenOutput: canOpenOutput,
      isActive: json['is_active'] == true,
      jobId: _readNullableText(json['job_id']),
      outputPath: outputPath,
      outputMediaType: outputMediaType,
      targetPath: targetPath,
      targetMediaType: targetMediaType,
      sourcePaths: (json['source_paths'] as List<dynamic>? ?? const <dynamic>[])
          .map((item) => '$item')
          .where((item) => item.isNotEmpty && item != 'null')
          .toList(),
    );
  }

  final String id;
  final String path;
  final String fileName;
  final String mediaType;
  final String? thumbnailPath;
  final String modifiedAt;
  final int sizeBytes;
  final bool isFavorite;
  final String source;
  final String queueStatus;
  final double progressPercent;
  final String progressPhase;
  final String progressDetail;
  final bool canOpenOutput;
  final bool isActive;
  final String? jobId;
  final String? outputPath;
  final String? outputMediaType;
  final String? targetPath;
  final String? targetMediaType;
  final List<String> sourcePaths;

  bool get isFileBacked => source == 'file';

  bool get isQueueBacked => source == 'queue';

  bool get canUseWorkActions =>
      (isFileBacked && canOpenOutput && path.isNotEmpty) || isQueueBacked;

  bool get canFavorite => isFileBacked && canOpenOutput && path.isNotEmpty;

  bool get canOpenDirectory => canOpenOutput && path.isNotEmpty;

  String get effectiveMediaType => outputMediaType ?? mediaType;

  bool get shouldShowStatus => isQueueBacked || !canOpenOutput;

  bool get shouldShowProgress => isQueueBacked || !canOpenOutput;

  String get statusLabel {
    if (queueStatus == 'completed' && !canOpenOutput) {
      return '输出缺失';
    }
    if (isActive) {
      return '生成中';
    }
    return switch (queueStatus) {
      'completed' => '已完成',
      'failed' => '失败',
      'drafted' => '草稿',
      'queued' => '队列中',
      _ => '等待中',
    };
  }

  String get progressPhaseLabel {
    if (queueStatus == 'completed' && !canOpenOutput) {
      return '输出文件不存在';
    }
    return switch (progressPhase) {
      'extracting' => '提取帧',
      'processing' => '处理帧',
      'merging' => '合成视频',
      'completed' => '已完成',
      'failed' => '失败',
      'running' => '生成中',
      _ => isActive ? '生成中' : '等待中',
    };
  }

  String get openUnavailableMessage {
    if (queueStatus == 'failed') {
      return '任务失败，暂无可打开的生成作品。';
    }
    if (queueStatus == 'completed') {
      return outputPath == null || outputPath!.isEmpty
          ? '任务已完成，但没有记录输出文件。'
          : '任务已完成，但输出文件不存在：$outputPath';
    }
    return '作品正在生成或等待执行，完成后即可打开。';
  }

  String get favoriteUnavailableMessage {
    if (queueStatus == 'failed') {
      return '任务失败，暂无可收藏的生成作品。';
    }
    if (queueStatus == 'completed') {
      return '输出文件不存在，无法收藏。';
    }
    return '作品生成完成后才能收藏。';
  }

  String get directoryUnavailableMessage {
    if (queueStatus == 'failed') {
      return '任务失败，暂无可打开的作品目录。';
    }
    if (queueStatus == 'completed') {
      return outputPath == null || outputPath!.isEmpty
          ? '任务已完成，但没有记录输出文件目录。'
          : '任务已完成，但输出文件不存在：$outputPath';
    }
    return '作品生成完成后才能打开所在路径。';
  }

  static String _readText(dynamic value, {String fallback = ''}) {
    if (value == null) {
      return fallback;
    }
    final text = '$value';
    if (text.isEmpty || text == 'null') {
      return fallback;
    }
    return text;
  }

  static String? _readNullableText(dynamic value) {
    final text = _readText(value);
    return text.isEmpty ? null : text;
  }

  static String? _mediaTypeFromPath(String? path) {
    if (path == null || path.isEmpty) {
      return null;
    }
    final extension = path.split('.').last.toLowerCase();
    if (const {
      'jpg',
      'jpeg',
      'png',
      'webp',
      'bmp',
      'tif',
      'tiff',
    }.contains(extension)) {
      return 'image';
    }
    if (const {'mp4', 'mov', 'mkv', 'avi', 'webm', 'm4v'}.contains(extension)) {
      return 'video';
    }
    return null;
  }
}
