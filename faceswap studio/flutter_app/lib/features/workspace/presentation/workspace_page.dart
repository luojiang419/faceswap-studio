import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:faceswap_studio/shared/services/bridge_client.dart';
import 'package:faceswap_studio/shared/widgets/studio_media_viewer.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:webview_all/webview_all.dart';

class WorkspacePage extends StatelessWidget {
  const WorkspacePage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('工作台', style: theme.textTheme.headlineMedium),
        const SizedBox(height: 14),
        const Expanded(
          child: DefaultTabController(
            length: 2,
            child: Column(
              children: [
                TabBar(
                  tabs: [
                    Tab(text: '操作台'),
                    Tab(text: '生成队列'),
                  ],
                ),
                SizedBox(height: 12),
                Expanded(
                  child: TabBarView(
                    children: [_OperationWorkbench(), _QueueBoard()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _OperationWorkbench extends StatefulWidget {
  const _OperationWorkbench();

  @override
  State<_OperationWorkbench> createState() => _OperationWorkbenchState();
}

class _OperationWorkbenchState extends State<_OperationWorkbench>
    with AutomaticKeepAliveClientMixin {
  final BridgeClient _client = BridgeClient();

  Timer? _pollTimer;
  WebViewController? _controller;
  Widget? _webViewWidget;

  bool _requestInFlight = false;
  bool _actionInFlight = false;
  bool _bridgeOnline = false;
  bool _controllerReady = false;
  bool _isPinned = true;
  bool _previewInFlight = false;
  String _serviceState = 'stopped';
  String _webuiUrl = 'http://127.0.0.1:7860';
  String _workspaceMessage = '选择源文件和目标文件后即可添加到队列或立即生成。';
  String _previewMessage = '选择源文件、目标文件并调整参数后，即可生成原生预览。';
  int _pageProgress = 0;
  String? _lastLoadedUrl;
  _WorkspaceDraft? _workspaceDraft;
  _WorkspaceOptionsSchema? _workspaceOptionsSchema;
  _WorkspaceOptionsState? _workspaceOptionsState;
  _WorkspacePreviewResult? _workspacePreviewResult;

  @override
  bool get wantKeepAlive => true;

  bool get _useNativeWorkbenchMode => Platform.isWindows;

  @override
  void initState() {
    super.initState();
    if (!_useNativeWorkbenchMode) {
      _initController();
    }
    _refresh();
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 1200),
      (_) => _refresh(),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
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
          ? _WorkspaceOptionsState.fromJson(results[2] as Map<String, dynamic>)
          : null;
      final workspaceOptionsSchema =
          _useNativeWorkbenchMode && results.length > 3
          ? _WorkspaceOptionsSchema.fromJson(results[3] as Map<String, dynamic>)
          : null;

      if (!mounted) {
        return;
      }

      final wasReady = _serviceState == 'ready';

      setState(() {
        _bridgeOnline = true;
        _serviceState = state;
        _webuiUrl = webuiUrl;
        _workspaceDraft = workspaceDraft ?? _workspaceDraft;
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

  Future<void> _updateWorkspaceOptions(Map<String, dynamic> payload) async {
    if (_actionInFlight) {
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
      final optionsState = _WorkspaceOptionsState.fromJson(
        results[0] as Map<String, dynamic>,
      );
      final optionsSchema = _WorkspaceOptionsSchema.fromJson(
        results[1] as Map<String, dynamic>,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _workspaceOptionsState = optionsState;
        _workspaceOptionsSchema = optionsSchema;
        _workspacePreviewResult = null;
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
    setState(() {
      _actionInFlight = true;
    });
    try {
      final results = await Future.wait<dynamic>([
        _client.resetWorkspaceOptions(),
        _client.getWorkspaceOptionsSchema(),
      ]);
      final optionsState = _WorkspaceOptionsState.fromJson(
        results[0] as Map<String, dynamic>,
      );
      final optionsSchema = _WorkspaceOptionsSchema.fromJson(
        results[1] as Map<String, dynamic>,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _workspaceOptionsState = optionsState;
        _workspaceOptionsSchema = optionsSchema;
        _workspacePreviewResult = null;
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
    if (_previewInFlight || currentDraft == null || !currentDraft.canSubmit) {
      return;
    }
    setState(() {
      _previewInFlight = true;
      _previewMessage = '正在生成预览，请稍候。';
    });
    try {
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
        setState(() {
          _workspacePreviewResult = previewResult;
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

  Future<void> _loadWebUiIfNeeded({bool force = false}) async {
    if (!_controllerReady || !_isWebUiReady) {
      return;
    }
    if (!force && _lastLoadedUrl == _webuiUrl) {
      return;
    }

    try {
      await _controller!.loadRequest(Uri.parse(_webuiUrl));
      _lastLoadedUrl = _webuiUrl;
    } catch (_) {}
  }

  Future<void> _reloadWebUi() async {
    if (_useNativeWorkbenchMode) {
      await _refresh();
      return;
    }
    if (!_bridgeOnline) {
      return;
    }
    setState(() {
      _lastLoadedUrl = null;
    });
    await _loadWebUiIfNeeded(force: true);
  }

  Future<void> _openBrowser() async {
    try {
      await _client.openBrowser();
    } catch (_) {}
  }

  Future<void> _openSourcePreview() async {
    final path = _workspaceDraft?.primarySourcePath;
    final mediaType = _workspaceDraft?.primarySourceMediaType;
    if (!mounted || path == null || mediaType != 'image') {
      return;
    }
    await showStudioImageViewer(context, filePath: path, title: 'SOURCE');
  }

  Future<void> _openTargetPreview() async {
    final path = _workspaceDraft?.targetPath;
    final mediaType = _workspaceDraft?.targetMediaType;
    if (!mounted || path == null || mediaType == null) {
      return;
    }
    if (mediaType == 'video') {
      await showStudioVideoViewer(context, filePath: path, title: 'TARGET');
      return;
    }
    await showStudioImageViewer(context, filePath: path, title: 'TARGET');
  }

  Future<void> _openPreviewResult() async {
    final previewResult = _workspacePreviewResult;
    if (!mounted || previewResult == null) {
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
    } catch (_) {}
  }

  bool get _isWebUiReady => _serviceState == 'ready';

  Future<void> _pickSourceFiles() async {
    final files = await openFiles(
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
    if (files.isEmpty) {
      return;
    }
    await _invokeWorkspaceAction(() async {
      final draft = await _client.setWorkspaceSourcePaths(
        files.map((file) => file.path).toList(),
      );
      _workspaceDraft = _WorkspaceDraft.fromJson(draft);
      _workspaceMessage = '已更新源文件，共 ${_workspaceDraft!.sourcePaths.length} 个。';
      _workspacePreviewResult = null;
      _previewMessage = '源文件已更新，请重新生成预览。';
    });
  }

  Future<void> _pickTargetFile() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: '目标媒体',
          extensions: [
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
          ],
        ),
      ],
    );
    if (file == null) {
      return;
    }
    await _invokeWorkspaceAction(() async {
      final draft = await _client.setWorkspaceTargetPath(file.path);
      _workspaceDraft = _WorkspaceDraft.fromJson(draft);
      _workspaceMessage = '已更新目标文件。';
      _workspacePreviewResult = null;
      _previewMessage = '目标文件已更新，请重新生成预览。';
    });
  }

  Future<void> _clearSourceFiles() async {
    await _invokeWorkspaceAction(() async {
      final draft = await _client.clearWorkspaceSourcePaths();
      _workspaceDraft = _WorkspaceDraft.fromJson(draft);
      _workspaceMessage = '已清空源文件。';
      _workspacePreviewResult = null;
      _previewMessage = '源文件已清空。';
    });
  }

  Future<void> _clearTargetFile() async {
    await _invokeWorkspaceAction(() async {
      final draft = await _client.clearWorkspaceTargetPath();
      _workspaceDraft = _WorkspaceDraft.fromJson(draft);
      _workspaceMessage = '已清空目标文件。';
      _workspacePreviewResult = null;
      _previewMessage = '目标文件已清空。';
    });
  }

  Future<void> _queueWorkspace() async {
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
    await _invokeWorkspaceAction(() async {
      final result = await _client.runWorkspace();
      if (result['ok'] == true) {
        _workspaceMessage = '已提交并开始生成：${result['job_id']}';
      } else {
        _workspaceMessage = '${result['message'] ?? '提交生成失败。'}';
      }
      final workspace = result['workspace'] as Map<String, dynamic>?;
      if (workspace != null) {
        _workspaceDraft = _WorkspaceDraft.fromJson(workspace);
      }
    });
  }

  Future<void> _invokeWorkspaceAction(Future<void> Function() action) async {
    if (_actionInFlight) {
      return;
    }
    setState(() {
      _actionInFlight = true;
    });
    try {
      await action();
    } catch (error) {
      _workspaceMessage = '操作失败: $error';
    } finally {
      await _refresh();
      if (mounted) {
        setState(() {
          _actionInFlight = false;
        });
      }
    }
  }

  String get _serviceLabel {
    return switch (_serviceState) {
      'ready' => '在线',
      'starting' => '启动中',
      'stopping' => '停止中',
      'stopped' => '离线',
      'bridge_offline' => 'Bridge 离线',
      _ => _serviceState,
    };
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compactHeader =
            constraints.maxWidth <= 1180 || constraints.maxHeight <= 640;

        return Card(
          child: Padding(
            padding: EdgeInsets.all(compactHeader ? 16 : 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: compactHeader ? 8 : 10,
                  runSpacing: compactHeader ? 8 : 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '操作台',
                          style: compactHeader
                              ? theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                )
                              : theme.textTheme.titleLarge,
                        ),
                        if (!_useNativeWorkbenchMode) ...[
                          const SizedBox(width: 8),
                          IconButton(
                            onPressed: _isWebUiReady
                                ? _togglePinnedPreview
                                : null,
                            tooltip: _isPinned
                                ? '取消顶部固定'
                                : '固定 SOURCE / TARGET / PREVIEW',
                            icon: Icon(
                              _isPinned
                                  ? Icons.push_pin_rounded
                                  : Icons.push_pin_outlined,
                            ),
                          ),
                        ],
                      ],
                    ),
                    _WorkspacePill(
                      compact: compactHeader,
                      active: _bridgeOnline,
                      label: _bridgeOnline ? 'Bridge 在线' : 'Bridge 离线',
                    ),
                    _WorkspacePill(
                      compact: compactHeader,
                      active: _isWebUiReady,
                      label: 'FaceFusion $_serviceLabel',
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _bridgeOnline ? _reloadWebUi : null,
                      icon: Icon(
                        Icons.refresh_rounded,
                        size: compactHeader ? 18 : 20,
                      ),
                      label: const Text('重新加载'),
                      style: FilledButton.styleFrom(
                        minimumSize: Size(0, compactHeader ? 36 : 40),
                        padding: EdgeInsets.symmetric(
                          horizontal: compactHeader ? 14 : 16,
                        ),
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _bridgeOnline ? _openBrowser : null,
                      icon: Icon(
                        Icons.open_in_browser_rounded,
                        size: compactHeader ? 18 : 20,
                      ),
                      label: const Text('浏览器打开'),
                      style: FilledButton.styleFrom(
                        minimumSize: Size(0, compactHeader ? 36 : 40),
                        padding: EdgeInsets.symmetric(
                          horizontal: compactHeader ? 14 : 16,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: compactHeader ? 12 : 14),
                if (_isWebUiReady && _pageProgress < 100)
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
                              ? const [Color(0xFF07111A), Color(0xFF0B1623)]
                              : const [Color(0xFFF7FBFD), Color(0xFFEAF3F8)],
                        ),
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.35,
                          ),
                        ),
                      ),
                      child: _useNativeWorkbenchMode
                          ? _NativeWorkbenchPane(
                              bridgeOnline: _bridgeOnline,
                              webUiReady: _isWebUiReady,
                              busy: _actionInFlight || _previewInFlight,
                              previewBusy: _previewInFlight,
                              draft: _workspaceDraft,
                              workspaceOptionsSchema: _workspaceOptionsSchema,
                              workspaceOptionsState: _workspaceOptionsState,
                              previewResult: _workspacePreviewResult,
                              workspaceMessage: _workspaceMessage,
                              previewMessage: _previewMessage,
                              onPickSourceFiles: _pickSourceFiles,
                              onClearSourceFiles: _clearSourceFiles,
                              onPickTargetFile: _pickTargetFile,
                              onClearTargetFile: _clearTargetFile,
                              onUpdateOptions: _updateWorkspaceOptions,
                              onResetOptions: _resetWorkspaceOptions,
                              onPreviewWorkspace: _previewWorkspace,
                              onOpenSourcePreview: _openSourcePreview,
                              onOpenTargetPreview: _openTargetPreview,
                              onOpenPreviewResult: _openPreviewResult,
                              onQueueWorkspace: _queueWorkspace,
                              onRunWorkspace: _runWorkspace,
                              onOpenBrowser: _openBrowser,
                            )
                          : _isWebUiReady &&
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
    required this.previewBusy,
    required this.draft,
    required this.workspaceOptionsSchema,
    required this.workspaceOptionsState,
    required this.previewResult,
    required this.workspaceMessage,
    required this.previewMessage,
    required this.onPickSourceFiles,
    required this.onClearSourceFiles,
    required this.onPickTargetFile,
    required this.onClearTargetFile,
    required this.onUpdateOptions,
    required this.onResetOptions,
    required this.onPreviewWorkspace,
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
  final bool previewBusy;
  final _WorkspaceDraft? draft;
  final _WorkspaceOptionsSchema? workspaceOptionsSchema;
  final _WorkspaceOptionsState? workspaceOptionsState;
  final _WorkspacePreviewResult? previewResult;
  final String workspaceMessage;
  final String previewMessage;
  final VoidCallback onPickSourceFiles;
  final VoidCallback onClearSourceFiles;
  final VoidCallback onPickTargetFile;
  final VoidCallback onClearTargetFile;
  final Future<void> Function(Map<String, dynamic> payload) onUpdateOptions;
  final Future<void> Function() onResetOptions;
  final Future<void> Function() onPreviewWorkspace;
  final Future<void> Function() onOpenSourcePreview;
  final Future<void> Function() onOpenTargetPreview;
  final Future<void> Function() onOpenPreviewResult;
  final VoidCallback onQueueWorkspace;
  final VoidCallback onRunWorkspace;
  final VoidCallback onOpenBrowser;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentDraft = draft ?? const _WorkspaceDraft.empty();

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxHeight <= 640 || constraints.maxWidth <= 1220;
        final useSingleColumn = constraints.maxWidth <= 1100;
        final useWideTopRow = constraints.maxWidth >= 1480;
        final outerPadding = compact ? 18.0 : 24.0;
        final sectionGap = compact ? 14.0 : 22.0;
        final cardGap = compact ? 12.0 : 18.0;
        final buttonGap = compact ? 10.0 : 12.0;
        final draftPreviewHeight = compact
            ? 148.0
            : useWideTopRow
            ? 212.0
            : 188.0;
        final nativePreviewHeight = compact
            ? 248.0
            : useWideTopRow
            ? 264.0
            : 300.0;
        final contentWidth = constraints.maxWidth > 1760
            ? 1760.0
            : constraints.maxWidth;
        final currentOptionsState =
            workspaceOptionsState ?? const _WorkspaceOptionsState.empty();

        final sourceCard = _WorkspaceDraftCard(
          compact: compact,
          previewHeight: draftPreviewHeight,
          title: 'SOURCE',
          subtitle: currentDraft.sourcePaths.isEmpty
              ? '支持图片和音频，可一次选择多个源文件。'
              : '已选择 ${currentDraft.sourcePaths.length} 个源文件。',
          filePath: currentDraft.primarySourcePath,
          thumbnailPath: currentDraft.sourceThumbnail,
          mediaType: currentDraft.primarySourceMediaType,
          actionLabel: '选择源文件',
          onOpenPreview:
              currentDraft.primarySourcePath != null &&
                  currentDraft.primarySourceMediaType == 'image'
              ? () => onOpenSourcePreview()
              : null,
          onPick: bridgeOnline && !busy ? onPickSourceFiles : null,
          onClear: currentDraft.sourcePaths.isNotEmpty && !busy
              ? onClearSourceFiles
              : null,
        );

        final targetCard = _WorkspaceDraftCard(
          compact: compact,
          previewHeight: draftPreviewHeight,
          title: 'TARGET',
          subtitle: currentDraft.targetPath == null
              ? '支持目标图片或目标视频。'
              : '当前目标已就绪。',
          filePath: currentDraft.targetPath,
          thumbnailPath: currentDraft.targetThumbnail,
          mediaType: currentDraft.targetMediaType,
          actionLabel: '选择目标文件',
          onOpenPreview:
              currentDraft.targetPath != null &&
                  currentDraft.targetMediaType != null
              ? () => onOpenTargetPreview()
              : null,
          onPick: bridgeOnline && !busy ? onPickTargetFile : null,
          onClear: currentDraft.targetPath != null && !busy
              ? onClearTargetFile
              : null,
        );

        final previewPanel = _WorkspacePreviewPanel(
          compact: compact,
          previewHeight: nativePreviewHeight,
          previewBusy: previewBusy,
          bridgeOnline: bridgeOnline,
          canPreview: currentDraft.canSubmit && !busy,
          previewResult: previewResult,
          previewMessage: previewMessage,
          targetMediaType: currentDraft.targetMediaType,
          onOpenPreviewResult: previewResult != null
              ? () => onOpenPreviewResult()
              : null,
          onPreview:
              bridgeOnline && currentDraft.canSubmit && !busy && !previewBusy
              ? onPreviewWorkspace
              : null,
        );

        final optionsPanel = _WorkspaceOptionsPanel(
          compact: compact,
          busy: busy,
          draft: currentDraft,
          schema: workspaceOptionsSchema,
          state: currentOptionsState,
          onUpdateOptions: onUpdateOptions,
          onResetOptions: onResetOptions,
        );
        final submitPanel = _WorkspaceSubmitPanel(
          compact: compact,
          useSingleColumn: useSingleColumn,
          buttonGap: buttonGap,
          bridgeOnline: bridgeOnline,
          webUiReady: webUiReady,
          busy: busy,
          draft: currentDraft,
          onQueueWorkspace: onQueueWorkspace,
          onRunWorkspace: onRunWorkspace,
          onOpenBrowser: onOpenBrowser,
        );

        late final Widget workspaceSections;
        if (useSingleColumn) {
          workspaceSections = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              sourceCard,
              SizedBox(height: cardGap),
              targetCard,
              SizedBox(height: cardGap),
              previewPanel,
              SizedBox(height: cardGap),
              optionsPanel,
            ],
          );
        } else if (useWideTopRow) {
          workspaceSections = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 5, child: sourceCard),
                  SizedBox(width: cardGap),
                  Expanded(flex: 5, child: targetCard),
                  SizedBox(width: cardGap),
                  Expanded(flex: 6, child: previewPanel),
                ],
              ),
              SizedBox(height: cardGap),
              optionsPanel,
            ],
          );
        } else {
          workspaceSections = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: sourceCard),
                  SizedBox(width: cardGap),
                  Expanded(child: targetCard),
                ],
              ),
              SizedBox(height: cardGap),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 5, child: previewPanel),
                  SizedBox(width: cardGap),
                  Expanded(flex: 7, child: optionsPanel),
                ],
              ),
            ],
          );
        }

        return Padding(
          padding: EdgeInsets.all(outerPadding),
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: contentWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.only(
                        right: compact ? 2 : 4,
                        bottom: compact ? 10 : 12,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Windows 原生工作台',
                            style:
                                (compact
                                        ? theme.textTheme.titleLarge
                                        : theme.textTheme.headlineSmall)
                                    ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          SizedBox(height: compact ? 8 : 10),
                          Text(
                            useWideTopRow
                                ? '宽屏下优先展示 SOURCE / TARGET / PREVIEW，参数区滚动显示，底部按钮固定。'
                                : '使用 Flutter 原生文件选择器准备 SOURCE / TARGET，调整参数、生成预览后提交本地队列。',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              height: compact ? 1.25 : 1.4,
                              fontSize: compact ? 13 : null,
                            ),
                          ),
                          SizedBox(height: sectionGap),
                          workspaceSections,
                        ],
                      ),
                    ),
                  ),
                  SizedBox(height: compact ? 12 : 16),
                  submitPanel,
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WorkspaceDraftCard extends StatelessWidget {
  const _WorkspaceDraftCard({
    this.compact = false,
    this.previewHeight = 180,
    required this.title,
    required this.subtitle,
    required this.filePath,
    required this.thumbnailPath,
    required this.mediaType,
    required this.actionLabel,
    required this.onOpenPreview,
    required this.onPick,
    required this.onClear,
  });

  final bool compact;
  final double previewHeight;
  final String title;
  final String subtitle;
  final String? filePath;
  final String? thumbnailPath;
  final String? mediaType;
  final String actionLabel;
  final VoidCallback? onOpenPreview;
  final VoidCallback? onPick;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: EdgeInsets.all(compact ? 14 : 18),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
        ),
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
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: compact ? 1.22 : 1.35,
              fontSize: compact ? 11.5 : null,
            ),
          ),
          SizedBox(height: compact ? 10 : 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Material(
              color: theme.brightness == Brightness.dark
                  ? const Color(0xFF0A1420)
                  : const Color(0xFFEAF2F8),
              child: InkWell(
                onTap: mediaType == 'video' ? null : onOpenPreview,
                child: SizedBox(
                  height: previewHeight,
                  width: double.infinity,
                  child: mediaType == 'video' && filePath != null
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
                                      padding: EdgeInsets.all(compact ? 8 : 10),
                                      child: Image.file(
                                        File(thumbnailPath!),
                                        fit: BoxFit.contain,
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
                                  label: mediaType == 'video' ? '点击播放' : '点击查看',
                                ),
                              ),
                          ],
                        ),
                ),
              ),
            ),
          ),
          SizedBox(height: compact ? 10 : 12),
          Text(
            filePath ?? '未选择文件',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontSize: compact ? 13 : null,
              height: compact ? 1.2 : null,
            ),
            maxLines: compact ? 1 : 2,
            overflow: TextOverflow.ellipsis,
          ),
          SizedBox(height: compact ? 10 : 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: onPick,
                  icon: Icon(
                    Icons.folder_open_rounded,
                    size: compact ? 18 : 20,
                  ),
                  label: Text(actionLabel),
                  style: FilledButton.styleFrom(
                    minimumSize: Size(0, compact ? 36 : 40),
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 12 : 16,
                    ),
                  ),
                ),
              ),
              SizedBox(width: compact ? 10 : 12),
              FilledButton.tonalIcon(
                onPressed: onClear,
                icon: Icon(Icons.clear_rounded, size: compact ? 18 : 20),
                label: const Text('清空'),
                style: FilledButton.styleFrom(
                  minimumSize: Size(0, compact ? 36 : 40),
                  padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 16),
                ),
              ),
            ],
          ),
        ],
      ),
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

class _WorkspaceDraft {
  const _WorkspaceDraft({
    required this.sourcePaths,
    required this.targetPath,
    required this.sourceThumbnail,
    required this.targetThumbnail,
    required this.targetMediaType,
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
      outputRoot = '',
      outputDirectory = null,
      canSubmit = false;

  factory _WorkspaceDraft.fromJson(Map<String, dynamic> json) {
    return _WorkspaceDraft(
      sourcePaths: (json['source_paths'] as List<dynamic>? ?? const <dynamic>[])
          .map((item) => '$item')
          .toList(),
      targetPath: json['target_path'] as String?,
      sourceThumbnail: json['source_thumbnail'] as String?,
      targetThumbnail: json['target_thumbnail'] as String?,
      targetMediaType: json['target_media_type'] as String?,
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
  final String outputRoot;
  final String? outputDirectory;
  final bool canSubmit;

  String? get primarySourcePath =>
      sourcePaths.isEmpty ? null : sourcePaths.first;

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

class _WorkspacePreviewPanel extends StatelessWidget {
  const _WorkspacePreviewPanel({
    this.compact = false,
    required this.previewHeight,
    required this.previewBusy,
    required this.bridgeOnline,
    required this.canPreview,
    required this.previewResult,
    required this.previewMessage,
    required this.targetMediaType,
    required this.onOpenPreviewResult,
    required this.onPreview,
  });

  final bool compact;
  final double previewHeight;
  final bool previewBusy;
  final bool bridgeOnline;
  final bool canPreview;
  final _WorkspacePreviewResult? previewResult;
  final String previewMessage;
  final String? targetMediaType;
  final VoidCallback? onOpenPreviewResult;
  final Future<void> Function()? onPreview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: EdgeInsets.all(compact ? 14 : 18),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: compact ? 8 : 10,
            runSpacing: compact ? 8 : 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '原生预览',
                style:
                    (compact
                            ? theme.textTheme.titleSmall
                            : theme.textTheme.titleMedium)
                        ?.copyWith(fontWeight: FontWeight.w800),
              ),
              _WorkspacePill(
                compact: compact,
                active: previewResult != null,
                label: previewResult == null ? '未生成' : '已生成',
              ),
              if (targetMediaType != null)
                _WorkspacePill(
                  compact: compact,
                  active: true,
                  label: targetMediaType == 'video' ? '视频目标' : '图片目标',
                ),
            ],
          ),
          SizedBox(height: compact ? 8 : 10),
          Text(
            '使用当前参数草稿生成单帧 PNG 预览，确认效果后再入队。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
          SizedBox(height: compact ? 12 : 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Material(
              color: theme.brightness == Brightness.dark
                  ? const Color(0xFF0A1420)
                  : const Color(0xFFEAF2F8),
              child: InkWell(
                onTap: onOpenPreviewResult,
                child: SizedBox(
                  height: previewHeight,
                  width: double.infinity,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: previewBusy
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const SizedBox(
                                      width: 28,
                                      height: 28,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.4,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      '正在生成预览',
                                      style: theme.textTheme.bodyMedium,
                                    ),
                                  ],
                                ),
                              )
                            : previewResult != null
                            ? Image.memory(
                                previewResult!.imageBytes,
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                                errorBuilder: (_, _, _) => _MediaPlaceholder(
                                  compact: compact,
                                  mediaType: targetMediaType,
                                ),
                              )
                            : _MediaPlaceholder(
                                compact: compact,
                                mediaType: targetMediaType,
                              ),
                      ),
                      if (onOpenPreviewResult != null)
                        Positioned(
                          right: compact ? 8 : 10,
                          bottom: compact ? 8 : 10,
                          child: const _PreviewActionBadge(label: '点击全屏查看'),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SizedBox(height: compact ? 10 : 12),
          Text(
            previewMessage,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
          if (previewResult != null) ...[
            SizedBox(height: compact ? 10 : 12),
            Wrap(
              spacing: compact ? 8 : 10,
              runSpacing: compact ? 8 : 10,
              children: [
                _PreviewMetaChip(
                  label: '${previewResult!.width}x${previewResult!.height}',
                ),
                _PreviewMetaChip(label: previewResult!.previewModeLabel),
                _PreviewMetaChip(label: previewResult!.previewResolution),
                if (previewResult!.targetMediaType == 'video')
                  _PreviewMetaChip(label: '帧 ${previewResult!.frameNumber}'),
                _PreviewMetaChip(label: previewResult!.orientationLabel),
              ],
            ),
          ],
          SizedBox(height: compact ? 12 : 14),
          FilledButton.icon(
            onPressed:
                bridgeOnline && canPreview && !previewBusy && onPreview != null
                ? () => onPreview!()
                : null,
            icon: Icon(Icons.preview_outlined, size: compact ? 18 : 20),
            label: Text(previewResult == null ? '生成预览' : '重新生成预览'),
            style: FilledButton.styleFrom(
              minimumSize: Size(0, compact ? 38 : 42),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewMetaChip extends StatelessWidget {
  const _PreviewMetaChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: theme.textTheme.bodySmall),
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

class _WorkspaceSubmitPanel extends StatelessWidget {
  const _WorkspaceSubmitPanel({
    required this.compact,
    required this.useSingleColumn,
    required this.buttonGap,
    required this.bridgeOnline,
    required this.webUiReady,
    required this.busy,
    required this.draft,
    required this.onQueueWorkspace,
    required this.onRunWorkspace,
    required this.onOpenBrowser,
  });

  final bool compact;
  final bool useSingleColumn;
  final double buttonGap;
  final bool bridgeOnline;
  final bool webUiReady;
  final bool busy;
  final _WorkspaceDraft draft;
  final VoidCallback onQueueWorkspace;
  final VoidCallback onRunWorkspace;
  final VoidCallback onOpenBrowser;

  @override
  Widget build(BuildContext context) {
    final buttonHeight = compact ? 36.0 : 40.0;
    final primaryWidth = useSingleColumn ? 148.0 : 168.0;
    final secondaryWidth = useSingleColumn ? 140.0 : 156.0;
    final browserWidth = useSingleColumn ? 176.0 : 196.0;

    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: buttonGap,
        runSpacing: compact ? 8 : buttonGap,
        children: [
          SizedBox(
            width: primaryWidth,
            child: FilledButton.icon(
              onPressed: bridgeOnline && draft.canSubmit && !busy
                  ? onQueueWorkspace
                  : null,
              icon: Icon(Icons.playlist_add_rounded, size: compact ? 18 : 20),
              label: const Text('添加到队列'),
              style: FilledButton.styleFrom(minimumSize: Size(0, buttonHeight)),
            ),
          ),
          SizedBox(
            width: secondaryWidth,
            child: FilledButton.tonalIcon(
              onPressed: bridgeOnline && draft.canSubmit && !busy
                  ? onRunWorkspace
                  : null,
              icon: Icon(Icons.rocket_launch_rounded, size: compact ? 18 : 20),
              label: const Text('立即生成'),
              style: FilledButton.styleFrom(minimumSize: Size(0, buttonHeight)),
            ),
          ),
          SizedBox(
            width: browserWidth,
            child: FilledButton.tonalIcon(
              onPressed: bridgeOnline && webUiReady && !busy
                  ? onOpenBrowser
                  : null,
              icon: Icon(
                Icons.open_in_browser_rounded,
                size: compact ? 18 : 20,
              ),
              label: const Text('浏览器高级参数'),
              style: FilledButton.styleFrom(minimumSize: Size(0, buttonHeight)),
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceOptionsPanel extends StatefulWidget {
  const _WorkspaceOptionsPanel({
    this.compact = false,
    required this.busy,
    required this.draft,
    required this.schema,
    required this.state,
    required this.onUpdateOptions,
    required this.onResetOptions,
  });

  final bool compact;
  final bool busy;
  final _WorkspaceDraft draft;
  final _WorkspaceOptionsSchema? schema;
  final _WorkspaceOptionsState state;
  final Future<void> Function(Map<String, dynamic> payload) onUpdateOptions;
  final Future<void> Function() onResetOptions;

  @override
  State<_WorkspaceOptionsPanel> createState() => _WorkspaceOptionsPanelState();
}

class _WorkspaceOptionsPanelState extends State<_WorkspaceOptionsPanel> {
  static const List<String> _orderedFieldKeys = <String>[
    'processors',
    'face_swapper_model',
    'face_swapper_pixel_boost',
    'face_swapper_weight',
    'face_enhancer_model',
    'face_enhancer_blend',
    'face_enhancer_weight',
    'frame_enhancer_model',
    'frame_enhancer_blend',
    'output_image_quality',
    'output_image_scale',
    'output_video_encoder',
    'output_video_preset',
    'output_video_quality',
    'output_video_scale',
    'output_video_fps',
    'preview_mode',
    'preview_resolution',
    'preview_frame_number',
  ];

  final Map<String, double> _numericDrafts = <String, double>{};
  late final Map<String, TextEditingController> _textControllers;

  @override
  void initState() {
    super.initState();
    _textControllers = <String, TextEditingController>{
      'output_video_fps': TextEditingController(),
      'preview_frame_number': TextEditingController(),
    };
    _syncWithState();
  }

  @override
  void didUpdateWidget(covariant _WorkspaceOptionsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncWithState();
  }

  @override
  void dispose() {
    for (final controller in _textControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _syncWithState() {
    final schema = widget.schema;
    if (schema == null) {
      return;
    }

    for (final field in schema.fields.values) {
      final value = widget.state.options[field.key];
      if (field.usesTextInput) {
        final controller = _textControllers[field.key];
        if (controller != null) {
          final nextText = field.formatEditableValue(value);
          if (controller.text != nextText) {
            controller.text = nextText;
          }
        }
        continue;
      }
      if (field.isNumeric) {
        _numericDrafts[field.key] = field.asDouble(value);
      }
    }
  }

  Future<void> _applyTextFieldValue(_WorkspaceOptionField field) async {
    final controller = _textControllers[field.key];
    if (controller == null) {
      return;
    }
    final parsedValue = field.parseEditableValue(controller.text);
    if (parsedValue == null) {
      _syncWithState();
      setState(() {});
      return;
    }
    await widget.onUpdateOptions(<String, dynamic>{field.key: parsedValue});
  }

  bool _isFieldVisible(_WorkspaceOptionField field) {
    final targetMediaType =
        widget.state.targetMediaType ?? widget.draft.targetMediaType;
    if (!field.supportsTargetMediaType(targetMediaType)) {
      return false;
    }

    final processors = widget.state.stringListValue('processors');
    if (field.key.startsWith('face_swapper_') &&
        !processors.contains('face_swapper')) {
      return false;
    }
    if (field.key.startsWith('face_enhancer_') &&
        !processors.contains('face_enhancer')) {
      return false;
    }
    if (field.key.startsWith('frame_enhancer_') &&
        !processors.contains('frame_enhancer')) {
      return false;
    }
    return true;
  }

  List<_WorkspaceOptionField> _visibleFields() {
    final schema = widget.schema;
    if (schema == null) {
      return const <_WorkspaceOptionField>[];
    }

    final ordered = <_WorkspaceOptionField>[];
    final usedKeys = <String>{};
    for (final key in _orderedFieldKeys) {
      final field = schema.fields[key];
      if (field != null && _isFieldVisible(field)) {
        ordered.add(field);
        usedKeys.add(key);
      }
    }
    for (final field in schema.fields.values) {
      if (!usedKeys.contains(field.key) && _isFieldVisible(field)) {
        ordered.add(field);
      }
    }
    return ordered;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = widget.compact;
    final sectionSpacing = compact ? 12.0 : 14.0;
    final fields = _visibleFields();

    return Container(
      padding: EdgeInsets.all(compact ? 14 : 18),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '常用参数',
                  style:
                      (compact
                              ? theme.textTheme.titleSmall
                              : theme.textTheme.titleMedium)
                          ?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: widget.busy ? null : () => widget.onResetOptions(),
                icon: Icon(Icons.restart_alt_rounded, size: compact ? 18 : 20),
                label: const Text('重置默认'),
                style: FilledButton.styleFrom(
                  minimumSize: Size(0, compact ? 36 : 40),
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 8 : 10),
          Text(
            '直接写入工作台参数草稿，后续预览与入队都会使用这里的当前值。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
          SizedBox(height: compact ? 12 : 14),
          if (widget.schema == null || widget.state.options.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                    const SizedBox(height: 12),
                    Text('正在加载参数面板', style: theme.textTheme.bodyMedium),
                  ],
                ),
              ),
            )
          else
            ..._buildSections(context, fields, sectionSpacing),
        ],
      ),
    );
  }

  List<Widget> _buildSections(
    BuildContext context,
    List<_WorkspaceOptionField> fields,
    double sectionSpacing,
  ) {
    final grouped = <String, List<_WorkspaceOptionField>>{};
    for (final field in fields) {
      grouped
          .putIfAbsent(field.section, () => <_WorkspaceOptionField>[])
          .add(field);
    }

    final widgets = <Widget>[];
    final orderedSections = <String>[
      'processors',
      'enhancers',
      'output',
      'preview',
    ];

    for (final section in orderedSections) {
      final sectionFields = grouped[section];
      if (sectionFields == null || sectionFields.isEmpty) {
        continue;
      }
      widgets.add(_WorkspaceSectionTitle(title: _sectionLabel(section)));
      widgets.add(SizedBox(height: widget.compact ? 8 : 10));
      widgets.addAll(
        sectionFields.map(
          (field) => Padding(
            padding: EdgeInsets.only(bottom: sectionSpacing),
            child: _buildField(context, field),
          ),
        ),
      );
    }
    return widgets;
  }

  String _sectionLabel(String section) {
    return switch (section) {
      'processors' => '处理器与模型',
      'enhancers' => '增强参数',
      'output' => '输出参数',
      'preview' => '预览参数',
      _ => section,
    };
  }

  Widget _buildField(BuildContext context, _WorkspaceOptionField field) {
    final theme = Theme.of(context);
    final value = widget.state.options[field.key];

    if (field.type == 'multi_select') {
      final selectedValues = widget.state.stringListValue(field.key);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            field.label,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: field.choices.map((choice) {
              final selected = selectedValues.contains(choice);
              return FilterChip(
                selected: selected,
                label: Text(choice),
                onSelected: widget.busy
                    ? null
                    : (nextSelected) {
                        final nextValues = List<String>.from(selectedValues);
                        if (nextSelected) {
                          if (!nextValues.contains(choice)) {
                            nextValues.add(choice);
                          }
                        } else {
                          nextValues.remove(choice);
                        }
                        widget.onUpdateOptions(<String, dynamic>{
                          field.key: nextValues,
                        });
                      },
              );
            }).toList(),
          ),
        ],
      );
    }

    if (field.type == 'select') {
      final currentValue = value == null ? null : '$value';
      return DropdownButtonFormField<String>(
        initialValue: field.choices.contains(currentValue)
            ? currentValue
            : null,
        items: field.choices
            .map(
              (choice) => DropdownMenuItem<String>(
                value: choice,
                child: Text(choice, overflow: TextOverflow.ellipsis),
              ),
            )
            .toList(),
        onChanged: widget.busy
            ? null
            : (nextValue) {
                if (nextValue == null) {
                  return;
                }
                widget.onUpdateOptions(<String, dynamic>{field.key: nextValue});
              },
        decoration: InputDecoration(
          labelText: field.label,
          helperText: field.dependsOn == null
              ? null
              : '受 ${field.dependsOn} 影响',
        ),
      );
    }

    if (field.usesTextInput) {
      final controller = _textControllers[field.key]!;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            field.label,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  enabled: !widget.busy,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    hintText: field.key == 'preview_frame_number'
                        ? '输入预览帧号'
                        : '输入输出 FPS',
                    helperText: field.minimum == null || field.maximum == null
                        ? null
                        : '范围 ${field.minimum} - ${field.maximum}',
                  ),
                  onSubmitted: (_) => _applyTextFieldValue(field),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.tonalIcon(
                onPressed: widget.busy
                    ? null
                    : () => _applyTextFieldValue(field),
                icon: const Icon(Icons.check_rounded),
                label: const Text('应用'),
                style: FilledButton.styleFrom(
                  minimumSize: Size(0, widget.compact ? 38 : 40),
                ),
              ),
            ],
          ),
        ],
      );
    }

    final currentValue = _numericDrafts[field.key] ?? field.asDouble(value);
    final divisions = field.divisions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                field.label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              field.formatValue(field.castSliderValue(currentValue)),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        Slider(
          value: currentValue.clamp(field.minimum ?? 0.0, field.maximum ?? 1.0),
          min: field.minimum ?? 0.0,
          max: field.maximum ?? 1.0,
          divisions: divisions,
          label: field.formatValue(field.castSliderValue(currentValue)),
          onChanged: widget.busy
              ? null
              : (nextValue) {
                  setState(() {
                    _numericDrafts[field.key] = nextValue;
                  });
                },
          onChangeEnd: widget.busy
              ? null
              : (nextValue) {
                  final normalizedValue = field.castSliderValue(nextValue);
                  widget.onUpdateOptions(<String, dynamic>{
                    field.key: normalizedValue,
                  });
                },
        ),
      ],
    );
  }
}

class _WorkspaceSectionTitle extends StatelessWidget {
  const _WorkspaceSectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      title,
      style: theme.textTheme.labelLarge?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        letterSpacing: 0.4,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _WorkspaceOptionsSchema {
  const _WorkspaceOptionsSchema({
    required this.version,
    required this.targetMediaType,
    required this.fields,
  });

  factory _WorkspaceOptionsSchema.fromJson(Map<String, dynamic> json) {
    final rawFields =
        (json['fields'] as Map<String, dynamic>? ?? const <String, dynamic>{})
            .cast<String, dynamic>();
    return _WorkspaceOptionsSchema(
      version: (json['version'] as num?)?.toInt() ?? 1,
      targetMediaType: json['target_media_type'] as String?,
      fields: rawFields.map(
        (key, value) => MapEntry(
          key,
          _WorkspaceOptionField.fromJson(key, value as Map<String, dynamic>),
        ),
      ),
    );
  }

  final int version;
  final String? targetMediaType;
  final Map<String, _WorkspaceOptionField> fields;
}

class _WorkspaceOptionsState {
  const _WorkspaceOptionsState({
    required this.version,
    required this.targetMediaType,
    required this.options,
  });

  const _WorkspaceOptionsState.empty()
    : version = 1,
      targetMediaType = null,
      options = const <String, dynamic>{};

  factory _WorkspaceOptionsState.fromJson(Map<String, dynamic> json) {
    final rawOptions =
        (json['options'] as Map<String, dynamic>? ?? const <String, dynamic>{})
            .cast<String, dynamic>();
    final normalizedOptions = <String, dynamic>{};
    for (final entry in rawOptions.entries) {
      if (entry.value is List<dynamic>) {
        normalizedOptions[entry.key] = (entry.value as List<dynamic>)
            .map((item) => '$item')
            .toList();
      } else {
        normalizedOptions[entry.key] = entry.value;
      }
    }
    return _WorkspaceOptionsState(
      version: (json['version'] as num?)?.toInt() ?? 1,
      targetMediaType: json['target_media_type'] as String?,
      options: normalizedOptions,
    );
  }

  final int version;
  final String? targetMediaType;
  final Map<String, dynamic> options;

  List<String> stringListValue(String key) {
    final rawValue = options[key];
    if (rawValue is List<String>) {
      return rawValue;
    }
    if (rawValue is List<dynamic>) {
      return rawValue.map((item) => '$item').toList();
    }
    return const <String>[];
  }
}

class _WorkspaceOptionField {
  const _WorkspaceOptionField({
    required this.key,
    required this.type,
    required this.section,
    required this.label,
    required this.choices,
    required this.visibleFor,
    this.dependsOn,
    this.minimum,
    this.maximum,
    this.step,
  });

  factory _WorkspaceOptionField.fromJson(
    String key,
    Map<String, dynamic> json,
  ) {
    return _WorkspaceOptionField(
      key: key,
      type: '${json['type'] ?? 'select'}',
      section: '${json['section'] ?? 'misc'}',
      label: '${json['label'] ?? key}',
      choices: (json['choices'] as List<dynamic>? ?? const <dynamic>[])
          .map((item) => '$item')
          .toList(),
      visibleFor:
          (json['visible_for'] as List<dynamic>? ?? const <dynamic>['all'])
              .map((item) => '$item')
              .toList(),
      dependsOn: json['depends_on'] as String?,
      minimum: (json['minimum'] as num?)?.toDouble(),
      maximum: (json['maximum'] as num?)?.toDouble(),
      step: (json['step'] as num?)?.toDouble(),
    );
  }

  final String key;
  final String type;
  final String section;
  final String label;
  final List<String> choices;
  final List<String> visibleFor;
  final String? dependsOn;
  final double? minimum;
  final double? maximum;
  final double? step;

  bool get isNumeric => type == 'int' || type == 'float';

  bool get usesTextInput =>
      key == 'output_video_fps' || key == 'preview_frame_number';

  bool supportsTargetMediaType(String? targetMediaType) {
    if (visibleFor.contains('all')) {
      return true;
    }
    if (targetMediaType == null) {
      return false;
    }
    return visibleFor.contains(targetMediaType);
  }

  double asDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    final parsed = double.tryParse('$value');
    return parsed ?? minimum ?? 0;
  }

  int? get divisions {
    if (minimum == null || maximum == null || step == null || step == 0) {
      return null;
    }
    final total = ((maximum! - minimum!) / step!).round();
    if (total <= 0 || total > 240) {
      return null;
    }
    return total;
  }

  dynamic castSliderValue(double value) {
    if (type == 'int') {
      return value.round();
    }
    final digits = step != null && step! < 1 ? 2 : 0;
    return double.parse(value.toStringAsFixed(digits));
  }

  String formatValue(dynamic value) {
    if (value == null) {
      return '--';
    }
    if (value is int) {
      return '$value';
    }
    if (value is double) {
      if ((value - value.round()).abs() < 0.0001) {
        return value.toStringAsFixed(0);
      }
      return value.toStringAsFixed(2);
    }
    return '$value';
  }

  String formatEditableValue(dynamic value) {
    if (value == null) {
      return '';
    }
    return '$value';
  }

  dynamic parseEditableValue(String rawValue) {
    final trimmed = rawValue.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    if (type == 'int') {
      final parsed = int.tryParse(trimmed);
      if (parsed == null) {
        return null;
      }
      if (minimum != null && parsed < minimum!) {
        return minimum!.round();
      }
      if (maximum != null && parsed > maximum!) {
        return maximum!.round();
      }
      return parsed;
    }

    final parsed = double.tryParse(trimmed);
    if (parsed == null) {
      return null;
    }
    var normalized = parsed;
    if (minimum != null && normalized < minimum!) {
      normalized = minimum!;
    }
    if (maximum != null && normalized > maximum!) {
      normalized = maximum!;
    }
    return double.parse(normalized.toStringAsFixed(2));
  }
}

class _WorkspacePreviewResult {
  const _WorkspacePreviewResult({
    required this.imageBytes,
    required this.mimeType,
    required this.width,
    required this.height,
    required this.orientation,
    required this.targetMediaType,
    required this.previewMode,
    required this.previewResolution,
    required this.frameNumber,
  });

  factory _WorkspacePreviewResult.fromJson(Map<String, dynamic> json) {
    return _WorkspacePreviewResult(
      imageBytes: base64Decode('${json['image_base64'] ?? ''}'),
      mimeType: '${json['mime_type'] ?? 'image/png'}',
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      orientation: '${json['orientation'] ?? 'landscape'}',
      targetMediaType: '${json['target_media_type'] ?? 'image'}',
      previewMode: '${json['preview_mode'] ?? 'default'}',
      previewResolution: '${json['preview_resolution'] ?? '1024x1024'}',
      frameNumber: (json['frame_number'] as num?)?.toInt() ?? 0,
    );
  }

  final Uint8List imageBytes;
  final String mimeType;
  final int width;
  final int height;
  final String orientation;
  final String targetMediaType;
  final String previewMode;
  final String previewResolution;
  final int frameNumber;

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

class _QueueBoard extends StatefulWidget {
  const _QueueBoard();

  @override
  State<_QueueBoard> createState() => _QueueBoardState();
}

class _QueueBoardState extends State<_QueueBoard>
    with AutomaticKeepAliveClientMixin {
  final BridgeClient _client = BridgeClient();
  Timer? _pollTimer;

  bool _requestInFlight = false;
  bool _bridgeOnline = false;
  List<_QueueTask> _queueTasks = <_QueueTask>[];
  _QueueRunnerState _queueRunnerState = const _QueueRunnerState();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _refresh();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_requestInFlight) {
      return;
    }
    _requestInFlight = true;
    try {
      final status = await _client.getStatus();
      final queue = await _client.getQueueTasks();

      if (!mounted) {
        return;
      }

      setState(() {
        _bridgeOnline = '${status['state'] ?? ''}' != 'bridge_offline';
        _queueTasks = (queue['tasks'] as List<dynamic>? ?? const <dynamic>[])
            .cast<Map<String, dynamic>>()
            .map(_QueueTask.fromJson)
            .toList();
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

  Future<void> _runQueue() async {
    try {
      await _client.runQueue();
    } catch (_) {
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await _refresh();
    }
  }

  Future<void> _deleteQueueTask(String jobId) async {
    try {
      await _client.deleteQueueTask(jobId);
    } catch (_) {
    } finally {
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final runner = _queueRunnerState;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '生成队列会接收操作台里“添加到队列”的任务，并按提交顺序逐条执行。',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            FilledButton.icon(
              onPressed:
                  _bridgeOnline &&
                      _queueTasks.any((task) => task.status == 'queued') &&
                      !runner.active
                  ? _runQueue
                  : null,
              icon: const Icon(Icons.rocket_launch_rounded),
              label: const Text('执行生成'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                _QueueSummary(
                  title: '执行器',
                  value: runner.active ? '运行中' : '待命',
                  detail: runner.currentJobId ?? '暂无运行中的任务',
                ),
                const SizedBox(width: 12),
                _QueueSummary(
                  title: '完成进度',
                  value: '${runner.completedJobs}/${runner.totalJobs}',
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
                      onDelete: task.isActive
                          ? null
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
              ? const Color(0x161AC6E4)
              : const Color(0x120F9FB8),
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
  const _QueueTaskCard({required this.task, required this.onDelete});

  final _QueueTask task;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            _QueueMediaPreview(
              label: 'SOURCE',
              filePath: task.primarySourcePath,
              mediaType: task.sourceMediaType,
              thumbnailPath: task.sourceThumbnail,
            ),
            const SizedBox(width: 12),
            _QueueMediaPreview(
              label: 'TARGET',
              filePath: task.targetPath,
              mediaType: task.targetMediaType,
              thumbnailPath: task.targetThumbnail,
              showVideoOverlays: false,
            ),
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
                    '步骤 ${task.completedSteps}/${task.stepTotal} · 源 ${task.sourcePaths.length} 个文件',
                    style: theme.textTheme.bodyMedium,
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
                  if (task.isActive) ...[
                    const SizedBox(height: 10),
                    LinearProgressIndicator(
                      value: task.stepTotal == 0
                          ? 0
                          : task.completedSteps / task.stepTotal,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            IconButton(
              onPressed: onDelete,
              tooltip: '删除任务',
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ],
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
                  ? const Color(0xFF0A1420)
                  : const Color(0xFFEAF2F8),
              child: isVideo
                  ? StudioInlineVideoPlayer(
                      filePath: filePath!,
                      thumbnailPath: thumbnailPath,
                      fit: BoxFit.cover,
                      showVideoBadge: showVideoOverlays,
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
  final int stepTotal;
  final int completedSteps;
  final bool isActive;

  String? get primarySourcePath =>
      sourcePaths.isEmpty ? null : sourcePaths.first;

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
    this.lastError,
  });

  factory _QueueRunnerState.fromJson(Map<String, dynamic> json) {
    return _QueueRunnerState(
      active: json['active'] == true,
      currentJobId: json['current_job_id'] as String?,
      totalJobs: (json['total_jobs'] as num?)?.toInt() ?? 0,
      completedJobs: (json['completed_jobs'] as num?)?.toInt() ?? 0,
      lastError: json['last_error'] as String?,
    );
  }

  final bool active;
  final String? currentJobId;
  final int totalJobs;
  final int completedJobs;
  final String? lastError;
}

class TabControllerData {
  const TabControllerData({required this.length});

  final int length;
}
