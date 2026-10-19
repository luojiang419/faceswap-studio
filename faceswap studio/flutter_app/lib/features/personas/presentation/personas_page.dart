import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:faceswap_studio/app/theme/studio_depth.dart';
import 'package:faceswap_studio/shared/services/bridge_client.dart';
import 'package:faceswap_studio/shared/widgets/studio_media_viewer.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

const Set<String> _personaImageExtensions = {
  'jpg',
  'jpeg',
  'png',
  'webp',
  'bmp',
  'tiff',
};

const XTypeGroup _personaImageTypeGroup = XTypeGroup(
  label: '人物图片',
  extensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'tiff'],
);

bool _isPersonaImagePath(String path) {
  final extension = path.split('.').last.toLowerCase();
  return _personaImageExtensions.contains(extension);
}

class PersonasPage extends StatefulWidget {
  const PersonasPage({super.key});

  @override
  State<PersonasPage> createState() => _PersonasPageState();
}

class _PersonasPageState extends State<PersonasPage> {
  final BridgeClient _client = BridgeClient();
  final ScrollController _horizontalScroll = ScrollController();
  final ScrollController _verticalScroll = ScrollController();
  static Future<void>? _settingsWrites;
  Timer? _saveScaleTimer;
  double _gridScale = 100;
  int _scaleRevision = 0;
  bool _zoomHovered = false;
  bool _zoomPinned = false;

  bool _loading = true;
  bool _requestInFlight = false;
  String _root = '';
  List<_PersonaItem> _items = <_PersonaItem>[];

  @override
  void initState() {
    super.initState();
    _refresh();
    _loadGridScale();
  }

  @override
  void dispose() {
    if (_saveScaleTimer?.isActive ?? false) {
      _persistGridScale();
    }
    _horizontalScroll.dispose();
    _verticalScroll.dispose();
    super.dispose();
  }

  Future<void> _loadGridScale() async {
    final revision = _scaleRevision;
    try {
      // 新页面读取前等待上一页面的最后一次写入。
      await _settingsWrites;
      final settings = await _client.getSettings();
      final value = settings['persona_grid_scale'];
      if (!mounted || revision != _scaleRevision) return;
      if (value is num && value.isFinite) {
        setState(() => _gridScale = value.toDouble().clamp(10, 800));
      }
    } catch (error) {
      _showMessage('读取人物尺寸设置失败：$error');
    }
  }

  void _setGridScale(double value) {
    final next = value.roundToDouble().clamp(10.0, 800.0);
    if (next == _gridScale) return;
    setState(() {
      _gridScale = next;
      _scaleRevision++;
    });
    _saveScaleTimer?.cancel();
    _saveScaleTimer = Timer(
      const Duration(milliseconds: 250),
      _persistGridScale,
    );
  }

  void _persistGridScale() {
    _saveScaleTimer?.cancel();
    final value = _gridScale;
    // 串行写入，防止旧请求晚返回覆盖最新倍率。
    late final Future<void> write;
    write = (_settingsWrites ?? Future<void>.value())
        .then((_) async {
          try {
            final saved = await _client.updateSettings({
              'persona_grid_scale': value,
            });
            if (saved['persona_grid_scale'] != value) {
              throw StateError('服务未保存尺寸设置，请重启应用后重试。');
            }
          } catch (error) {
            _showMessage('保存人物尺寸设置失败：$error');
          }
        })
        .whenComplete(() {
          if (identical(_settingsWrites, write)) _settingsWrites = null;
        });
    _settingsWrites = write;
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        !HardwareKeyboard.instance.isControlPressed) {
      return;
    }
    final delta = event.scrollDelta.dy != 0
        ? event.scrollDelta.dy
        : event.scrollDelta.dx;
    if (delta == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      _setGridScale(_gridScale - delta.sign * 10);
    });
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
      final result = await _client.getPersonas();
      if (!mounted) {
        return;
      }
      setState(() {
        _root = '${result['root'] ?? ''}';
        _items = (result['items'] as List<dynamic>? ?? const <dynamic>[])
            .cast<Map<String, dynamic>>()
            .map(_PersonaItem.fromJson)
            .toList();
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
      });
      _showMessage('加载人物形象库失败：$error');
    } finally {
      _requestInFlight = false;
    }
  }

  Future<void> _usePersona(_PersonaItem item) async {
    try {
      final result = await _client.usePersona(item.id);
      _showMessage('${result['message'] ?? '已加载人物形象。'}');
    } catch (error) {
      _showMessage('加载人物形象失败：$error');
    }
  }

  Future<void> _openPersonaGallery(_PersonaItem item) async {
    final filePaths = <String>[];
    for (final path in item.facePaths) {
      if (await File(path).exists()) {
        filePaths.add(path);
      }
    }
    if (!mounted) {
      return;
    }
    if (filePaths.isEmpty) {
      _showMessage('人物形象图片不存在，无法浏览。');
      return;
    }
    await showStudioImageGalleryViewer(
      context,
      filePaths: filePaths,
      title: item.name,
    );
  }

  Future<void> _addPersona() async {
    final request = await showDialog<_PersonaCreateRequest>(
      context: context,
      builder: (context) => const _AddPersonaDialog(),
    );
    if (!mounted || request == null) {
      return;
    }

    try {
      final result = await _client.savePersonaFromImages(
        request.name,
        request.paths,
      );
      _showMessage('${result['message'] ?? '人物形象保存完成。'}');
      await _refresh();
    } catch (error) {
      _showMessage('保存人物形象失败：$error');
    }
  }

  Future<void> _openDirectory(_PersonaItem item) async {
    try {
      final result = await _client.openPersonaDirectory(item.id);
      if (result['ok'] == false) {
        _showMessage('${result['message'] ?? '打开目录失败。'}');
      }
    } catch (error) {
      _showMessage('打开目录失败：$error');
    }
  }

  Future<void> _deletePersona(_PersonaItem item) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除人物形象'),
        content: Text('确定删除 ${item.name} 以及对应的本地文件吗？'),
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
      final result = await _client.deletePersona(item.id);
      if (!mounted) {
        return;
      }
      setState(() {
        _items = (result['items'] as List<dynamic>? ?? const <dynamic>[])
            .cast<Map<String, dynamic>>()
            .map(_PersonaItem.fromJson)
            .toList();
      });
      _showMessage('${result['message'] ?? '已删除人物形象。'}');
    } catch (error) {
      _showMessage('删除人物形象失败：$error');
    }
  }

  Future<void> _handleAction(String action, _PersonaItem item) async {
    switch (action) {
      case 'use':
        await _usePersona(item);
        return;
      case 'open':
        await _openDirectory(item);
        return;
      case 'delete':
        await _deletePersona(item);
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) => Listener(
        onPointerSignal: _handlePointerSignal,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: scheme.outlineVariant),
                    boxShadow: StudioDepth.shadows(context, subtle: true),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('人物形象', style: theme.textTheme.headlineMedium),
                            const SizedBox(height: 8),
                            Text(
                              _root.isEmpty ? '人物形象库' : _root,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton(
                        onPressed: _refresh,
                        icon: const Icon(Icons.refresh_rounded),
                        tooltip: '刷新人物形象',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: Color.lerp(
                        scheme.surface,
                        scheme.surfaceContainer,
                        0.3,
                      ),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: scheme.outlineVariant),
                      boxShadow: StudioDepth.shadows(context, subtle: true),
                    ),
                    child: _buildGrid(theme),
                  ),
                ),
              ],
            ),
            Positioned(
              right: 16,
              bottom: 88,
              child: MouseRegion(
                onEnter: (_) => setState(() => _zoomHovered = true),
                onExit: (_) => setState(() => _zoomHovered = false),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_zoomHovered || _zoomPinned)
                      Container(
                        width: math.min(
                          320,
                          math.max(0, constraints.maxWidth - 32),
                        ),
                        margin: const EdgeInsets.only(bottom: 8),
                        child: Card(
                          elevation: 6,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  children: [
                                    const Expanded(child: Text('人物格子尺寸')),
                                    Text('${_gridScale.round()}%'),
                                    IconButton(
                                      tooltip: '恢复 100%',
                                      onPressed: () => _setGridScale(100),
                                      icon: const Icon(
                                        Icons.restart_alt_rounded,
                                      ),
                                    ),
                                  ],
                                ),
                                Slider(
                                  key: const ValueKey(
                                    'persona-grid-scale-slider',
                                  ),
                                  value: _gridScale,
                                  min: 10,
                                  max: 800,
                                  divisions: 79,
                                  label: '${_gridScale.round()}%',
                                  onChanged: _setGridScale,
                                  onChangeEnd: (_) => _persistGridScale(),
                                ),
                                Text(
                                  '10%–800% · Ctrl＋滚轮',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    FloatingActionButton.small(
                      heroTag: 'persona-grid-scale',
                      tooltip: '调节人物格子尺寸（Ctrl＋滚轮）',
                      onPressed: () =>
                          setState(() => _zoomPinned = !_zoomPinned),
                      child: const Icon(Icons.photo_size_select_large_rounded),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              right: 16,
              bottom: 16,
              child: FloatingActionButton.extended(
                onPressed: _addPersona,
                icon: const Icon(Icons.person_add_alt_1_outlined),
                label: const Text('添加人物'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return Card(
        child: Center(
          child: Text('当前没有人物形象。', style: theme.textTheme.titleMedium),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        const cardWidth = 344.0;
        const cardHeight = 400.0;
        const gap = 14.0;
        final scale = _gridScale / 100;
        final width = cardWidth * scale;
        final height = cardHeight * scale;
        final columns = math.max(
          1,
          ((constraints.maxWidth + gap) / (width + gap)).floor(),
        );
        final gridWidth = width * columns + gap * (columns - 1);
        return Scrollbar(
          controller: _horizontalScroll,
          thumbVisibility: gridWidth > constraints.maxWidth,
          notificationPredicate: (notification) =>
              notification.metrics.axis == Axis.horizontal,
          child: SingleChildScrollView(
            controller: _horizontalScroll,
            scrollDirection: Axis.horizontal,
            physics: const _PersonaScrollPhysics(),
            child: SizedBox(
              width: math.max(constraints.maxWidth, gridWidth),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: gridWidth,
                  child: GridView.builder(
                    key: const ValueKey('persona-grid'),
                    controller: _verticalScroll,
                    physics: const _PersonaScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 152),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: gap,
                      mainAxisSpacing: gap,
                      mainAxisExtent: height,
                    ),
                    itemCount: _items.length,
                    itemBuilder: (context, index) {
                      final item = _items[index];
                      return FittedBox(
                        fit: BoxFit.fill,
                        child: SizedBox(
                          width: cardWidth,
                          height: cardHeight,
                          child: _PersonaCard(
                            item: item,
                            onTap: () => _openPersonaGallery(item),
                            onAction: (action) => _handleAction(action, item),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PersonaScrollPhysics extends ClampingScrollPhysics {
  const _PersonaScrollPhysics({super.parent});

  @override
  _PersonaScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _PersonaScrollPhysics(parent: buildParent(ancestor));

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) =>
      !HardwareKeyboard.instance.isControlPressed &&
      super.shouldAcceptUserOffset(position);
}

class _PersonaCard extends StatelessWidget {
  const _PersonaCard({
    required this.item,
    required this.onTap,
    required this.onAction,
  });

  final _PersonaItem item;
  final VoidCallback onTap;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
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
                        _PersonaPreview(item: item),
                        Positioned(
                          right: 10,
                          top: 10,
                          child: Material(
                            color: theme.colorScheme.surface.withValues(
                              alpha: 0.88,
                            ),
                            shape: const CircleBorder(),
                            child: PopupMenuButton<String>(
                              tooltip: '人物形象操作',
                              onSelected: onAction,
                              icon: Icon(
                                Icons.more_horiz_rounded,
                                color: theme.colorScheme.onSurface,
                              ),
                              itemBuilder: (_) => const [
                                PopupMenuItem<String>(
                                  value: 'use',
                                  child: _PersonaMenuLabel(
                                    icon: Icons.check_circle_outline_rounded,
                                    label: '使用',
                                  ),
                                ),
                                PopupMenuItem<String>(
                                  value: 'open',
                                  child: _PersonaMenuLabel(
                                    icon: Icons.folder_open_rounded,
                                    label: '打开目录',
                                  ),
                                ),
                                PopupMenuDivider(),
                                PopupMenuItem<String>(
                                  value: 'delete',
                                  child: _PersonaMenuLabel(
                                    icon: Icons.delete_outline_rounded,
                                    label: '删除',
                                    destructive: true,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                item.name,
                style: theme.textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Text(
                '${item.faceCount} 张角度图 · ${item.updatedAt}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PersonaPreview extends StatelessWidget {
  const _PersonaPreview({required this.item});

  final _PersonaItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final previewPath = item.previewPath;
    if (previewPath == null || previewPath.isEmpty) {
      return Center(
        child: Icon(
          Icons.face_retouching_natural_rounded,
          size: 52,
          color: theme.colorScheme.primary,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Image.file(
        File(previewPath),
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) =>
            Icon(Icons.broken_image_outlined, color: theme.colorScheme.error),
      ),
    );
  }
}

class _PersonaMenuLabel extends StatelessWidget {
  const _PersonaMenuLabel({
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

class _PersonaCreateRequest {
  const _PersonaCreateRequest({required this.name, required this.paths});

  final String name;
  final List<String> paths;
}

class _AddPersonaDialog extends StatefulWidget {
  const _AddPersonaDialog();

  @override
  State<_AddPersonaDialog> createState() => _AddPersonaDialogState();
}

class _AddPersonaDialogState extends State<_AddPersonaDialog> {
  final TextEditingController _nameController = TextEditingController();
  List<String> _paths = <String>[];
  bool _dragging = false;

  bool get _canSave =>
      _nameController.text.trim().isNotEmpty && _paths.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _nameController.addListener(_handleNameChanged);
  }

  @override
  void dispose() {
    _nameController.removeListener(_handleNameChanged);
    _nameController.dispose();
    super.dispose();
  }

  void _handleNameChanged() {
    setState(() {});
  }

  String _normalizePath(String path) {
    return File(path).absolute.path.toLowerCase();
  }

  void _addPaths(Iterable<String> paths) {
    final nextPaths = List<String>.of(_paths);
    final normalized = nextPaths.map(_normalizePath).toSet();
    for (final rawPath in paths) {
      final path = rawPath.trim();
      if (path.isEmpty ||
          !_isPersonaImagePath(path) ||
          !File(path).existsSync()) {
        continue;
      }
      final normalizedPath = _normalizePath(path);
      if (normalized.add(normalizedPath)) {
        nextPaths.add(path);
      }
    }
    setState(() {
      _paths = nextPaths;
    });
  }

  Future<void> _pickImages() async {
    final files = await openFiles(
      acceptedTypeGroups: const [_personaImageTypeGroup],
    );
    if (files.isEmpty) {
      return;
    }
    _addPaths(files.map((file) => file.path));
  }

  void _removePath(String path) {
    setState(() {
      _paths = _paths.where((item) => item != path).toList();
    });
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty || _paths.isEmpty) {
      return;
    }
    Navigator.of(context).pop(
      _PersonaCreateRequest(
        name: name,
        paths: List<String>.unmodifiable(_paths),
      ),
    );
  }

  String _fileName(String path) {
    return path.split(Platform.pathSeparator).last;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('添加人物'),
      content: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: '人物名称'),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                if (_canSave) {
                  _submit();
                }
              },
            ),
            const SizedBox(height: 16),
            DropTarget(
              onDragDone: (detail) {
                _addPaths(detail.files.map((file) => file.path));
              },
              onDragEntered: (_) {
                setState(() {
                  _dragging = true;
                });
              },
              onDragExited: (_) {
                setState(() {
                  _dragging = false;
                });
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: double.infinity,
                height: 164,
                decoration: BoxDecoration(
                  color: _dragging
                      ? theme.colorScheme.primaryContainer.withValues(
                          alpha: 0.36,
                        )
                      : theme.colorScheme.surfaceContainerHighest.withValues(
                          alpha: 0.42,
                        ),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _dragging
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outlineVariant,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.add_photo_alternate_outlined,
                      size: 34,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 10),
                    Text('拖拽图片到这里', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _pickImages,
                      icon: const Icon(Icons.folder_open_rounded),
                      label: const Text('选择图片'),
                    ),
                  ],
                ),
              ),
            ),
            if (_paths.isNotEmpty) ...[
              const SizedBox(height: 14),
              SizedBox(
                height: 156,
                child: ListView.separated(
                  itemCount: _paths.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final path = _paths[index];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.image_outlined),
                      title: Text(
                        _fileName(path),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        onPressed: () => _removePath(path),
                        icon: const Icon(Icons.close_rounded),
                        tooltip: '移除',
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _canSave ? _submit : null,
          icon: const Icon(Icons.save_outlined),
          label: const Text('保存人物'),
        ),
      ],
    );
  }
}

class _PersonaItem {
  const _PersonaItem({
    required this.id,
    required this.name,
    required this.previewPath,
    required this.facePaths,
    required this.faceCount,
    required this.updatedAt,
  });

  factory _PersonaItem.fromJson(Map<String, dynamic> json) {
    final facePaths =
        (json['face_paths'] as List<dynamic>? ?? const <dynamic>[])
            .map((item) => '$item')
            .where((item) => item.isNotEmpty && item != 'null')
            .toList();
    return _PersonaItem(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? '未命名人物'}',
      previewPath: json['preview_path'] as String?,
      facePaths: facePaths,
      faceCount:
          (json['face_count'] as num?)?.toInt() ??
          (facePaths.isEmpty ? 0 : facePaths.length),
      updatedAt: '${json['updated_at'] ?? ''}',
    );
  }

  final String id;
  final String name;
  final String? previewPath;
  final List<String> facePaths;
  final int faceCount;
  final String updatedAt;
}
