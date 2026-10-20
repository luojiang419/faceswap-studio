import 'package:faceswap_studio/app/theme/studio_depth.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:faceswap_studio/shared/services/bridge_client.dart';
import 'package:faceswap_studio/shared/services/studio_file_picker.dart';
import 'package:faceswap_studio/shared/widgets/studio_media_viewer.dart';
import 'package:faceswap_studio/shared/widgets/studio_media_loading.dart';
import 'package:faceswap_studio/shared/widgets/studio_hover_focus.dart';
import 'package:faceswap_studio/shared/widgets/studio_file_drop_region.dart';
import 'package:faceswap_studio/shared/widgets/studio_frame_scrubber.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:webview_all/webview_all.dart';

import 'workspace_options_panel.dart';

class WorkspacePage extends StatefulWidget {
  const WorkspacePage({super.key});

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

// 两个标签页共用提交/运行状态；旧轮询不能覆盖一次更新后的状态。
class _WorkspaceGenerationState extends ChangeNotifier {
  bool _running = false;
  bool submitting = false;
  int revision = 0;
  bool get active => _running || submitting;

  bool begin() {
    if (active) return false;
    submitting = true;
    revision++;
    notifyListeners();
    return true;
  }

  void finish(bool? running) {
    submitting = false;
    _running = running ?? true;
    revision++;
    notifyListeners();
  }

  void apply(bool running, int observedRevision) {
    if (submitting || revision != observedRevision || _running == running) {
      return;
    }
    _running = running;
    revision++;
    notifyListeners();
  }
}

class _WorkspacePageState extends State<WorkspacePage> {
  final _generation = _WorkspaceGenerationState();

  @override
  void dispose() {
    _generation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(height: 32, text: '操作台'),
              Tab(height: 32, text: '生成队列'),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: TabBarView(
              children: [
                _OperationWorkbench(generation: _generation),
                _QueueBoard(generation: _generation),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<bool> _confirmWorkspaceAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final theme = Theme.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                )
              : null,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed == true;
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
            hintText: '例如：张三正装',
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

class _OperationWorkbench extends StatefulWidget {
  const _OperationWorkbench({required this.generation});
  final _WorkspaceGenerationState generation;

  @override
  State<_OperationWorkbench> createState() => _OperationWorkbenchState();
}

class _OperationWorkbenchState extends State<_OperationWorkbench>
    with AutomaticKeepAliveClientMixin {
  static const double _defaultWorkspaceOptionsPanelWidth = 430.0;
  static const double _minWorkspaceOptionsPanelWidth = 320.0;
  static const double _maxWorkspaceOptionsPanelWidth = 760.0;

  final BridgeClient _client = BridgeClient();

  Timer? _pollTimer;
  WebViewController? _controller;
  Widget? _webViewWidget;

  bool _requestInFlight = false;
  bool _actionInFlight = false;
  bool _sourceImporting = false;
  bool _targetImporting = false;
  int _workspaceDraftRevision = 0;
  int _sourceProcessed = 0;
  int _sourceTotal = 0;
  int _sourceRecognized = 0;
  int _sourceSkipped = 0;
  Timer? _sourceProgressTimer;
  String? _sourceRequestId;
  bool _bridgeOnline = false;
  bool _controllerReady = false;
  bool _isPinned = true;
  bool _previewInFlight = false;
  int? _lastVideoFrameTotal;
  String _serviceState = 'stopped';
  String _webuiUrl = 'http://127.0.0.1:7860';
  String _workspaceMessage = '选择源文件和目标文件后即可添加到队列或立即生成。';
  String _previewMessage = '';
  int _pageProgress = 0;
  String? _lastLoadedUrl;
  double _workspaceOptionsPanelWidth = _defaultWorkspaceOptionsPanelWidth;
  _WorkspaceDraft? _workspaceDraft;
  WorkspaceOptionsSchema? _workspaceOptionsSchema;
  WorkspaceOptionsState? _workspaceOptionsState;
  _WorkspacePreviewResult? _workspacePreviewResult;

  @override
  bool get wantKeepAlive => true;

  bool get _useNativeWorkbenchMode => Platform.isWindows;
  bool get _generationActive => widget.generation.active;

  void _generationChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.generation.addListener(_generationChanged);
    if (!_useNativeWorkbenchMode) {
      _initController();
    } else {
      _loadWorkspacePanelWidth();
    }
    _refresh();
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 1200),
      (_) => _refresh(),
    );
  }

  double _normalizeWorkspacePanelWidth(dynamic value) {
    final parsedValue = value is num
        ? value.toDouble()
        : double.tryParse('$value') ?? _defaultWorkspaceOptionsPanelWidth;
    return parsedValue
        .clamp(_minWorkspaceOptionsPanelWidth, _maxWorkspaceOptionsPanelWidth)
        .toDouble();
  }

  Future<void> _loadWorkspacePanelWidth() async {
    try {
      final settings = await _client.getSettings();
      if (!mounted) {
        return;
      }
      setState(() {
        _workspaceOptionsPanelWidth = _normalizeWorkspacePanelWidth(
          settings['workspace_options_panel_width'],
        );
      });
    } catch (_) {}
  }

  void _setWorkspacePanelWidth(double width) {
    final normalizedWidth = _normalizeWorkspacePanelWidth(width);
    if ((_workspaceOptionsPanelWidth - normalizedWidth).abs() < 0.5) {
      return;
    }
    setState(() {
      _workspaceOptionsPanelWidth = normalizedWidth;
    });
  }

  Future<void> _persistWorkspacePanelWidth(double width) async {
    final normalizedWidth = _normalizeWorkspacePanelWidth(width);
    _setWorkspacePanelWidth(normalizedWidth);
    try {
      final settings = await _client.updateSettings({
        'workspace_options_panel_width': normalizedWidth,
      });
      if (!mounted) {
        return;
      }
      setState(() {
        _workspaceOptionsPanelWidth = _normalizeWorkspacePanelWidth(
          settings['workspace_options_panel_width'],
        );
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _workspaceMessage = '参数面板宽度保存失败: $error';
      });
    }
  }

  @override
  void dispose() {
    widget.generation.removeListener(_generationChanged);
    _pollTimer?.cancel();
    _sourceProgressTimer?.cancel();
    super.dispose();
  }

  void _initController() {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {
            if (!mounted) {
              return;
            }
            setState(() {
              _pageProgress = progress;
            });
          },
          onPageStarted: (String url) {
            if (!mounted) {
              return;
            }
            setState(() {
              _pageProgress = 5;
            });
          },
          onPageFinished: (String url) {
            if (!mounted) {
              return;
            }
            setState(() {
              _pageProgress = 100;
            });
          },
          onNavigationRequest: (NavigationRequest request) {
            return NavigationDecision.navigate;
          },
        ),
      );

    _controller = controller;
    _webViewWidget = WebViewWidget(controller: controller);
    _controllerReady = true;
  }

  Future<void> _refresh() async {
    if (_requestInFlight) {
      return;
    }
    _requestInFlight = true;
    final draftRevision = _workspaceDraftRevision;
    final generationRevision = widget.generation.revision;
    try {
      final results = await Future.wait<dynamic>([
        _client.getStatus(),
        if (_useNativeWorkbenchMode) _client.getWorkspaceDraft(),
        if (_useNativeWorkbenchMode) _client.getWorkspaceOptions(),
        if (_useNativeWorkbenchMode && _workspaceOptionsSchema == null)
          _client.getWorkspaceOptionsSchema(),
      ]);
      final status = results[0] as Map<String, dynamic>;
      final state = '${status['state'] ?? 'unknown'}';
      final webuiUrl = '${status['webui_url'] ?? _webuiUrl}';
      final workspaceDraft = _useNativeWorkbenchMode
          ? _WorkspaceDraft.fromJson(results[1] as Map<String, dynamic>)
          : null;
      final workspaceOptionsState = _useNativeWorkbenchMode
          ? WorkspaceOptionsState.fromJson(results[2] as Map<String, dynamic>)
          : null;
      final workspaceOptionsSchema =
          _useNativeWorkbenchMode && results.length > 3
          ? WorkspaceOptionsSchema.fromJson(results[3] as Map<String, dynamic>)
          : null;

      if (!mounted) {
        return;
      }

      final wasReady = _serviceState == 'ready';
      if (_useNativeWorkbenchMode) {
        widget.generation.apply(
          (results[1] as Map<String, dynamic>)['generation_active'] == true,
          generationRevision,
        );
      }

      setState(() {
        _bridgeOnline = true;
        _serviceState = state;
        _webuiUrl = webuiUrl;
        if (draftRevision == _workspaceDraftRevision) {
          _workspaceDraft = workspaceDraft ?? _workspaceDraft;
        }
        _workspaceOptionsState =
            workspaceOptionsState ?? _workspaceOptionsState;
        _workspaceOptionsSchema =
            workspaceOptionsSchema ?? _workspaceOptionsSchema;
      });

      if (_isWebUiReady && !_useNativeWorkbenchMode) {
        await _loadWebUiIfNeeded(force: !wasReady);
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _bridgeOnline = false;
        _serviceState = 'bridge_offline';
      });
    } finally {
      _requestInFlight = false;
    }
  }

  Future<void> _updateWorkspaceOptions(
    Map<String, dynamic> payload, {
    bool clearPreview = true,
  }) async {
    if (_actionInFlight || _generationActive) {
      return;
    }
    setState(() {
      _actionInFlight = true;
    });
    try {
      final results = await Future.wait<dynamic>([
        _client.updateWorkspaceOptions(payload),
        _client.getWorkspaceOptionsSchema(),
      ]);
      final optionsState = WorkspaceOptionsState.fromJson(
        results[0] as Map<String, dynamic>,
      );
      final optionsSchema = WorkspaceOptionsSchema.fromJson(
        results[1] as Map<String, dynamic>,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _workspaceOptionsState = optionsState;
        _workspaceOptionsSchema = optionsSchema;
        if (clearPreview) {
          _workspacePreviewResult = null;
          _lastVideoFrameTotal = null;
        }
        _previewMessage = '参数已更新，请重新生成预览以确认当前效果。';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _workspaceMessage = '参数更新失败: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _actionInFlight = false;
        });
      }
    }
  }

  Future<void> _resetWorkspaceOptions() async {
    if (_actionInFlight) {
      return;
    }
    final confirmed = await _confirmWorkspaceAction(
      context,
      title: '重置参数面板',
      message: '确定将参数面板恢复为默认值吗？当前参数草稿会被覆盖。',
      confirmLabel: '重置',
      destructive: true,
    );
    if (!mounted || !confirmed) {
      return;
    }
    setState(() {
      _actionInFlight = true;
    });
    try {
      final results = await Future.wait<dynamic>([
        _client.resetWorkspaceOptions(),
        _client.getWorkspaceOptionsSchema(),
      ]);
      final optionsState = WorkspaceOptionsState.fromJson(
        results[0] as Map<String, dynamic>,
      );
      final optionsSchema = WorkspaceOptionsSchema.fromJson(
        results[1] as Map<String, dynamic>,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _workspaceOptionsState = optionsState;
        _workspaceOptionsSchema = optionsSchema;
        _workspacePreviewResult = null;
        _lastVideoFrameTotal = null;
        _previewMessage = '参数已重置为默认值，请重新生成预览。';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _workspaceMessage = '参数重置失败: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _actionInFlight = false;
        });
      }
    }
  }

  Future<void> _previewWorkspace() async {
    final currentDraft = _workspaceDraft;
    if (_generationActive ||
        _sourceImporting ||
        _targetImporting ||
        _previewInFlight ||
        currentDraft == null ||
        !currentDraft.canSubmit) {
      return;
    }
    setState(() {
      _previewInFlight = true;
      _previewMessage = '正在生成预览，请稍候。';
    });
    try {
      // 先呈现等待反馈，再开始请求和结果解码。
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final result = await _client.previewWorkspace({
        'source_paths': currentDraft.sourcePaths,
        'target_path': currentDraft.targetPath,
        'options': _workspaceOptionsState?.options ?? const <String, dynamic>{},
      });
      if (!mounted) {
        return;
      }
      if (result['ok'] == true) {
        final previewResult = _WorkspacePreviewResult.fromJson(result);
        if (previewResult.imageBytes.isEmpty) {
          setState(() {
            _workspacePreviewResult = null;
            _previewMessage = '预览生成失败：Bridge 返回了空的预览图片。';
          });
          return;
        }
        // 对照模式会同时显示原图和换脸图，全部准备好再移除粒子动画。
        Object? imageError;
        await Future.wait([
          for (final bytes in [
            previewResult.imageBytes,
            if (previewResult.canCompare) ...[
              previewResult.beforeImageBytes,
              previewResult.afterImageBytes,
            ],
          ])
            precacheImage(
              MemoryImage(bytes),
              context,
              onError: (error, _) => imageError ??= error,
            ),
        ]);
        if (!mounted) return;
        if (imageError != null) {
          throw StateError('预览图片无法解码');
        }
        setState(() {
          _workspacePreviewResult = previewResult;
          _lastVideoFrameTotal =
              previewResult.videoFrameTotal ?? _lastVideoFrameTotal;
          _previewMessage = '预览已更新，参数变更后可再次生成。';
        });
      } else {
        setState(() {
          _workspacePreviewResult = null;
          _previewMessage = '${result['message'] ?? '预览生成失败。'}';
        });
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _workspacePreviewResult = null;
        _previewMessage = '预览生成失败: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _previewInFlight = false;
        });
      }
    }
  }

  Future<void> _previewWorkspaceAtFrame(int frameNumber) async {
    await _updateWorkspaceOptions(<String, dynamic>{
      'preview_frame_number': frameNumber,
    }, clearPreview: false);
    if (!mounted) {
      return;
    }
    await _previewWorkspace();
  }

  Future<void> _loadWebUiIfNeeded({
    bool force = false,
    bool showError = false,
  }) async {
    if (!_controllerReady || !_isWebUiReady) {
      return;
    }
    if (!force && _lastLoadedUrl == _webuiUrl) {
      return;
    }

    try {
      await _controller!.loadRequest(Uri.parse(_webuiUrl));
      _lastLoadedUrl = _webuiUrl;
    } catch (error) {
      if (!showError || !mounted) {
        return;
      }
      setState(() {
        _workspaceMessage = '加载 WebUI 失败: $error';
      });
    }
  }

  Future<void> _openBrowser() async {
    try {
      final result = await _client.openBrowser();
      if (result['ok'] == false && mounted) {
        setState(() {
          _workspaceMessage = '${result['message'] ?? '打开浏览器失败。'}';
        });
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _workspaceMessage = '打开浏览器失败: $error';
      });
    }
  }

  Future<void> _openSourcePreview() async {
    final draft = _workspaceDraft;
    final path = draft?.primarySourcePath;
    final mediaType = draft?.primarySourceMediaType;
    if (!mounted || path == null || mediaType != 'image') {
      return;
    }
    final imagePaths = draft?.imageSourcePaths ?? const <String>[];
    if (imagePaths.length > 1) {
      final initialIndex = imagePaths.indexOf(path);
      await showStudioImageGalleryViewer(
        context,
        filePaths: imagePaths,
        initialIndex: initialIndex < 0 ? 0 : initialIndex,
        title: '人脸参考',
      );
      return;
    }
    await showStudioImageViewer(context, filePath: path, title: '人脸参考');
  }

  Future<void> _openTargetPreview() async {
    final path = _workspaceDraft?.targetPath;
    final mediaType = _workspaceDraft?.targetMediaType;
    if (!mounted || path == null || mediaType == null) {
      return;
    }
    if (mediaType == 'video') {
      await showStudioVideoViewer(context, filePath: path, title: '待换脸视频');
      return;
    }
    await showStudioImageViewer(context, filePath: path, title: '待换脸视频');
  }

  Future<void> _openPreviewResult() async {
    final previewResult = _workspacePreviewResult;
    if (!mounted || previewResult == null) {
      return;
    }
    if (previewResult.canCompare) {
      await showStudioImageComparisonViewer(
        context,
        beforeImageBytes: previewResult.beforeImageBytes,
        afterImageBytes: previewResult.afterImageBytes,
        singleImageBytes: previewResult.imageBytes,
        title: '原生预览',
      );
      return;
    }
    await showStudioImageViewer(
      context,
      imageBytes: previewResult.imageBytes,
      title: '原生预览',
    );
  }

  Future<void> _togglePinnedPreview() async {
    if (!_controllerReady || !_isWebUiReady) {
      return;
    }
    try {
      await _controller!.runJavaScript(
        "window.toggleStudioPinned && window.toggleStudioPinned();",
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _isPinned = !_isPinned;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _workspaceMessage = '切换固定预览失败: $error';
      });
    }
  }

  bool get _isWebUiReady => _serviceState == 'ready';

  void _applyImportedDraft(Map<String, dynamic> json, {required bool source}) {
    final incoming = _WorkspaceDraft.fromJson(json);
    final current = _workspaceDraft ?? const _WorkspaceDraft.empty();
    _workspaceDraft = _WorkspaceDraft.withMedia(
      source: source ? incoming : current,
      target: source ? current : incoming,
    );
    _workspaceDraftRevision++;
  }

  Future<void> _pickSourceFiles([List<XFile>? droppedFiles]) async {
    if (_generationActive ||
        _actionInFlight ||
        _previewInFlight ||
        _sourceImporting) {
      return;
    }
    // 先在文件窗口下方绘制等待态，窗口关闭后不必再等原生清理回调。
    setState(() {
      _sourceImporting = true;
      _sourceProcessed = _sourceRecognized = _sourceSkipped = _sourceTotal = 0;
    });
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final files =
          droppedFiles ??
          await pickStudioFiles(
            context,
            acceptedTypeGroups: const [
              XTypeGroup(
                label: '源媒体',
                extensions: [
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
                ],
              ),
            ],
          );
      if (!mounted || files.isEmpty || _actionInFlight || _generationActive) {
        return;
      }
      final requestId =
          '${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(1 << 32)}';
      final imageCount = files
          .where(
            (file) => RegExp(
              r'\.(jpg|jpeg|png|webp|bmp|tiff)$',
              caseSensitive: false,
            ).hasMatch(file.path),
          )
          .length;
      setState(() {
        _sourceImporting = true;
        _sourceRequestId = requestId;
        _sourceProcessed = _sourceRecognized = _sourceSkipped = 0;
        _sourceTotal = imageCount;
      });
      // 让带批次数量的首帧先显示，再提交识别请求。
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      var readingProgress = false;
      _sourceProgressTimer = Timer.periodic(const Duration(milliseconds: 500), (
        _,
      ) async {
        if (readingProgress) return;
        readingProgress = true;
        try {
          final progress = await _client.getSourceExtractionProgress(requestId);
          if (!mounted ||
              !_sourceImporting ||
              _sourceRequestId != requestId ||
              progress['request_id'] != requestId) {
            return;
          }
          setState(() {
            _sourceProcessed = math
                .max(
                  _sourceProcessed,
                  (progress['processed'] as num?)?.toInt() ?? 0,
                )
                .clamp(0, _sourceTotal);
            _sourceRecognized = (progress['recognized'] as num?)?.toInt() ?? 0;
            _sourceSkipped = (progress['skipped'] as num?)?.toInt() ?? 0;
          });
        } catch (_) {
          /* 短暂轮询失败不影响识别请求，最终请求负责展示错误。 */
        } finally {
          readingProgress = false;
        }
      });
      await _invokeWorkspaceAction(() async {
        _workspaceMessage = '正在自动提取源脸，请稍候。';
        final result = await _client.extractWorkspaceSourceFaces(
          files.map((file) => file.path).toList(),
          requestId: requestId,
          append: droppedFiles != null,
        );
        final workspace = result['workspace'] as Map<String, dynamic>?;
        if (result['ok'] == true && workspace != null) {
          _applyImportedDraft(workspace, source: true);
        }
        if (result['ok'] == true) {
          _sourceProcessed = _sourceTotal;
          _workspaceMessage =
              '${result['message'] ?? '已自动提取源脸。'} 当前共 ${_workspaceDraft?.sourcePaths.length ?? 0} 个源文件。';
        } else {
          _workspaceMessage = '${result['message'] ?? '源脸提取失败。'}';
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(_workspaceMessage)));
          }
          return;
        }
        _workspacePreviewResult = null;
        _lastVideoFrameTotal = null;
        _previewMessage = '源文件已更新，请重新生成预览。';
      }, independentImport: true);
    } finally {
      _sourceProgressTimer?.cancel();
      _sourceRequestId = null;
      if (mounted) setState(() => _sourceImporting = false);
    }
  }

  Future<void> _pickPersona() async {
    if (_generationActive) return;
    final persona = await showDialog<_PersonaChoice>(
      context: context,
      builder: (context) => _PersonaPickerDialog(client: _client),
    );
    if (!mounted || persona == null || _generationActive) {
      return;
    }
    await _invokeWorkspaceAction(() async {
      final result = await _client.usePersona(persona.id);
      final workspace = result['workspace'] as Map<String, dynamic>?;
      if (workspace != null) {
        _workspaceDraft = _WorkspaceDraft.fromJson(workspace);
      }
      _workspaceMessage =
          '${result['message'] ?? '已加载人物形象。'} 当前共 ${_workspaceDraft?.sourcePaths.length ?? 0} 个源文件。';
      _workspacePreviewResult = null;
      _lastVideoFrameTotal = null;
      _previewMessage = '人物形象已加载，请重新生成预览。';
    });
  }

  Future<void> _savePersona() async {
    if (_workspaceDraft?.sourcePaths.isEmpty ?? true) {
      setState(() {
        _workspaceMessage = '请先选择源图片并完成自动提取，再保存人物形象。';
      });
      return;
    }
    final name = await _showPersonaNameDialog(context);
    if (!mounted || name == null) {
      return;
    }
    await _invokeWorkspaceAction(() async {
      final result = await _client.savePersona(name);
      _workspaceMessage = '${result['message'] ?? '人物形象保存完成。'}';
    });
  }

  Future<void> _pickTargetFile([List<XFile>? droppedFiles]) async {
    if (_generationActive ||
        _actionInFlight ||
        _previewInFlight ||
        _targetImporting) {
      return;
    }
    setState(() => _targetImporting = true);
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final files =
          droppedFiles ??
          await pickStudioFiles(
            context,
            multiple: false,
            acceptedTypeGroups: const [
              XTypeGroup(
                label: '换脸视频',
                extensions: [
                  'mp4',
                  'mov',
                  'mkv',
                  'avi',
                  'webm',
                  'wmv',
                  'mpeg',
                  'm4v',
                ],
              ),
            ],
          );
      if (!mounted || files.isEmpty || _actionInFlight || _generationActive) {
        return;
      }
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      await _invokeWorkspaceAction(() async {
        final draft = await _client.setWorkspaceTargetPath(files.single.path);
        _applyImportedDraft(draft, source: false);
        _workspaceMessage = '已更新目标文件。';
        _workspacePreviewResult = null;
        _lastVideoFrameTotal = null;
        _previewMessage = '目标文件已更新，请重新生成预览。';
      }, independentImport: true);
    } finally {
      if (mounted) setState(() => _targetImporting = false);
    }
  }

  Future<void> _clearSourceFiles() async {
    if (_workspaceDraft?.sourcePaths.isEmpty ?? true) {
      return;
    }
    final confirmed = await _confirmWorkspaceAction(
      context,
      title: '清空源文件',
      message: '确定清空当前已选择的人脸参考吗？预览结果会一并清除。',
      confirmLabel: '清空',
      destructive: true,
    );
    if (!mounted || !confirmed) {
      return;
    }
    await _invokeWorkspaceAction(() async {
      final draft = await _client.clearWorkspaceSourcePaths();
      _workspaceDraft = _WorkspaceDraft.fromJson(draft);
      _workspaceMessage = '已清空源文件。';
      _workspacePreviewResult = null;
      _lastVideoFrameTotal = null;
      _previewMessage = '源文件已清空。';
    });
  }

  Future<void> _clearTargetFile() async {
    if (_workspaceDraft?.targetPath == null) {
      return;
    }
    final confirmed = await _confirmWorkspaceAction(
      context,
      title: '清空目标文件',
      message: '确定清空当前目标文件吗？预览结果会一并清除。',
      confirmLabel: '清空',
      destructive: true,
    );
    if (!mounted || !confirmed) {
      return;
    }
    await _invokeWorkspaceAction(() async {
      final draft = await _client.clearWorkspaceTargetPath();
      _workspaceDraft = _WorkspaceDraft.fromJson(draft);
      _workspaceMessage = '已清空目标文件。';
      _workspacePreviewResult = null;
      _lastVideoFrameTotal = null;
      _previewMessage = '目标文件已清空。';
    });
  }

  Future<void> _queueWorkspace() async {
    if (_generationActive || _sourceImporting || _targetImporting) return;
    await _invokeWorkspaceAction(() async {
      final result = await _client.queueWorkspace();
      if (result['ok'] == true) {
        _workspaceMessage = '已加入队列：${result['job_id']}';
      } else {
        _workspaceMessage = '${result['message'] ?? '加入队列失败。'}';
      }
      final workspace = result['workspace'] as Map<String, dynamic>?;
      if (workspace != null) {
        _workspaceDraft = _WorkspaceDraft.fromJson(workspace);
      }
    });
  }

  Future<void> _runWorkspace() async {
    if (_actionInFlight ||
        _previewInFlight ||
        _sourceImporting ||
        _targetImporting ||
        !widget.generation.begin()) {
      return;
    }
    await _invokeWorkspaceAction(() async {
      final result = await _client.runWorkspace();
      if (!mounted) return;
      final queue = result['queue'] as Map<String, dynamic>?;
      final runner = queue?['runner'] as Map<String, dynamic>?;
      widget.generation.finish(runner?['active'] == true);
      if (result['ok'] == true) {
        _workspaceMessage = '已在生成队列中开始当前任务：${result['job_id']}';
        if (mounted) DefaultTabController.of(context).animateTo(1);
      } else {
        _workspaceMessage = '${result['message'] ?? '提交生成失败。'}';
      }
      final workspace = result['workspace'] as Map<String, dynamic>?;
      if (workspace != null) {
        _workspaceDraft = _WorkspaceDraft.fromJson(workspace);
      }
    });
    if (mounted && widget.generation.submitting) widget.generation.finish(null);
  }

  Future<void> _invokeWorkspaceAction(
    Future<void> Function() action, {
    bool independentImport = false,
  }) async {
    if (!independentImport && _actionInFlight) {
      return;
    }
    if (!independentImport) {
      setState(() => _actionInFlight = true);
    }
    try {
      await action();
    } catch (error) {
      _workspaceMessage = '操作失败: $error';
      if (mounted && (_sourceImporting || _targetImporting)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_workspaceMessage)));
      }
    } finally {
      if (!independentImport) {
        await _refresh();
        if (mounted) setState(() => _actionInFlight = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compactHeader =
            constraints.maxWidth <= 1180 || constraints.maxHeight <= 640;

        if (_useNativeWorkbenchMode) {
          return _NativeWorkbenchPane(
            actionBusy:
                _generationActive || _actionInFlight || _previewInFlight,
            bridgeOnline: _bridgeOnline,
            webUiReady: _isWebUiReady,
            busy:
                _generationActive ||
                _actionInFlight ||
                _previewInFlight ||
                _sourceImporting ||
                _targetImporting,
            previewBusy: _previewInFlight,
            sourceImporting: _sourceImporting,
            targetImporting: _targetImporting,
            sourceProcessed: _sourceProcessed,
            sourceTotal: _sourceTotal,
            sourceRecognized: _sourceRecognized,
            sourceSkipped: _sourceSkipped,
            draft: _workspaceDraft,
            workspaceOptionsSchema: _workspaceOptionsSchema,
            workspaceOptionsState: _workspaceOptionsState,
            workspaceOptionsPanelWidth: _workspaceOptionsPanelWidth,
            previewResult: _workspacePreviewResult,
            lastVideoFrameTotal: _lastVideoFrameTotal,
            workspaceMessage: _workspaceMessage,
            previewMessage: _previewMessage,
            onPickSourceFiles: _pickSourceFiles,
            onDropSourceFiles: _pickSourceFiles,
            onPickPersona: _pickPersona,
            onSavePersona: _savePersona,
            onClearSourceFiles: _clearSourceFiles,
            onPickTargetFile: _pickTargetFile,
            onDropTargetFiles: _pickTargetFile,
            onClearTargetFile: _clearTargetFile,
            onUpdateOptions: _updateWorkspaceOptions,
            onResetOptions: _resetWorkspaceOptions,
            onWorkspaceOptionsPanelWidthChanged: _setWorkspacePanelWidth,
            onWorkspaceOptionsPanelWidthChangeEnd: _persistWorkspacePanelWidth,
            onPreviewWorkspace: _previewWorkspace,
            onPreviewFrameSelected: _previewWorkspaceAtFrame,
            onOpenSourcePreview: _openSourcePreview,
            onOpenTargetPreview: _openTargetPreview,
            onOpenPreviewResult: _openPreviewResult,
            onQueueWorkspace: _queueWorkspace,
            onRunWorkspace: _runWorkspace,
            onOpenBrowser: _openBrowser,
          );
        }

        return Card(
          elevation: 2,
          shadowColor: Colors.black.withValues(alpha: 0.12),
          child: Padding(
            padding: EdgeInsets.all(compactHeader ? 10 : 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!_useNativeWorkbenchMode)
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      onPressed: _isWebUiReady ? _togglePinnedPreview : null,
                      tooltip: _isPinned ? '取消顶部固定' : '固定人脸参考 / 待换脸视频 / 预览',
                      icon: Icon(
                        _isPinned
                            ? Icons.push_pin_rounded
                            : Icons.push_pin_outlined,
                      ),
                    ),
                  ),
                if (!_useNativeWorkbenchMode &&
                    _isWebUiReady &&
                    _pageProgress < 100)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: LinearProgressIndicator(value: _pageProgress / 100),
                  ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: theme.brightness == Brightness.dark
                              ? const [Color(0xFF171716), Color(0xFF20201E)]
                              : [
                                  theme.colorScheme.surface,
                                  theme.colorScheme.surfaceContainerLowest,
                                ],
                        ),
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.35,
                          ),
                        ),
                      ),
                      child:
                          _isWebUiReady &&
                              _controllerReady &&
                              _webViewWidget != null
                          ? _webViewWidget!
                          : Center(
                              child: Padding(
                                padding: const EdgeInsets.all(32),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.web_asset_rounded,
                                      size: 52,
                                      color: theme.colorScheme.primary,
                                    ),
                                    const SizedBox(height: 18),
                                    Text(
                                      _bridgeOnline
                                          ? 'FaceFusion 当前未就绪，启动后这里会自动嵌入原版 WebUI。'
                                          : 'Bridge 未连接，当前无法嵌入 FaceFusion WebUI。',
                                      textAlign: TextAlign.center,
                                      style: theme.textTheme.titleMedium,
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      _bridgeOnline
                                          ? '请先使用首页功能概览中的运行控制模块启动 FaceFusion。'
                                          : '建议通过启动器重新进入应用，确保 Bridge 与 Flutter 一起拉起。',
                                      textAlign: TextAlign.center,
                                      style: theme.textTheme.bodyMedium,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _NativeWorkbenchPane extends StatelessWidget {
  const _NativeWorkbenchPane({
    required this.bridgeOnline,
    required this.webUiReady,
    required this.busy,
    required this.actionBusy,
    required this.previewBusy,
    required this.sourceImporting,
    required this.targetImporting,
    required this.sourceProcessed,
    required this.sourceTotal,
    required this.sourceRecognized,
    required this.sourceSkipped,
    required this.draft,
    required this.workspaceOptionsSchema,
    required this.workspaceOptionsState,
    required this.workspaceOptionsPanelWidth,
    required this.previewResult,
    required this.lastVideoFrameTotal,
    required this.workspaceMessage,
    required this.previewMessage,
    required this.onPickSourceFiles,
    required this.onDropSourceFiles,
    required this.onPickPersona,
    required this.onSavePersona,
    required this.onClearSourceFiles,
    required this.onPickTargetFile,
    required this.onDropTargetFiles,
    required this.onClearTargetFile,
    required this.onUpdateOptions,
    required this.onResetOptions,
    required this.onWorkspaceOptionsPanelWidthChanged,
    required this.onWorkspaceOptionsPanelWidthChangeEnd,
    required this.onPreviewWorkspace,
    required this.onPreviewFrameSelected,
    required this.onOpenSourcePreview,
    required this.onOpenTargetPreview,
    required this.onOpenPreviewResult,
    required this.onQueueWorkspace,
    required this.onRunWorkspace,
    required this.onOpenBrowser,
  });

  final bool bridgeOnline;
  final bool webUiReady;
  final bool busy;
  final bool actionBusy;
  final bool previewBusy;
  final bool sourceImporting;
  final bool targetImporting;
  final int sourceProcessed;
  final int sourceTotal;
  final int sourceRecognized;
  final int sourceSkipped;
  final _WorkspaceDraft? draft;
  final WorkspaceOptionsSchema? workspaceOptionsSchema;
  final WorkspaceOptionsState? workspaceOptionsState;
  final double workspaceOptionsPanelWidth;
  final _WorkspacePreviewResult? previewResult;
  final int? lastVideoFrameTotal;
  final String workspaceMessage;
  final String previewMessage;
  final VoidCallback onPickSourceFiles;
  final Future<void> Function(List<XFile>) onDropSourceFiles;
  final VoidCallback onPickPersona;
  final VoidCallback onSavePersona;
  final VoidCallback onClearSourceFiles;
  final VoidCallback onPickTargetFile;
  final Future<void> Function(List<XFile>) onDropTargetFiles;
  final VoidCallback onClearTargetFile;
  final Future<void> Function(Map<String, dynamic> payload, {bool clearPreview})
  onUpdateOptions;
  final Future<void> Function() onResetOptions;
  final ValueChanged<double> onWorkspaceOptionsPanelWidthChanged;
  final Future<void> Function(double width)
  onWorkspaceOptionsPanelWidthChangeEnd;
  final Future<void> Function() onPreviewWorkspace;
  final Future<void> Function(int frameNumber) onPreviewFrameSelected;
  final Future<void> Function() onOpenSourcePreview;
  final Future<void> Function() onOpenTargetPreview;
  final Future<void> Function() onOpenPreviewResult;
  final VoidCallback onQueueWorkspace;
  final VoidCallback onRunWorkspace;
  final VoidCallback onOpenBrowser;

  @override
  Widget build(BuildContext context) {
    final currentDraft = draft ?? const _WorkspaceDraft.empty();

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxHeight <= 640 || constraints.maxWidth <= 1220;
        final useSingleColumn = constraints.maxWidth < 760;
        final outerPadding = compact ? 10.0 : 16.0;
        final cardGap = compact ? 10.0 : 16.0;
        final buttonGap = compact ? 10.0 : 12.0;
        final collapsedOptionsRailWidth = compact ? 40.0 : 44.0;
        final collapsedOptionsRailGap = 8.0;
        final panelMinWidth = compact
            ? (constraints.maxWidth - 64.0).clamp(220.0, 320.0).toDouble()
            : 320.0;
        final panelViewportLimit = compact
            ? constraints.maxWidth * 0.82
            : constraints.maxWidth * 0.56;
        final panelAvailableLimit =
            constraints.maxWidth - (compact ? 84.0 : 240.0);
        final panelMaxWidth = math.max(
          panelMinWidth,
          math.min(760.0, math.min(panelViewportLimit, panelAvailableLimit)),
        );
        final resolvedPanelWidth = workspaceOptionsPanelWidth
            .clamp(panelMinWidth, panelMaxWidth)
            .toDouble();
        final currentOptionsState =
            workspaceOptionsState ?? const WorkspaceOptionsState.empty();

        final sourceLoading = StudioMediaLoading(
          key: const ValueKey('source-import-loading'),
          kind: StudioMediaLoadingKind.face,
          processed: sourceProcessed,
          total: sourceTotal,
          recognized: sourceRecognized,
          skipped: sourceSkipped,
        );
        final sourceCard = _WorkspaceDraftCard(
          compact: compact,
          title: '人脸参考',
          onDropFiles: bridgeOnline && !actionBusy && !sourceImporting
              ? onDropSourceFiles
              : null,
          loading: sourceImporting ? sourceLoading : null,
          imageLoading: sourceLoading,
          subtitle: sourceImporting
              ? '正在为你准备人脸参考。'
              : currentDraft.sourcePaths.isEmpty
              ? '拖入多张人脸图片，或点击下方上传。'
              : '已添加 ${currentDraft.sourcePaths.length} 个文件，可继续拖入追加。',
          filePath: currentDraft.primarySourcePath,
          thumbnailPath: currentDraft.sourceThumbnail,
          mediaType: currentDraft.primarySourceMediaType,
          actionLabel: '上传人脸图片',
          visibleActionCount: 2,
          extraActions: [
            _WorkspaceDraftAction(
              label: '从形象库选择',
              icon: Icons.badge_outlined,
              onPressed: bridgeOnline && !busy ? onPickPersona : null,
            ),
            _WorkspaceDraftAction(
              label: '保存人物形象',
              icon: Icons.person_add_alt_1_outlined,
              onPressed:
                  bridgeOnline && !busy && currentDraft.sourcePaths.isNotEmpty
                  ? onSavePersona
                  : null,
            ),
          ],
          onOpenPreview:
              currentDraft.primarySourcePath != null &&
                  currentDraft.primarySourceMediaType == 'image'
              ? () => onOpenSourcePreview()
              : null,
          onPick: bridgeOnline && !actionBusy && !sourceImporting
              ? onPickSourceFiles
              : null,
          onClear: currentDraft.sourcePaths.isNotEmpty && !busy
              ? onClearSourceFiles
              : null,
        );

        const targetLoading = StudioMediaLoading(
          key: ValueKey('target-import-loading'),
          kind: StudioMediaLoadingKind.video,
        );
        final targetCard = _WorkspaceDraftCard(
          compact: compact,
          title: '待换脸视频',
          videoDrop: true,
          onDropFiles: bridgeOnline && !actionBusy && !targetImporting
              ? onDropTargetFiles
              : null,
          loading: targetImporting ? targetLoading : null,
          imageLoading: targetLoading,
          subtitle: targetImporting
              ? '正在读取素材信息。'
              : currentDraft.targetPath == null
              ? '拖入一个视频，或点击下方选择。'
              : '待换脸素材已就绪。',
          filePath: currentDraft.targetPath,
          thumbnailPath: currentDraft.targetThumbnail,
          mediaType: currentDraft.targetMediaType,
          actionLabel: currentDraft.targetPath == null ? '选择待换脸视频' : '更换视频',
          onOpenPreview:
              currentDraft.targetPath != null &&
                  currentDraft.targetMediaType != null
              ? () => onOpenTargetPreview()
              : null,
          onPick: bridgeOnline && !actionBusy && !targetImporting
              ? onPickTargetFile
              : null,
          onClear: currentDraft.targetPath != null && !busy
              ? onClearTargetFile
              : null,
        );

        final previewPanel = _WorkspacePreviewPanel(
          busy: busy,
          compact: compact,
          previewBusy: previewBusy,
          bridgeOnline: bridgeOnline,
          previewResult: previewResult,
          previewMessage: previewMessage,
          workspaceOptionsSchema: workspaceOptionsSchema,
          workspaceOptionsState: currentOptionsState,
          targetMediaType: currentDraft.targetMediaType,
          targetPath: currentDraft.targetPath,
          previewFrameNumber:
              (currentOptionsState.options['preview_frame_number'] as num?)
                  ?.toInt() ??
              0,
          targetVideoFrameTotal: currentDraft.targetVideoFrameTotal,
          lastVideoFrameTotal: lastVideoFrameTotal,
          onOpenPreviewResult: previewResult != null && !previewBusy
              ? () => onOpenPreviewResult()
              : null,
          onUpdateOptions: onUpdateOptions,
          onPreviewFrameSelected:
              bridgeOnline &&
                  currentDraft.canSubmit &&
                  !busy &&
                  !previewBusy &&
                  currentDraft.targetMediaType == 'video'
              ? onPreviewFrameSelected
              : null,
        );

        final optionsPanel = WorkspaceOptionsPanel(
          compact: compact,
          busy: busy,
          targetMediaType: currentDraft.targetMediaType,
          targetVideoFrameTotal: currentDraft.targetVideoFrameTotal,
          schema: workspaceOptionsSchema,
          state: currentOptionsState,
          onUpdateOptions: onUpdateOptions,
          onResetOptions: onResetOptions,
        );
        final submitPanel = _WorkspaceSubmitPanel(
          compact: compact,
          buttonGap: buttonGap,
          bridgeOnline: bridgeOnline,
          webUiReady: webUiReady,
          busy: busy,
          draft: currentDraft,
          previewBusy: previewBusy,
          hasPreview: previewResult != null,
          onPreviewWorkspace: onPreviewWorkspace,
          onQueueWorkspace: onQueueWorkspace,
          onRunWorkspace: onRunWorkspace,
          onOpenBrowser: onOpenBrowser,
        );

        // 三个预览共用视口的剩余空间，媒体内部按 contain 缩放。
        final workspaceSections = LayoutBuilder(
          builder: (context, viewport) {
            if (useSingleColumn && viewport.maxHeight >= 520) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: sourceCard),
                        SizedBox(width: cardGap),
                        Expanded(child: targetCard),
                      ],
                    ),
                  ),
                  SizedBox(height: cardGap),
                  Expanded(child: previewPanel),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: sourceCard),
                SizedBox(width: cardGap),
                Expanded(child: targetCard),
                SizedBox(width: cardGap),
                Expanded(flex: useSingleColumn ? 2 : 1, child: previewPanel),
              ],
            );
          },
        );

        final workspaceContent = Padding(
          padding: EdgeInsets.fromLTRB(
            outerPadding,
            outerPadding,
            outerPadding + collapsedOptionsRailWidth + collapsedOptionsRailGap,
            outerPadding,
          ),
          child: workspaceSections,
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                key: const ValueKey('workspace-media-panel'),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: StudioDepth.borderColor(context)),
                  boxShadow: StudioDepth.shadows(context),
                ),
                child: Stack(
                  children: [
                    Positioned.fill(child: workspaceContent),
                    WorkspaceFloatingOptionsOverlay(
                      compact: compact,
                      collapsedWidth: collapsedOptionsRailWidth,
                      panelWidth: resolvedPanelWidth,
                      minPanelWidth: panelMinWidth,
                      maxPanelWidth: panelMaxWidth,
                      onPanelWidthChanged: onWorkspaceOptionsPanelWidthChanged,
                      onPanelWidthChangeEnd:
                          onWorkspaceOptionsPanelWidthChangeEnd,
                      child: optionsPanel,
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: compact ? 8 : 10),
            submitPanel,
          ],
        );
      },
    );
  }
}

class _WorkspaceDraftCard extends StatelessWidget {
  const _WorkspaceDraftCard({
    this.compact = false,
    this.loading,
    this.imageLoading,
    this.videoDrop = false,
    this.onDropFiles,
    required this.title,
    required this.subtitle,
    required this.filePath,
    required this.thumbnailPath,
    required this.mediaType,
    required this.actionLabel,
    this.visibleActionCount = 1,
    this.extraActions = const <_WorkspaceDraftAction>[],
    required this.onOpenPreview,
    required this.onPick,
    required this.onClear,
  });

  final bool compact;
  final Widget? loading;
  final Widget? imageLoading;
  final bool videoDrop;
  final Future<void> Function(List<XFile>)? onDropFiles;
  final String title;
  final String subtitle;
  final String? filePath;
  final String? thumbnailPath;
  final String? mediaType;
  final String actionLabel;
  final int visibleActionCount;
  final List<_WorkspaceDraftAction> extraActions;
  final VoidCallback? onOpenPreview;
  final VoidCallback? onPick;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return StudioFileDropRegion(
      key: ValueKey(videoDrop ? 'target-file-drop' : 'source-file-drop'),
      video: videoDrop,
      extensions: videoDrop
          ? const {'mp4', 'mov', 'mkv', 'avi', 'webm', 'wmv', 'mpeg', 'm4v'}
          : const {
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
            },
      onFiles: onDropFiles,
      child: Container(
        padding: EdgeInsets.all(compact ? 10 : 14),
        decoration: BoxDecoration(
          color: theme.cardTheme.color,
          borderRadius: BorderRadius.circular(22),
          boxShadow: StudioDepth.shadows(context),
          border: Border.all(color: StudioDepth.borderColor(context)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style:
                  (compact
                          ? theme.textTheme.titleSmall
                          : theme.textTheme.titleMedium)
                      ?.copyWith(fontWeight: FontWeight.w800),
            ),
            SizedBox(height: compact ? 4 : 6),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: compact ? 1.22 : 1.35,
                fontSize: compact ? 11.5 : null,
              ),
            ),
            SizedBox(height: compact ? 10 : 14),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Material(
                  color: theme.brightness == Brightness.dark
                      ? const Color(0xFF20201E)
                      : theme.colorScheme.surfaceContainer,
                  child: InkWell(
                    onTap: loading != null || mediaType == 'video'
                        ? null
                        : onOpenPreview,
                    child: SizedBox(
                      width: double.infinity,
                      child:
                          loading ??
                          (mediaType == 'video' && filePath != null
                              ? StudioInlineVideoPlayer(
                                  filePath: filePath!,
                                  thumbnailPath: thumbnailPath,
                                  fit: BoxFit.contain,
                                  onOpenFullscreen: onOpenPreview,
                                )
                              : Stack(
                                  children: [
                                    Positioned.fill(
                                      child: thumbnailPath != null
                                          ? Padding(
                                              padding: EdgeInsets.all(
                                                compact ? 8 : 10,
                                              ),
                                              child: Image.file(
                                                File(thumbnailPath!),
                                                fit: BoxFit.contain,
                                                frameBuilder:
                                                    imageLoading == null
                                                    ? null
                                                    : (
                                                        _,
                                                        child,
                                                        frame,
                                                        synchronous,
                                                      ) =>
                                                          frame != null ||
                                                              synchronous
                                                          ? child
                                                          : imageLoading!,
                                                errorBuilder: (_, _, _) =>
                                                    _MediaPlaceholder(
                                                      compact: compact,
                                                      mediaType: mediaType,
                                                    ),
                                              ),
                                            )
                                          : _MediaPlaceholder(
                                              compact: compact,
                                              mediaType: mediaType,
                                            ),
                                    ),
                                    if (onOpenPreview != null)
                                      Positioned(
                                        right: compact ? 8 : 10,
                                        bottom: compact ? 8 : 10,
                                        child: _PreviewActionBadge(
                                          label: mediaType == 'video'
                                              ? '点击播放'
                                              : '点击查看',
                                        ),
                                      ),
                                  ],
                                )),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(height: compact ? 8 : 10),
            Text(
              loading != null
                  ? '正在处理新素材…'
                  : filePath == null
                  ? '未选择文件'
                  : filePath!.split(RegExp(r'[/\\]')).last,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: compact ? 13 : null,
                height: compact ? 1.2 : null,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            SizedBox(height: compact ? 10 : 14),
            _WorkspaceDraftActionsBar(
              compact: compact,
              visibleActionCount: visibleActionCount,
              actions: [
                _WorkspaceDraftAction(
                  label: actionLabel,
                  icon: Icons.folder_open_rounded,
                  onPressed: onPick,
                ),
                ...extraActions,
                _WorkspaceDraftAction(
                  label: '清空',
                  icon: Icons.clear_rounded,
                  onPressed: onClear,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceDraftAction {
  const _WorkspaceDraftAction({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
}

class _WorkspaceDraftActionsBar extends StatelessWidget {
  const _WorkspaceDraftActionsBar({
    required this.compact,
    required this.actions,
    required this.visibleActionCount,
  });

  final bool compact;
  final List<_WorkspaceDraftAction> actions;
  final int visibleActionCount;

  @override
  Widget build(BuildContext context) {
    final gap = compact ? 10.0 : 12.0;
    final minActionWidth = compact ? 132.0 : 150.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 520 || visibleActionCount > 1) {
          final visibleActions = actions.take(visibleActionCount).toList();
          final availableWidth = constraints.maxWidth - 48 - gap;
          final columns = visibleActions.length;
          final itemWidth = (availableWidth - gap * (columns - 1)) / columns;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Row(
                  children: [
                    for (
                      var index = 0;
                      index < visibleActions.length;
                      index++
                    ) ...[
                      if (index > 0) SizedBox(width: gap),
                      Expanded(
                        child: FilledButton.tonal(
                          onPressed: visibleActions[index].onPressed,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 36),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (itemWidth >= minActionWidth) ...[
                                  Icon(visibleActions[index].icon, size: 18),
                                  const SizedBox(width: 8),
                                ],
                                Text(visibleActions[index].label, maxLines: 1),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(width: gap),
              PopupMenuButton<_WorkspaceDraftAction>(
                tooltip: '更多素材操作',
                icon: const Icon(Icons.more_horiz_rounded),
                onSelected: (action) => action.onPressed?.call(),
                itemBuilder: (context) => [
                  for (final action in actions.skip(visibleActionCount))
                    PopupMenuItem(
                      value: action,
                      enabled: action.onPressed != null,
                      child: ListTile(
                        dense: true,
                        leading: Icon(action.icon, size: 18),
                        title: Text(action.label),
                      ),
                    ),
                ],
              ),
            ],
          );
        }
        final maxColumns = actions.length.clamp(1, 4).toInt();
        var columns = maxColumns;
        while (columns > 1 &&
            constraints.maxWidth <
                minActionWidth * columns + gap * (columns - 1)) {
          columns -= 1;
        }
        final itemWidth = columns <= 1
            ? constraints.maxWidth
            : (constraints.maxWidth - gap * (columns - 1)) / columns;

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final action in actions)
              SizedBox(
                width: itemWidth,
                child: FilledButton.tonalIcon(
                  onPressed: action.onPressed,
                  icon: Icon(action.icon, size: compact ? 18 : 20),
                  label: Text(action.label, overflow: TextOverflow.ellipsis),
                  style: FilledButton.styleFrom(
                    minimumSize: Size(0, compact ? 36 : 40),
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 10 : 12,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MediaPlaceholder extends StatelessWidget {
  const _MediaPlaceholder({this.compact = false, required this.mediaType});

  final bool compact;
  final String? mediaType;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = switch (mediaType) {
      'video' => Icons.movie_creation_outlined,
      'audio' => Icons.audio_file_outlined,
      _ => Icons.perm_media_outlined,
    };

    return Center(
      child: Icon(
        icon,
        size: compact ? 44 : 54,
        color: theme.colorScheme.primary,
      ),
    );
  }
}

class _PersonaPickerDialog extends StatefulWidget {
  const _PersonaPickerDialog({required this.client});

  final BridgeClient client;

  @override
  State<_PersonaPickerDialog> createState() => _PersonaPickerDialogState();
}

class _PersonaPickerDialogState extends State<_PersonaPickerDialog> {
  bool _loading = true;
  String _message = '正在加载人物形象库...';
  List<_PersonaChoice> _items = <_PersonaChoice>[];

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
            .map(_PersonaChoice.fromJson)
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
            tooltip: '刷新',
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
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
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
                      childAspectRatio: columns == 1 ? 1.8 : 0.82,
                    ),
                    itemCount: _items.length,
                    itemBuilder: (context, index) {
                      final item = _items[index];
                      return _PersonaChoiceCard(
                        item: item,
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

class _PersonaChoiceCard extends StatelessWidget {
  const _PersonaChoiceCard({required this.item, required this.onTap});

  final _PersonaChoice item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                color: theme.brightness == Brightness.dark
                    ? const Color(0xFF20201E)
                    : theme.colorScheme.surfaceContainer,
                child: item.previewPath == null
                    ? Icon(
                        Icons.face_retouching_natural_rounded,
                        size: 46,
                        color: theme.colorScheme.primary,
                      )
                    : Padding(
                        padding: const EdgeInsets.all(10),
                        child: Image.file(
                          File(item.previewPath!),
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => Icon(
                            Icons.broken_image_outlined,
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${item.faceCount} 张角度图',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
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

class _PersonaChoice {
  const _PersonaChoice({
    required this.id,
    required this.name,
    required this.previewPath,
    required this.faceCount,
  });

  factory _PersonaChoice.fromJson(Map<String, dynamic> json) {
    final facePaths =
        (json['face_paths'] as List<dynamic>? ?? const <dynamic>[])
            .map((item) => '$item')
            .where((item) => item.isNotEmpty && item != 'null')
            .toList();
    return _PersonaChoice(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? '未命名人物'}',
      previewPath: json['preview_path'] as String?,
      faceCount:
          (json['face_count'] as num?)?.toInt() ??
          (facePaths.isEmpty ? 0 : facePaths.length),
    );
  }

  final String id;
  final String name;
  final String? previewPath;
  final int faceCount;
}

class _WorkspaceDraft {
  const _WorkspaceDraft({
    required this.sourcePaths,
    required this.targetPath,
    required this.sourceThumbnail,
    required this.targetThumbnail,
    required this.targetMediaType,
    required this.targetVideoFrameTotal,
    required this.outputRoot,
    required this.outputDirectory,
    required this.canSubmit,
  });

  const _WorkspaceDraft.empty()
    : sourcePaths = const <String>[],
      targetPath = null,
      sourceThumbnail = null,
      targetThumbnail = null,
      targetMediaType = null,
      targetVideoFrameTotal = null,
      outputRoot = '',
      outputDirectory = null,
      canSubmit = false;

  factory _WorkspaceDraft.withMedia({
    required _WorkspaceDraft source,
    required _WorkspaceDraft target,
  }) => _WorkspaceDraft(
    sourcePaths: source.sourcePaths,
    sourceThumbnail: source.sourceThumbnail,
    targetPath: target.targetPath,
    targetThumbnail: target.targetThumbnail,
    targetMediaType: target.targetMediaType,
    targetVideoFrameTotal: target.targetVideoFrameTotal,
    outputRoot: target.outputRoot,
    outputDirectory: target.outputDirectory,
    canSubmit: source.sourcePaths.isNotEmpty && target.targetPath != null,
  );

  factory _WorkspaceDraft.fromJson(Map<String, dynamic> json) {
    return _WorkspaceDraft(
      sourcePaths: (json['source_paths'] as List<dynamic>? ?? const <dynamic>[])
          .map((item) => '$item')
          .toList(),
      targetPath: json['target_path'] as String?,
      sourceThumbnail: json['source_thumbnail'] as String?,
      targetThumbnail: json['target_thumbnail'] as String?,
      targetMediaType: json['target_media_type'] as String?,
      targetVideoFrameTotal: (json['target_video_frame_total'] as num?)
          ?.toInt(),
      outputRoot: '${json['output_root'] ?? ''}',
      outputDirectory: json['output_directory'] as String?,
      canSubmit: json['can_submit'] == true,
    );
  }

  final List<String> sourcePaths;
  final String? targetPath;
  final String? sourceThumbnail;
  final String? targetThumbnail;
  final String? targetMediaType;
  final int? targetVideoFrameTotal;
  final String outputRoot;
  final String? outputDirectory;
  final bool canSubmit;

  String? get primarySourcePath =>
      sourcePaths.isEmpty ? null : sourcePaths.first;

  List<String> get imageSourcePaths {
    return sourcePaths.where((path) {
      final lowerPath = path.toLowerCase();
      return lowerPath.endsWith('.jpg') ||
          lowerPath.endsWith('.jpeg') ||
          lowerPath.endsWith('.png') ||
          lowerPath.endsWith('.webp') ||
          lowerPath.endsWith('.bmp') ||
          lowerPath.endsWith('.tif') ||
          lowerPath.endsWith('.tiff');
    }).toList();
  }

  String? get primarySourceMediaType {
    final path = primarySourcePath;
    if (path == null) {
      return null;
    }
    final lowerPath = path.toLowerCase();
    if (lowerPath.endsWith('.mp3') ||
        lowerPath.endsWith('.wav') ||
        lowerPath.endsWith('.aac') ||
        lowerPath.endsWith('.flac') ||
        lowerPath.endsWith('.ogg') ||
        lowerPath.endsWith('.m4a') ||
        lowerPath.endsWith('.opus')) {
      return 'audio';
    }
    return 'image';
  }
}

class _WorkspacePreviewPanel extends StatefulWidget {
  const _WorkspacePreviewPanel({
    this.compact = false,
    required this.busy,
    required this.previewBusy,
    required this.bridgeOnline,
    required this.previewResult,
    required this.previewMessage,
    required this.workspaceOptionsSchema,
    required this.workspaceOptionsState,
    required this.targetMediaType,
    required this.targetPath,
    required this.previewFrameNumber,
    required this.targetVideoFrameTotal,
    required this.lastVideoFrameTotal,
    required this.onOpenPreviewResult,
    required this.onUpdateOptions,
    required this.onPreviewFrameSelected,
  });

  final bool compact;
  final bool busy;
  final bool previewBusy;
  final bool bridgeOnline;
  final _WorkspacePreviewResult? previewResult;
  final String previewMessage;
  final WorkspaceOptionsSchema? workspaceOptionsSchema;
  final WorkspaceOptionsState workspaceOptionsState;
  final String? targetMediaType;
  final String? targetPath;
  final int previewFrameNumber;
  final int? targetVideoFrameTotal;
  final int? lastVideoFrameTotal;
  final VoidCallback? onOpenPreviewResult;
  final Future<void> Function(Map<String, dynamic> payload, {bool clearPreview})
  onUpdateOptions;
  final Future<void> Function(int frameNumber)? onPreviewFrameSelected;

  @override
  State<_WorkspacePreviewPanel> createState() => _WorkspacePreviewPanelState();
}

class _WorkspacePreviewPanelState extends State<_WorkspacePreviewPanel> {
  final BridgeClient _thumbnailClient = BridgeClient();
  double? _sliderFrameValue;
  int? _inspectedFaceIndex;
  final Object _inspectionOwner = Object();
  ValueChanged<bool>? _pageFocus;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pageFocus = StudioHoverFocus.handlerOf(context, _inspectionOwner);
  }

  @override
  void dispose() {
    final focus = _pageFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) => focus?.call(false));
    super.dispose();
  }

  StudioComparisonMode _comparisonMode = StudioComparisonMode.wipe;
  bool _comparisonEnabled = true;
  double _comparisonDivider = 0.5;

  @override
  void didUpdateWidget(covariant _WorkspacePreviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.previewBusy || oldWidget.previewResult != widget.previewResult) {
      _inspectedFaceIndex = null;
      final focus = _pageFocus;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _inspectedFaceIndex == null) focus?.call(false);
      });
    }
    final displayedFrame = _displayedFrameNumber;
    if (_sliderFrameValue != null &&
        oldWidget.previewResult?.frameNumber !=
            widget.previewResult?.frameNumber &&
        displayedFrame.toDouble() != _sliderFrameValue) {
      _sliderFrameValue = null;
    }
  }

  int get _displayedFrameNumber {
    if (_sliderFrameValue != null) {
      return _sliderFrameValue!.round();
    }
    if (widget.previewResult?.targetMediaType == 'video') {
      return widget.previewResult!.frameNumber;
    }
    return widget.previewFrameNumber;
  }

  int? get _videoFrameTotal {
    return widget.previewResult?.videoFrameTotal ??
        widget.lastVideoFrameTotal ??
        widget.targetVideoFrameTotal;
  }

  bool get _showVideoSlider {
    final total = _videoFrameTotal;
    return widget.targetMediaType == 'video' && total != null && total > 1;
  }

  bool get _canScrubVideo => _showVideoSlider && !widget.previewBusy;

  String _frameSliderLabel(int currentFrame, int? videoFrameTotal) {
    if (widget.targetMediaType == 'video') {
      if (videoFrameTotal != null && videoFrameTotal > 1) {
        return '帧 $currentFrame / ${videoFrameTotal - 1}';
      }
      return '生成一次视频预览后可拖动选帧';
    }
    if (widget.targetMediaType == 'image') {
      return '图片目标无需选帧';
    }
    return '选择视频目标后可拖动选帧';
  }

  Widget _buildComparisonControls({required bool canCompare}) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.tonalIcon(
          onPressed: canCompare
              ? () {
                  setState(() {
                    _comparisonEnabled = !_comparisonEnabled;
                    if (_comparisonEnabled) {
                      _comparisonMode = StudioComparisonMode.wipe;
                    }
                  });
                }
              : null,
          icon: Icon(
            canCompare && _comparisonEnabled
                ? Icons.compare_arrows_rounded
                : Icons.visibility_off_rounded,
            size: 18,
          ),
          label: Text(
            canCompare ? (_comparisonEnabled ? '划像开' : '划像关') : '划像不可用',
          ),
          style: FilledButton.styleFrom(
            visualDensity: VisualDensity.compact,
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        if (canCompare && _comparisonEnabled)
          SegmentedButton<StudioComparisonMode>(
            segments: const [
              ButtonSegment<StudioComparisonMode>(
                value: StudioComparisonMode.wipe,
                icon: Icon(Icons.compare_arrows_rounded, size: 18),
                label: Text('划像'),
              ),
              ButtonSegment<StudioComparisonMode>(
                value: StudioComparisonMode.split,
                icon: Icon(Icons.splitscreen_rounded, size: 18),
                label: Text('双屏'),
              ),
            ],
            selected: {_comparisonMode},
            onSelectionChanged: (selection) {
              setState(() {
                _comparisonEnabled = true;
                _comparisonMode = selection.first;
              });
            },
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              padding: WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
      ],
    );
  }

  String get _faceSelectorMode {
    final rawValue = widget.workspaceOptionsState.options['face_selector_mode'];
    final value = rawValue == null ? 'many' : '$rawValue';
    return switch (value) {
      'many' || 'one' || 'reference' => value,
      _ => 'many',
    };
  }

  int get _referenceFacePosition {
    final rawValue =
        widget.workspaceOptionsState.options['reference_face_position'];
    if (rawValue is num) {
      return rawValue.toInt();
    }
    return int.tryParse('$rawValue') ?? 0;
  }

  Future<void> _selectReferenceFace(_PreviewFaceChoice face) async {
    await widget.onUpdateOptions(<String, dynamic>{
      'face_selector_mode': 'reference',
      'reference_face_position': face.index,
    }, clearPreview: false);
  }

  bool get _faceControlsEnabled => widget.bridgeOnline && !widget.busy;

  void _setFaceInspection(int index, bool visible) {
    if (!mounted) return;
    final next = visible
        ? index
        : (_inspectedFaceIndex == index ? null : _inspectedFaceIndex);
    if (next != _inspectedFaceIndex) {
      _inspectedFaceIndex = next;
      _pageFocus?.call(next != null);
    }
  }

  Widget _buildFaceModeShortcut(ThemeData theme) {
    final mode = _faceSelectorMode;
    return PopupMenuButton<String>(
      key: const ValueKey('workspace-face-mode'),
      tooltip: '换脸选择模式',
      enabled: _faceControlsEnabled,
      initialValue: mode,
      onSelected: (value) {
        if (value != mode) {
          widget.onUpdateOptions({
            'face_selector_mode': value,
          }, clearPreview: false);
        }
      },
      itemBuilder: (_) => [
        for (final entry in workspaceFaceSelectorLabels.entries)
          PopupMenuItem(
            value: entry.key,
            child: Row(
              children: [
                Icon(
                  mode == entry.key ? Icons.check_rounded : Icons.face_outlined,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Text(entry.value),
              ],
            ),
          ),
      ],
      child: Semantics(
        button: true,
        label: '换脸选择模式：${workspaceFaceSelectorLabels[mode]}',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: .3),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: .35),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                workspaceFaceSelectorLabels[mode]!,
                style: theme.textTheme.labelMedium,
              ),
              const SizedBox(width: 2),
              const Icon(Icons.expand_more_rounded, size: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFaceSelectorControls(ThemeData theme) {
    final selectedMode = _faceSelectorMode;
    final selectedPosition = _referenceFacePosition;
    final previewResult = widget.previewResult;
    final faceChoices =
        previewResult?.faceChoices ?? const <_PreviewFaceChoice>[];
    final emptyMessage = previewResult == null ? '生成预览后显示' : '当前帧未检测到人脸';
    return Container(
      key: const ValueKey('workspace-reference-faces'),
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: theme.brightness == Brightness.dark ? 0.22 : 0.46,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: StudioDepth.borderColor(context)),
      ),
      child: Row(
        children: [
          Tooltip(
            message: '参考脸缩略图：点击指定换脸对象，悬停放大查看；多张可横向浏览',
            child: Text(
              '参考脸',
              maxLines: 1,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: faceChoices.isEmpty
                ? Tooltip(
                    message: emptyMessage,
                    child: Text(
                      emptyMessage,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  )
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: faceChoices.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final face = faceChoices[index];
                      return _FaceChoiceTile(
                        key: ValueKey('reference-face-${face.index}'),
                        face: face,
                        selected:
                            selectedMode == 'reference' &&
                            face.index == selectedPosition,
                        enabled: _faceControlsEnabled,
                        onInspectChanged: (visible) =>
                            _setFaceInspection(face.index, visible),
                        onSelected: () => _selectReferenceFace(face),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final previewResult = widget.previewResult;
    final canCompare = previewResult?.canCompare == true;
    final currentFrame = _displayedFrameNumber;
    final videoFrameTotal = _videoFrameTotal;
    final sliderMaxFrame = _showVideoSlider ? videoFrameTotal! - 1 : 1;
    final sliderValue = currentFrame.clamp(0, sliderMaxFrame).toDouble();

    return LayoutBuilder(
      builder: (context, constraints) => Container(
        key: const ValueKey('workspace-preview-panel'),
        padding: EdgeInsets.all(widget.compact ? 10 : 14),
        decoration: BoxDecoration(
          color: theme.cardTheme.color,
          borderRadius: BorderRadius.circular(22),
          boxShadow: StudioDepth.shadows(context),
          border: Border.all(color: StudioDepth.borderColor(context)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: widget.compact ? 8 : 10,
              runSpacing: widget.compact ? 8 : 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _buildFaceModeShortcut(theme),
                Text(
                  '原生预览',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                _WorkspacePill(
                  compact: true,
                  active: previewResult != null,
                  label: previewResult == null ? '未生成' : '已生成',
                ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _AdaptivePreviewBody(
                media: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Material(
                    color: theme.brightness == Brightness.dark
                        ? const Color(0xFF20201E)
                        : theme.colorScheme.surfaceContainer,
                    child: InkWell(
                      onTap: widget.onOpenPreviewResult,
                      child: SizedBox(
                        width: double.infinity,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: widget.previewBusy
                                  ? const StudioMediaLoading(
                                      key: ValueKey(
                                        'workspace-preview-loading',
                                      ),
                                      kind: StudioMediaLoadingKind.face,
                                      message: '正在生成预览',
                                      detail: '正在融合人脸与生成画面，请稍候',
                                    )
                                  : previewResult != null
                                  ? StudioImageComparisonFrame(
                                      beforeImage: MemoryImage(
                                        previewResult.canCompare
                                            ? previewResult.beforeImageBytes
                                            : previewResult.imageBytes,
                                      ),
                                      afterImage: MemoryImage(
                                        previewResult.canCompare
                                            ? previewResult.afterImageBytes
                                            : previewResult.imageBytes,
                                      ),
                                      singleImage: MemoryImage(
                                        previewResult.imageBytes,
                                      ),
                                      mode:
                                          _comparisonEnabled &&
                                              previewResult.canCompare
                                          ? _comparisonMode
                                          : StudioComparisonMode.single,
                                      divider: _comparisonDivider,
                                      onDividerChanged: (value) {
                                        setState(() {
                                          _comparisonDivider = value;
                                        });
                                      },
                                      followPointer:
                                          _comparisonEnabled &&
                                          _comparisonMode ==
                                              StudioComparisonMode.wipe,
                                      beforeLabel:
                                          previewResult.targetMediaType ==
                                              'video'
                                          ? '原视频帧'
                                          : '原图',
                                      afterLabel: '换脸结果',
                                      onOpenFullscreen:
                                          widget.onOpenPreviewResult,
                                    )
                                  : _MediaPlaceholder(
                                      compact: widget.compact,
                                      mediaType: widget.targetMediaType,
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                controls: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (previewResult != null) ...[
                      _buildComparisonControls(canCompare: canCompare),
                      const SizedBox(height: 8),
                    ],
                    if (widget.targetMediaType == 'video') ...[
                      Row(
                        children: [
                          Text(
                            '预览帧',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            _frameSliderLabel(currentFrame, videoFrameTotal),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      StudioFrameScrubber(
                        videoKey: widget.targetPath,
                        loadFrame: widget.targetPath == null
                            ? null
                            : (frame) =>
                                  _thumbnailClient.getWorkspaceFrameThumbnail(
                                    widget.targetPath!,
                                    frame,
                                  ),
                        value: sliderValue,
                        max: sliderMaxFrame,
                        onChanged:
                            !_canScrubVideo ||
                                widget.onPreviewFrameSelected == null
                            ? null
                            : (nextValue) {
                                setState(() {
                                  _sliderFrameValue = nextValue;
                                });
                              },
                        onChangeEnd:
                            !_canScrubVideo ||
                                widget.onPreviewFrameSelected == null
                            ? null
                            : (nextValue) async {
                                final nextFrame = nextValue.round();
                                setState(() {
                                  _sliderFrameValue = nextFrame.toDouble();
                                });
                                await widget.onPreviewFrameSelected!(nextFrame);
                                if (!mounted) {
                                  return;
                                }
                                setState(() {
                                  _sliderFrameValue = null;
                                });
                              },
                      ),
                      SizedBox(height: widget.compact ? 10 : 12),
                    ],
                    _buildFaceSelectorControls(theme),
                    if (widget.previewMessage.isNotEmpty) ...[
                      SizedBox(height: widget.compact ? 10 : 12),
                      Text(
                        widget.previewMessage,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.35,
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
    );
  }
}

/// 控件按内容占用高度，画面使用剩余空间；矮窗口等比适配控件而不裁切。
class _AdaptivePreviewBody extends StatelessWidget {
  const _AdaptivePreviewBody({required this.media, required this.controls});

  final Widget media;
  final Widget controls;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 8.0;
        final minMediaHeight = (constraints.maxHeight * 0.18).clamp(40.0, 80.0);
        final maxControlsHeight = math.max(
          0.0,
          constraints.maxHeight - minMediaHeight - gap,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SizedBox(
                key: const ValueKey('workspace-preview-media'),
                child: media,
              ),
            ),
            const SizedBox(height: gap),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxControlsHeight),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.topCenter,
                child: SizedBox(
                  key: const ValueKey('workspace-preview-controls'),
                  width: constraints.maxWidth,
                  child: controls,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PreviewActionBadge extends StatelessWidget {
  const _PreviewActionBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(color: Colors.white),
        ),
      ),
    );
  }
}

/// Tooltip 的鼠标悬停不会触发 onTriggered，以浮层的真实生命周期同步背景。
class _FaceInspectionOverlay extends StatefulWidget {
  const _FaceInspectionOverlay({
    required this.onVisibilityChanged,
    required this.child,
  });

  final ValueChanged<bool> onVisibilityChanged;
  final Widget child;

  @override
  State<_FaceInspectionOverlay> createState() => _FaceInspectionOverlayState();
}

class _FaceInspectionOverlayState extends State<_FaceInspectionOverlay> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onVisibilityChanged(true);
    });
  }

  @override
  void dispose() {
    final notify = widget.onVisibilityChanged;
    WidgetsBinding.instance.addPostFrameCallback((_) => notify(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => widget.onVisibilityChanged(true),
    onExit: (_) => widget.onVisibilityChanged(false),
    child: widget.child,
  );
}

class _FaceChoiceTile extends StatelessWidget {
  const _FaceChoiceTile({
    super.key,
    required this.face,
    required this.selected,
    required this.enabled,
    required this.onSelected,
    required this.onInspectChanged,
  });

  final _PreviewFaceChoice face;
  final bool selected;
  final bool enabled;
  final VoidCallback onSelected;
  final ValueChanged<bool> onInspectChanged;

  Widget _image(double size, {Key? key}) => SizedBox.square(
    key: key,
    dimension: size,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: face.imageBytes.isEmpty
          ? const Icon(Icons.face_retouching_natural_rounded)
          : Image.memory(
              face.imageBytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.face_retouching_natural_rounded),
            ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MouseRegion(
      onExit: (_) => onInspectChanged(false),
      child: Tooltip(
        onTriggered: () => onInspectChanged(true),
        richMessage: TextSpan(
          children: [
            WidgetSpan(
              child: _FaceInspectionOverlay(
                onVisibilityChanged: onInspectChanged,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: .94, end: 1),
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 240),
                      curve: studioHoverFocusCurve,
                      child: _image(
                        72,
                        key: ValueKey('reference-face-hover-${face.index}'),
                      ),
                      builder: (_, scale, child) =>
                          Transform.scale(scale: scale, child: child),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '人脸 #${face.index}',
                      style: theme.textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        excludeFromSemantics: true,
        waitDuration: const Duration(milliseconds: 250),
        preferBelow: false,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: StudioDepth.borderColor(context)),
          boxShadow: StudioDepth.shadows(context, floating: true),
        ),
        child: Semantics(
          label: '人脸 #${face.index}',
          selected: selected,
          button: true,
          enabled: enabled,
          child: InkWell(
            onTap: enabled
                ? () {
                    onInspectChanged(false);
                    onSelected();
                  }
                : null,
            borderRadius: BorderRadius.circular(8),
            child: SizedBox.square(
              dimension: 36,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _image(
                    36,
                    key: ValueKey('reference-face-image-${face.index}'),
                  ),
                  if (selected)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: theme.colorScheme.primary,
                          width: 2,
                        ),
                      ),
                      child: Align(
                        alignment: Alignment.topRight,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.check_rounded,
                            size: 12,
                            color: theme.colorScheme.onPrimary,
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
    );
  }
}

class _WorkspaceSubmitPanel extends StatelessWidget {
  const _WorkspaceSubmitPanel({
    required this.compact,
    required this.buttonGap,
    required this.bridgeOnline,
    required this.webUiReady,
    required this.busy,
    required this.draft,
    required this.previewBusy,
    required this.hasPreview,
    required this.onPreviewWorkspace,
    required this.onQueueWorkspace,
    required this.onRunWorkspace,
    required this.onOpenBrowser,
  });

  final bool compact;
  final double buttonGap;
  final bool bridgeOnline;
  final bool webUiReady;
  final bool busy;
  final _WorkspaceDraft draft;
  final bool previewBusy;
  final bool hasPreview;
  final Future<void> Function() onPreviewWorkspace;
  final VoidCallback onQueueWorkspace;
  final VoidCallback onRunWorkspace;
  final VoidCallback onOpenBrowser;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final buttonHeight = compact ? 39.0 : 42.0;
    final gap = buttonGap * 0.75;
    final buttonStyle = FilledButton.styleFrom(
      minimumSize: Size(0, buttonHeight),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      visualDensity: VisualDensity.standard,
      textStyle: theme.textTheme.labelLarge?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w700,
      ),
    );

    return Container(
      key: const ValueKey('workspace-actions-panel'),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: theme.cardTheme.color ?? theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: StudioDepth.borderColor(context)),
        boxShadow: StudioDepth.shadows(context),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final minButtonWidth =
              160 * MediaQuery.textScalerOf(context).scale(15) / 15;
          final columns = constraints.maxWidth >= minButtonWidth * 4 + gap * 3
              ? 4
              : 2;
          final availableButtonWidth =
              (constraints.maxWidth - gap * (columns - 1)) / columns;
          final buttonWidth = math.min(
            availableButtonWidth,
            math.max(minButtonWidth, availableButtonWidth * 0.75),
          );
          return Wrap(
            alignment: WrapAlignment.center,
            spacing: gap,
            runSpacing: gap,
            children: [
              SizedBox(
                width: buttonWidth,
                child: FilledButton.icon(
                  onPressed: bridgeOnline && draft.canSubmit && !busy
                      ? onQueueWorkspace
                      : null,
                  icon: Icon(Icons.playlist_add_rounded, size: 20),
                  label: const Text('添加到队列'),
                  style: buttonStyle,
                ),
              ),
              SizedBox(
                width: buttonWidth,
                child: FilledButton.icon(
                  onPressed:
                      bridgeOnline && draft.canSubmit && !busy && !previewBusy
                      ? onPreviewWorkspace
                      : null,
                  icon: previewBusy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.preview_outlined, size: 20),
                  label: Text(
                    previewBusy
                        ? '正在预览'
                        : hasPreview
                        ? '重新生成预览'
                        : '生成预览',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: buttonStyle,
                ),
              ),
              SizedBox(
                width: buttonWidth,
                child: FilledButton.tonalIcon(
                  onPressed: bridgeOnline && webUiReady && !busy
                      ? onOpenBrowser
                      : null,
                  icon: Icon(Icons.open_in_browser_rounded, size: 20),
                  label: const Text('浏览器高级参数'),
                  style: buttonStyle,
                ),
              ),
              SizedBox(
                width: buttonWidth,
                child: FilledButton.tonalIcon(
                  onPressed: bridgeOnline && draft.canSubmit && !busy
                      ? onRunWorkspace
                      : null,
                  icon: Icon(Icons.rocket_launch_rounded, size: 20),
                  label: const Text('立即生成'),
                  style: buttonStyle,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _WorkspacePreviewResult {
  const _WorkspacePreviewResult({
    required this.imageBytes,
    required this.beforeImageBytes,
    required this.afterImageBytes,
    required this.mimeType,
    required this.width,
    required this.height,
    required this.orientation,
    required this.targetMediaType,
    required this.previewMode,
    required this.previewResolution,
    required this.frameNumber,
    required this.videoFrameTotal,
    required this.faceChoices,
  });

  factory _WorkspacePreviewResult.fromJson(Map<String, dynamic> json) {
    final rawFaceChoices =
        json['face_choices'] as List<dynamic>? ?? const <dynamic>[];
    return _WorkspacePreviewResult(
      imageBytes: _decodeImageBytes(json['image_base64']),
      beforeImageBytes: _decodeImageBytes(json['before_image_base64']),
      afterImageBytes: _decodeImageBytes(json['after_image_base64']),
      mimeType: '${json['mime_type'] ?? 'image/png'}',
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      orientation: '${json['orientation'] ?? 'landscape'}',
      targetMediaType: '${json['target_media_type'] ?? 'image'}',
      previewMode: '${json['preview_mode'] ?? 'default'}',
      previewResolution: '${json['preview_resolution'] ?? '1024x1024'}',
      frameNumber: (json['frame_number'] as num?)?.toInt() ?? 0,
      videoFrameTotal: (json['video_frame_total'] as num?)?.toInt(),
      faceChoices: [
        for (final item in rawFaceChoices)
          if (item is Map<String, dynamic>)
            _PreviewFaceChoice.fromJson(item)
          else if (item is Map)
            _PreviewFaceChoice.fromJson(item.cast<String, dynamic>()),
      ],
    );
  }

  static Uint8List _decodeImageBytes(dynamic value) {
    final rawValue = '$value';
    if (value == null || rawValue.isEmpty || rawValue == 'null') {
      return Uint8List(0);
    }
    return base64Decode(rawValue);
  }

  final Uint8List imageBytes;
  final Uint8List beforeImageBytes;
  final Uint8List afterImageBytes;
  final String mimeType;
  final int width;
  final int height;
  final String orientation;
  final String targetMediaType;
  final String previewMode;
  final String previewResolution;
  final int frameNumber;
  final int? videoFrameTotal;
  final List<_PreviewFaceChoice> faceChoices;

  bool get canCompare =>
      beforeImageBytes.isNotEmpty && afterImageBytes.isNotEmpty;

  String get previewModeLabel {
    return switch (previewMode) {
      'frame-by-frame' => '逐帧对照',
      'face-by-face' => '人脸对照',
      _ => '默认模式',
    };
  }

  String get orientationLabel {
    return switch (orientation) {
      'portrait' => '竖向',
      'square' => '方形',
      _ => '横向',
    };
  }
}

class _PreviewFaceChoice {
  const _PreviewFaceChoice({
    required this.index,
    required this.imageBytes,
    required this.boundingBox,
    required this.selected,
  });

  factory _PreviewFaceChoice.fromJson(Map<String, dynamic> json) {
    final rawBoundingBox =
        json['bounding_box'] as List<dynamic>? ?? const <dynamic>[];
    return _PreviewFaceChoice(
      index: (json['index'] as num?)?.toInt() ?? 0,
      imageBytes: _WorkspacePreviewResult._decodeImageBytes(
        json['image_base64'],
      ),
      boundingBox: [
        for (final item in rawBoundingBox)
          item is num ? item.toDouble() : double.tryParse('$item') ?? 0,
      ],
      selected: json['selected'] == true,
    );
  }

  final int index;
  final Uint8List imageBytes;
  final List<double> boundingBox;
  final bool selected;
}

class _QueueBoard extends StatefulWidget {
  const _QueueBoard({required this.generation});
  final _WorkspaceGenerationState generation;

  @override
  State<_QueueBoard> createState() => _QueueBoardState();
}

class _QueueBoardState extends State<_QueueBoard>
    with AutomaticKeepAliveClientMixin {
  final BridgeClient _client = BridgeClient();
  Timer? _pollTimer;

  bool _requestInFlight = false;
  bool _queueRunInFlight = false;
  bool _clearCompletedInFlight = false;
  bool _queueTaskActionInFlight = false;
  bool _bridgeOnline = false;
  List<_QueueTask> _queueTasks = <_QueueTask>[];
  _QueueRunnerState _queueRunnerState = const _QueueRunnerState();

  void _generationChanged() {
    if (mounted) setState(() {});
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    widget.generation.addListener(_generationChanged);
    _refresh();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    widget.generation.removeListener(_generationChanged);
    _pollTimer?.cancel();
    super.dispose();
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
    final generationRevision = widget.generation.revision;
    try {
      final status = await _client.getStatus();
      final queue = await _client.getQueueTasks();

      if (!mounted) {
        return;
      }

      widget.generation.apply(
        (queue['runner'] as Map<String, dynamic>?)?['active'] == true,
        generationRevision,
      );

      setState(() {
        _bridgeOnline = '${status['state'] ?? ''}' != 'bridge_offline';
        _queueTasks =
            (queue['tasks'] as List<dynamic>? ?? const <dynamic>[])
                .cast<Map<String, dynamic>>()
                .map(_QueueTask.fromJson)
                .toList()
              ..sort(_compareQueueTasksByNewest);
        _queueRunnerState = _QueueRunnerState.fromJson(
          (queue['runner'] as Map<String, dynamic>? ??
              const <String, dynamic>{}),
        );
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _bridgeOnline = false;
      });
    } finally {
      _requestInFlight = false;
    }
  }

  int _compareQueueTasksByNewest(_QueueTask a, _QueueTask b) {
    final timestampCompare = b.sortTimestamp.compareTo(a.sortTimestamp);
    if (timestampCompare != 0) {
      return timestampCompare;
    }
    return b.jobId.compareTo(a.jobId);
  }

  Future<void> _runQueue() async {
    if (_queueRunInFlight ||
        _queueRunnerState.active ||
        !widget.generation.begin()) {
      return;
    }
    setState(() {
      _queueRunInFlight = true;
    });
    try {
      final result = await _client.runQueue();
      if (!mounted) return;
      final runner = result['runner'] as Map<String, dynamic>?;
      widget.generation.finish(runner?['active'] == true);
      if (runner != null && runner['active'] == true) {
        _showMessage('队列已开始执行。');
      }
    } catch (error) {
      if (mounted && widget.generation.submitting) {
        widget.generation.finish(null);
      }
      _showMessage('执行队列失败：$error');
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await _refresh();
      if (mounted) {
        setState(() {
          _queueRunInFlight = false;
        });
      }
    }
  }

  Future<void> _clearCompletedQueueTasks() async {
    if (_clearCompletedInFlight) {
      return;
    }
    setState(() {
      _clearCompletedInFlight = true;
    });
    try {
      final result = await _client.clearCompletedQueueTasks();
      final removedCount = (result['removed_count'] as num?)?.toInt() ?? 0;
      _showMessage(
        removedCount == 0
            ? '没有需要清理的已完成任务。'
            : '已清理 $removedCount 个已完成任务记录，作品文件已保留。',
      );
    } catch (error) {
      _showMessage('清理已完成任务失败：$error');
    } finally {
      await _refresh();
      if (mounted) {
        setState(() {
          _clearCompletedInFlight = false;
        });
      }
    }
  }

  Future<void> _deleteQueueTask(String jobId) async {
    if (_queueTaskActionInFlight) {
      return;
    }
    final confirmed = await _confirmWorkspaceAction(
      context,
      title: '删除队列任务',
      message: '确定删除队列任务 $jobId 吗？此操作不会删除已经生成的作品文件。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!mounted || !confirmed) {
      return;
    }

    setState(() {
      _queueTaskActionInFlight = true;
    });
    try {
      final result = await _client.deleteQueueTask(jobId);
      if (result['ok'] == false) {
        _showMessage('${result['message'] ?? '删除任务失败。'}');
      } else {
        _showMessage('已删除任务：$jobId');
      }
    } catch (error) {
      _showMessage('删除任务失败：$error');
    } finally {
      await _refresh();
      if (mounted) {
        setState(() {
          _queueTaskActionInFlight = false;
        });
      }
    }
  }

  Future<void> _cancelQueueTask(_QueueTask task) async {
    if (_queueTaskActionInFlight || task.isCancelling) {
      return;
    }
    final confirmed = await _confirmWorkspaceAction(
      context,
      title: task.isActive ? '取消运行中任务' : '取消队列任务',
      message: task.isActive
          ? '确定取消正在生成的任务 ${task.jobId} 吗？已生成的作品文件会保留。'
          : '确定取消队列任务 ${task.jobId} 吗？此操作会将任务从生成队列移除。',
      confirmLabel: '取消任务',
      destructive: true,
    );
    if (!mounted || !confirmed) {
      return;
    }

    setState(() {
      _queueTaskActionInFlight = true;
    });
    try {
      final result = await _client.cancelQueueTask(task.jobId);
      if (result['ok'] == false) {
        _showMessage('${result['message'] ?? '取消任务失败。'}');
      } else {
        _showMessage('${result['message'] ?? '已取消任务：${task.jobId}'}');
      }
    } catch (error) {
      _showMessage('取消任务失败：$error');
    } finally {
      await _refresh();
      if (mounted) {
        setState(() {
          _queueTaskActionInFlight = false;
        });
      }
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

  Future<void> _openQueueTaskOutput(_QueueTask task) async {
    final outputPath = task.outputPath;
    if (!task.canOpenOutput || outputPath == null) {
      _showMessage('当前任务还没有可打开的生成作品。');
      return;
    }
    if (!await File(outputPath).exists()) {
      _showMessage('生成作品文件不存在：$outputPath');
      return;
    }

    final targetPath = task.targetPath;
    final canCompareWithTarget =
        targetPath != null &&
        task.targetMediaType == task.outputMediaType &&
        await File(targetPath).exists();

    if (!mounted) {
      return;
    }

    if (task.outputMediaType == 'video') {
      final playbackPath = await _prepareVideoPlaybackPath(outputPath);
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
          title: task.jobId,
        );
        return;
      }
      await showStudioVideoViewer(
        context,
        filePath: playbackPath,
        title: task.jobId,
      );
      return;
    }

    if (task.outputMediaType == 'image') {
      if (canCompareWithTarget) {
        await showStudioImageComparisonViewer(
          context,
          beforeFilePath: targetPath,
          afterFilePath: outputPath,
          title: task.jobId,
        );
        return;
      }
      await showStudioImageViewer(
        context,
        filePath: outputPath,
        title: task.jobId,
      );
      return;
    }

    _showMessage('当前输出类型暂不支持全屏预览。');
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final runner = _queueRunnerState;
    final hasCompletedTasks = _queueTasks.any(
      (task) => task.status == 'completed',
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '立即生成只执行当前任务；添加到队列后，点击“执行生成”才会批量执行待办。',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                OutlinedButton.icon(
                  onPressed:
                      _bridgeOnline &&
                          hasCompletedTasks &&
                          !_clearCompletedInFlight
                      ? _clearCompletedQueueTasks
                      : null,
                  icon: const Icon(Icons.cleaning_services_rounded),
                  label: const Text('清理已完成任务'),
                ),
                FilledButton.icon(
                  onPressed:
                      _bridgeOnline &&
                          _queueTasks.any((task) => task.status == 'queued') &&
                          !runner.active &&
                          !widget.generation.active &&
                          !_queueRunInFlight
                      ? _runQueue
                      : null,
                  icon: const Icon(Icons.rocket_launch_rounded),
                  label: const Text('执行生成'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _QueueSummary(
                      title: '执行器',
                      value: runner.active ? '运行中' : '待命',
                      detail: runner.currentJobId ?? '暂无运行中的任务',
                    ),
                    const SizedBox(width: 12),
                    _QueueSummary(
                      title: '完成进度',
                      value: '${runner.progressPercent.round()}%',
                      detail: runner.lastError ?? '执行生成时将逐条刷新状态',
                    ),
                    const SizedBox(width: 12),
                    _QueueSummary(
                      title: '任务总数',
                      value: '${_queueTasks.length}',
                      detail: '包含 queued / completed / failed',
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(
                    begin: 0,
                    end: (runner.progressPercent / 100).clamp(0.0, 1.0),
                  ),
                  duration: const Duration(milliseconds: 450),
                  curve: Curves.easeOutCubic,
                  builder: (context, value, _) {
                    return LinearProgressIndicator(value: value);
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  runner.totalJobs == 0
                      ? '队列待命'
                      : '已处理 ${runner.processedJobs}/${runner.totalJobs} · ${runner.progressPercent.toStringAsFixed(1)}%',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: _queueTasks.isEmpty
              ? Card(
                  child: Center(
                    child: Text(
                      '当前还没有队列任务。\n先在操作台里点击“添加到队列”。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: _queueTasks.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final task = _queueTasks[index];
                    return _QueueTaskCard(
                      task: task,
                      onOpen: task.canOpenOutput
                          ? () => _openQueueTaskOutput(task)
                          : null,
                      onAction: _queueTaskActionInFlight || task.isCancelling
                          ? null
                          : task.usesCancelAction
                          ? () => _cancelQueueTask(task)
                          : () => _deleteQueueTask(task.jobId),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _WorkspacePill extends StatelessWidget {
  const _WorkspacePill({
    this.compact = false,
    required this.active,
    required this.label,
  });

  final bool compact;
  final bool active;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 12,
        vertical: compact ? 6 : 8,
      ),
      decoration: BoxDecoration(
        color:
            (active
                    ? theme.colorScheme.primary
                    : theme.colorScheme.surfaceContainerHighest)
                .withValues(alpha: active ? 0.16 : 0.72),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: active
              ? theme.colorScheme.primary.withValues(alpha: 0.28)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Text(
        label,
        style:
            (compact ? theme.textTheme.labelMedium : theme.textTheme.labelLarge)
                ?.copyWith(
                  color: active
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
      ),
    );
  }
}

class _QueueSummary extends StatelessWidget {
  const _QueueSummary({
    required this.title,
    required this.value,
    required this.detail,
  });

  final String title;
  final String value;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.brightness == Brightness.dark
              ? const Color(0x24F6AA75)
              : theme.colorScheme.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title.toUpperCase(), style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Text(value, style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(detail, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _QueueTaskCard extends StatelessWidget {
  const _QueueTaskCard({
    required this.task,
    required this.onOpen,
    required this.onAction,
  });

  final _QueueTask task;
  final VoidCallback? onOpen;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final usesCancelAction = task.usesCancelAction;
    final actionColor = usesCancelAction
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _QueueMediaPreview(
                label: '人脸参考',
                filePath: task.primarySourcePath,
                mediaType: task.sourceMediaType,
                thumbnailPath: task.sourceThumbnail,
              ),
              const SizedBox(width: 12),
              _QueueMediaPreview(
                label: '待换脸视频',
                filePath: task.targetPath,
                mediaType: task.targetMediaType,
                thumbnailPath: task.targetThumbnail,
                showVideoOverlays: false,
              ),
              if (task.canOpenOutput) ...[
                const SizedBox(width: 12),
                _QueueMediaPreview(
                  label: 'OUTPUT',
                  filePath: task.outputPath,
                  mediaType: task.outputMediaType,
                  thumbnailPath: task.outputThumbnail,
                  showVideoOverlays: false,
                ),
              ],
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            task.jobId,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: _statusColor(
                              task.status,
                            ).withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(task.status.toUpperCase()),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '步骤 ${task.completedSteps}/${task.stepTotal} · 源 ${task.sourcePaths.length} 个文件 · ${task.progressPercent.toStringAsFixed(1)}%',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${task.progressPhaseLabel}：${task.progressDetail}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '目标：${task.targetPath ?? '未设置'}',
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '输出：${task.outputPath ?? '未设置'}',
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (task.isActive ||
                        task.status == 'completed' ||
                        task.status == 'failed') ...[
                      const SizedBox(height: 10),
                      TweenAnimationBuilder<double>(
                        tween: Tween<double>(
                          begin: 0,
                          end: (task.progressPercent / 100).clamp(0.0, 1.0),
                        ),
                        duration: const Duration(milliseconds: 450),
                        curve: Curves.easeOutCubic,
                        builder: (context, value, _) {
                          return LinearProgressIndicator(value: value);
                        },
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              TextButton.icon(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  foregroundColor: actionColor,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                ),
                icon: Icon(
                  usesCancelAction
                      ? Icons.cancel_outlined
                      : Icons.delete_outline_rounded,
                ),
                label: Text(task.actionLabel),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _statusColor(String status) {
    return switch (status) {
      'completed' => const Color(0xFF16A34A),
      'failed' => const Color(0xFFDC2626),
      'queued' => const Color(0xFF2563EB),
      'drafted' => const Color(0xFFF59E0B),
      _ => const Color(0xFF64748B),
    };
  }
}

class _QueueMediaPreview extends StatelessWidget {
  const _QueueMediaPreview({
    required this.label,
    required this.filePath,
    required this.mediaType,
    required this.thumbnailPath,
    this.showVideoOverlays = true,
  });

  final String label;
  final String? filePath;
  final String? mediaType;
  final String? thumbnailPath;
  final bool showVideoOverlays;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isVideo = mediaType == 'video' && filePath != null;

    return SizedBox(
      width: 120,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              height: 92,
              width: 120,
              color: theme.brightness == Brightness.dark
                  ? const Color(0xFF20201E)
                  : theme.colorScheme.surfaceContainer,
              child: isVideo
                  ? StudioInlineVideoPlayer(
                      filePath: filePath!,
                      thumbnailPath: thumbnailPath,
                      fit: BoxFit.cover,
                      showFullscreenButton: showVideoOverlays,
                    )
                  : thumbnailPath == null
                  ? Icon(
                      Icons.perm_media_outlined,
                      color: theme.colorScheme.primary,
                    )
                  : Padding(
                      padding: const EdgeInsets.all(8),
                      child: Image.file(
                        File(thumbnailPath!),
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => Icon(
                          Icons.broken_image_outlined,
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueTask {
  const _QueueTask({
    required this.jobId,
    required this.status,
    required this.sourcePaths,
    required this.sourceThumbnail,
    required this.sourceMediaType,
    required this.targetPath,
    required this.targetThumbnail,
    required this.targetMediaType,
    required this.outputPath,
    required this.outputThumbnail,
    required this.outputMediaType,
    required this.createdAt,
    required this.updatedAt,
    required this.canOpenOutput,
    required this.progressPercent,
    required this.progressPhase,
    required this.progressDetail,
    required this.stepTotal,
    required this.completedSteps,
    required this.isActive,
  });

  factory _QueueTask.fromJson(Map<String, dynamic> json) {
    final sourcePaths =
        (json['source_paths'] as List<dynamic>? ?? const <dynamic>[])
            .map((item) => '$item')
            .toList();
    final primarySourcePath = sourcePaths.isEmpty ? null : sourcePaths.first;

    return _QueueTask(
      jobId: '${json['job_id'] ?? ''}',
      status: '${json['status'] ?? 'queued'}',
      sourcePaths: sourcePaths,
      sourceThumbnail: json['source_thumbnail'] as String?,
      sourceMediaType:
          json['source_media_type'] as String? ??
          _mediaTypeFromPath(primarySourcePath),
      targetPath: json['target_path'] as String?,
      targetThumbnail: json['target_thumbnail'] as String?,
      targetMediaType:
          json['target_media_type'] as String? ??
          _mediaTypeFromPath(json['target_path'] as String?),
      outputPath: json['output_path'] as String?,
      outputThumbnail: json['output_thumbnail'] as String?,
      outputMediaType:
          json['output_media_type'] as String? ??
          _mediaTypeFromPath(json['output_path'] as String?),
      createdAt: json['created_at'] as String?,
      updatedAt: json['updated_at'] as String?,
      canOpenOutput: json['can_open_output'] == true,
      progressPercent: ((json['progress_percent'] as num?)?.toDouble() ?? 0)
          .clamp(0.0, 100.0)
          .toDouble(),
      progressPhase: '${json['progress_phase'] ?? 'queued'}',
      progressDetail: '${json['progress_detail'] ?? '等待执行。'}',
      stepTotal: (json['step_total'] as num?)?.toInt() ?? 0,
      completedSteps: (json['completed_steps'] as num?)?.toInt() ?? 0,
      isActive: json['is_active'] == true,
    );
  }

  final String jobId;
  final String status;
  final List<String> sourcePaths;
  final String? sourceThumbnail;
  final String? sourceMediaType;
  final String? targetPath;
  final String? targetThumbnail;
  final String? targetMediaType;
  final String? outputPath;
  final String? outputThumbnail;
  final String? outputMediaType;
  final String? createdAt;
  final String? updatedAt;
  final bool canOpenOutput;
  final double progressPercent;
  final String progressPhase;
  final String progressDetail;
  final int stepTotal;
  final int completedSteps;
  final bool isActive;

  String? get primarySourcePath =>
      sourcePaths.isEmpty ? null : sourcePaths.first;

  bool get usesCancelAction => status == 'drafted' || status == 'queued';

  bool get isCancelling => usesCancelAction && progressDetail.contains('取消');

  String get actionLabel {
    if (isCancelling) {
      return '取消中';
    }
    return usesCancelAction ? '取消任务' : '删除任务';
  }

  int get sortTimestamp =>
      (DateTime.tryParse(createdAt ?? '') ?? DateTime.tryParse(updatedAt ?? ''))
          ?.millisecondsSinceEpoch ??
      0;

  String get progressPhaseLabel {
    return switch (progressPhase) {
      'extracting' => '提取帧',
      'processing' => '处理帧',
      'merging' => '合成视频',
      'completed' => '已完成',
      'failed' => '失败',
      'running' => '生成中',
      _ => '等待中',
    };
  }

  static String? _mediaTypeFromPath(String? path) {
    if (path == null) {
      return null;
    }
    final lowerPath = path.toLowerCase();
    if (lowerPath.endsWith('.mp4') ||
        lowerPath.endsWith('.mov') ||
        lowerPath.endsWith('.mkv') ||
        lowerPath.endsWith('.avi') ||
        lowerPath.endsWith('.webm') ||
        lowerPath.endsWith('.wmv') ||
        lowerPath.endsWith('.mpeg') ||
        lowerPath.endsWith('.m4v')) {
      return 'video';
    }
    if (lowerPath.endsWith('.mp3') ||
        lowerPath.endsWith('.wav') ||
        lowerPath.endsWith('.aac') ||
        lowerPath.endsWith('.flac') ||
        lowerPath.endsWith('.ogg') ||
        lowerPath.endsWith('.m4a') ||
        lowerPath.endsWith('.opus')) {
      return 'audio';
    }
    if (lowerPath.endsWith('.jpg') ||
        lowerPath.endsWith('.jpeg') ||
        lowerPath.endsWith('.png') ||
        lowerPath.endsWith('.webp') ||
        lowerPath.endsWith('.bmp') ||
        lowerPath.endsWith('.tiff')) {
      return 'image';
    }
    return null;
  }
}

class _QueueRunnerState {
  const _QueueRunnerState({
    this.active = false,
    this.currentJobId,
    this.totalJobs = 0,
    this.completedJobs = 0,
    this.processedJobs = 0,
    this.progressPercent = 0,
    this.lastError,
  });

  factory _QueueRunnerState.fromJson(Map<String, dynamic> json) {
    return _QueueRunnerState(
      active: json['active'] == true,
      currentJobId: json['current_job_id'] as String?,
      totalJobs: (json['total_jobs'] as num?)?.toInt() ?? 0,
      completedJobs: (json['completed_jobs'] as num?)?.toInt() ?? 0,
      processedJobs:
          (json['processed_jobs'] as num?)?.toInt() ??
          (json['completed_jobs'] as num?)?.toInt() ??
          0,
      progressPercent: ((json['progress_percent'] as num?)?.toDouble() ?? 0)
          .clamp(0.0, 100.0)
          .toDouble(),
      lastError: json['last_error'] as String?,
    );
  }

  final bool active;
  final String? currentJobId;
  final int totalJobs;
  final int completedJobs;
  final int processedJobs;
  final double progressPercent;
  final String? lastError;
}

class TabControllerData {
  const TabControllerData({required this.length});

  final int length;
}
