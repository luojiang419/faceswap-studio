import 'dart:async';
import 'dart:io';

import 'package:faceswap_studio/shared/services/bridge_client.dart';
import 'package:flutter/material.dart';
import 'package:webview_all/webview_all.dart';

class WorkspacePage extends StatefulWidget {
  const WorkspacePage({super.key});

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  final BridgeClient _client = BridgeClient();
  final TabControllerData _tabController = TabControllerData(length: 2);
  final List<String> _activity = <String>[
    '工作台兼容模式已启用，准备接入本地 FaceFusion WebUI。',
  ];

  Timer? _pollTimer;
  WebViewController? _controller;

  bool _requestInFlight = false;
  bool _bridgeOnline = false;
  bool _controllerReady = false;
  String _serviceState = 'stopped';
  String _serviceMessage = 'Bridge 未连接';
  String _webuiUrl = 'http://127.0.0.1:7860';
  int _pageProgress = 0;
  String? _lastLoadedUrl;
  List<_QueueTask> _queueTasks = <_QueueTask>[];
  _QueueRunnerState _queueRunnerState = const _QueueRunnerState();

  @override
  void initState() {
    super.initState();
    _initController();
    _refresh();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
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
            _pushActivity('开始加载 WebUI: $url');
            if (!mounted) {
              return;
            }
            setState(() {
              _pageProgress = 5;
            });
          },
          onPageFinished: (String url) {
            _pushActivity('WebUI 加载完成: $url');
            if (!mounted) {
              return;
            }
            setState(() {
              _pageProgress = 100;
            });
          },
          onWebResourceError: (WebResourceError error) {
            _pushActivity('WebUI 资源错误: ${error.description}');
          },
          onNavigationRequest: (NavigationRequest request) {
            _pushActivity('导航到: ${request.url}');
            return NavigationDecision.navigate;
          },
        ),
      );

    _controller = controller;
    _controllerReady = true;
  }

  Future<void> _refresh() async {
    if (_requestInFlight) {
      return;
    }
    _requestInFlight = true;
    try {
      final status = await _client.getStatus();
      final queue = await _client.getQueueTasks();
      final state = '${status['state'] ?? 'unknown'}';
      final message = '${status['status_message'] ?? 'Bridge 已连接'}';
      final webuiUrl = '${status['webui_url'] ?? _webuiUrl}';

      if (!mounted) {
        return;
      }

      setState(() {
        _bridgeOnline = true;
        _serviceState = state;
        _serviceMessage = message;
        _webuiUrl = webuiUrl;
        _queueTasks =
            (queue['tasks'] as List<dynamic>? ?? const <dynamic>[])
                .cast<Map<String, dynamic>>()
                .map(_QueueTask.fromJson)
                .toList();
        _queueRunnerState = _QueueRunnerState.fromJson(
          (queue['runner'] as Map<String, dynamic>? ?? const <String, dynamic>{}),
        );
      });

      if (_isWebUiReady) {
        await _loadWebUiIfNeeded();
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _bridgeOnline = false;
        _serviceState = 'bridge_offline';
        _serviceMessage = 'Bridge 不可用，请通过根目录启动脚本重新拉起应用。';
      });
    } finally {
      _requestInFlight = false;
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
    } catch (error) {
      _pushActivity('WebUI 载入失败: $error');
    }
  }

  Future<void> _startFaceFusion() async {
    await _invokeAction(_client.startFaceFusion);
  }

  Future<void> _stopFaceFusion() async {
    await _invokeAction(_client.stopFaceFusion);
  }

  Future<void> _openBrowser() async {
    await _invokeAction(_client.openBrowser);
  }

  Future<void> _reloadWebUi() async {
    await _loadWebUiIfNeeded(force: true);
  }

  Future<void> _runQueue() async {
    await _invokeAction(_client.runQueue);
  }

  Future<void> _deleteQueueTask(String jobId) async {
    try {
      await _client.deleteQueueTask(jobId);
    } catch (error) {
      _pushActivity('删除任务失败: $error');
    } finally {
      await _refresh();
    }
  }

  Future<void> _invokeAction(
    Future<Map<String, dynamic>> Function() action,
  ) async {
    try {
      await action();
    } catch (error) {
      _pushActivity('调用 Bridge 失败: $error');
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await _refresh();
    }
  }

  void _pushActivity(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _activity.add(message);
      if (_activity.length > 12) {
        _activity.removeRange(0, _activity.length - 12);
      }
    });
  }

  bool get _isWebUiReady => _serviceState == 'ready';
  bool get _isFaceFusionRunning =>
      _serviceState == 'starting' || _serviceState == 'ready' || _serviceState == 'stopping';

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
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('工作台', style: theme.textTheme.headlineMedium)),
            FilledButton.icon(
              onPressed: _bridgeOnline && !_isFaceFusionRunning ? _startFaceFusion : null,
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('启动 FaceFusion'),
            ),
            const SizedBox(width: 10),
            FilledButton.tonalIcon(
              onPressed: _bridgeOnline && _isFaceFusionRunning ? _stopFaceFusion : null,
              icon: const Icon(Icons.stop_rounded),
              label: const Text('停止'),
            ),
            const SizedBox(width: 10),
            FilledButton.tonalIcon(
              onPressed: _bridgeOnline ? _reloadWebUi : null,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新加载'),
            ),
            const SizedBox(width: 10),
            FilledButton.tonalIcon(
              onPressed: _bridgeOnline ? _openBrowser : null,
              icon: const Icon(Icons.open_in_browser_rounded),
              label: const Text('浏览器打开'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '当前使用兼容模式接入原版 FaceFusion WebUI。Windows 端直接嵌入本地页面，后续再逐步把 SOURCE / TARGET / PREVIEW 原生化。',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 18),
        Expanded(
          child: DefaultTabController(
            length: _tabController.length,
            child: Column(
              children: [
                TabBar(
                  tabs: const [
                    Tab(text: '操作台'),
                    Tab(text: '生成队列'),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: TabBarView(
                    children: [
                      _buildOperationTab(theme),
                      _buildQueueTab(theme),
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

  Widget _buildOperationTab(ThemeData theme) {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('兼容模式状态', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 16),
                  _InfoTile(
                    title: 'Bridge',
                    value: _bridgeOnline ? '在线' : '离线',
                    detail: _serviceMessage,
                  ),
                  const SizedBox(height: 12),
                  _InfoTile(
                    title: 'FaceFusion',
                    value: _serviceLabel,
                    detail: 'WebUI 地址：$_webuiUrl',
                  ),
                  const SizedBox(height: 12),
                  _InfoTile(
                    title: '接入策略',
                    value: 'Windows WebView',
                    detail: '当前通过本地 WebView2 承载原版 FaceFusion 页面，保留浏览器回退入口。',
                  ),
                  const SizedBox(height: 18),
                  Text('活动记录', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 10),
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: theme.brightness == Brightness.dark
                            ? const Color(0xFF0A1420)
                            : const Color(0xFFF8FBFF),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: ListView.separated(
                        itemCount: _activity.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          return Text(
                            _activity[index],
                            style: theme.textTheme.bodyMedium,
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          flex: 5,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('原版 WebUI', style: theme.textTheme.titleLarge),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: _isWebUiReady
                              ? theme.colorScheme.primary.withValues(alpha: 0.14)
                              : theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(_serviceLabel),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_isWebUiReady && _pageProgress < 100)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: LinearProgressIndicator(value: _pageProgress / 100),
                    ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: theme.brightness == Brightness.dark
                              ? const Color(0xFF060D14)
                              : const Color(0xFFF2F7FB),
                        ),
                        child: _isWebUiReady && _controllerReady
                            ? WebViewWidget(controller: _controller!)
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
                                            ? '你可以先在首页或此页点击“启动 FaceFusion”。'
                                            : '建议通过根目录启动脚本重新进入应用，确保 Bridge 与 Flutter 一起拉起。',
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
          ),
        ),
      ],
    );
  }

  Widget _buildQueueTab(ThemeData theme) {
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
              onPressed: _bridgeOnline && _queueTasks.any((task) => task.status == 'queued') && !runner.active
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
                      onDelete: task.isActive ? null : () => _deleteQueueTask(task.jobId),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: theme.brightness == Brightness.dark
            ? const Color(0x161AC6E4)
            : const Color(0x120F9FB8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 8),
          Text(value, style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(detail, style: theme.textTheme.bodyMedium),
        ],
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
  const _QueueTaskCard({
    required this.task,
    required this.onDelete,
  });

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
              thumbnailPath: task.sourceThumbnail,
            ),
            const SizedBox(width: 12),
            _QueueMediaPreview(
              label: 'TARGET',
              thumbnailPath: task.targetThumbnail,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(task.jobId, style: theme.textTheme.titleMedium),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: _statusColor(task.status).withValues(alpha: 0.14),
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
                      value: task.stepTotal == 0 ? 0 : task.completedSteps / task.stepTotal,
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
    required this.thumbnailPath,
  });

  final String label;
  final String? thumbnailPath;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
              child: thumbnailPath == null
                  ? Icon(
                      Icons.perm_media_outlined,
                      color: theme.colorScheme.primary,
                    )
                  : Image.file(
                      File(thumbnailPath!),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Icon(
                        Icons.broken_image_outlined,
                        color: theme.colorScheme.error,
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
    required this.targetPath,
    required this.targetThumbnail,
    required this.outputPath,
    required this.stepTotal,
    required this.completedSteps,
    required this.isActive,
  });

  factory _QueueTask.fromJson(Map<String, dynamic> json) {
    return _QueueTask(
      jobId: '${json['job_id'] ?? ''}',
      status: '${json['status'] ?? 'queued'}',
      sourcePaths:
          (json['source_paths'] as List<dynamic>? ?? const <dynamic>[])
              .map((item) => '$item')
              .toList(),
      sourceThumbnail: json['source_thumbnail'] as String?,
      targetPath: json['target_path'] as String?,
      targetThumbnail: json['target_thumbnail'] as String?,
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
  final String? targetPath;
  final String? targetThumbnail;
  final String? outputPath;
  final int stepTotal;
  final int completedSteps;
  final bool isActive;
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
