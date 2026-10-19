import 'package:faceswap_studio/app/theme/studio_depth.dart';
import 'dart:async';

import 'package:faceswap_studio/shared/services/bridge_client.dart';
import 'package:faceswap_studio/shared/widgets/studio_update_dialog.dart';
import 'package:faceswap_studio/shared/widgets/runtime_control_panel.dart';
import 'package:flutter/material.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final BridgeClient _client = BridgeClient();
  final List<_LogEntry> _logs = <_LogEntry>[];
  Timer? _pollTimer;

  bool _bridgeOnline = false;
  bool _requestInFlight = false;
  bool _actionInFlight = false;
  int _lastLogId = 0;
  String _serviceState = 'stopped';
  String _serviceMessage = 'Bridge 未连接';
  String _webuiUrl = 'http://127.0.0.1:7860';
  int? _facefusionPid;
  _MetricsSnapshot? _metrics;
  bool _modelBootstrapPromptShown = false;
  bool _modelBootstrapReady = false;
  bool _updateCheckStarted = false;

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
      final results = await Future.wait<dynamic>([
        _client.getStatus(),
        _client.getMetrics(),
        _client.getLogs(after: _lastLogId),
        _client.getModelBootstrapStatus(),
      ]);

      final status = results[0] as Map<String, dynamic>;
      final metrics = results[1] as Map<String, dynamic>;
      final logs = results[2] as Map<String, dynamic>;
      final modelBootstrap = results[3] as Map<String, dynamic>;

      final entries = (logs['entries'] as List<dynamic>? ?? const <dynamic>[])
          .cast<Map<String, dynamic>>();
      final incomingLogs = entries
          .map(_LogEntry.fromJson)
          .toList()
          .reversed
          .toList();

      final latestLogs = List<_LogEntry>.from(incomingLogs)..addAll(_logs);
      if (latestLogs.length > 300) {
        latestLogs.removeRange(300, latestLogs.length);
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _bridgeOnline = true;
        _serviceState = '${status['state'] ?? 'unknown'}';
        _serviceMessage = '${status['status_message'] ?? 'Bridge 已连接'}';
        _webuiUrl = '${status['webui_url'] ?? _webuiUrl}';
        _facefusionPid = status['pid'] as int?;
        _metrics = _MetricsSnapshot.fromJson(metrics);
        _modelBootstrapReady = modelBootstrap['ready'] == true;
        _lastLogId = (logs['latest_id'] as num?)?.toInt() ?? _lastLogId;
        _logs
          ..clear()
          ..addAll(latestLogs);
      });
      _maybeShowModelBootstrapDialog(modelBootstrap);
      _maybeCheckForUpdates();
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _bridgeOnline = false;
        _serviceState = 'bridge_offline';
        _serviceMessage = 'Bridge 不可用，请通过启动脚本拉起应用。';
      });
    } finally {
      _requestInFlight = false;
    }
  }

  void _maybeShowModelBootstrapDialog(Map<String, dynamic> status) {
    final state = '${status['state'] ?? ''}';
    final shouldPrompt =
        !_modelBootstrapReady &&
        !_modelBootstrapPromptShown &&
        {'missing', 'starting', 'downloading', 'failed'}.contains(state);
    if (!shouldPrompt) {
      return;
    }

    _modelBootstrapPromptShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => const _ModelBootstrapDialog(),
      );
      await _refresh();
    });
  }

  void _maybeCheckForUpdates() {
    if (!_bridgeOnline || _updateCheckStarted) {
      return;
    }
    _updateCheckStarted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        return;
      }
      try {
        final settings = await _client.getSettings();
        if (settings['auto_check_updates'] == false || !mounted) return;
        await startStudioUpdateFlow(
          context,
          client: _client,
          autoDownload: true,
          automatic: true,
        );
        await _refresh();
      } catch (error) {
        if (!mounted) {
          return;
        }
        setState(() {
          _serviceMessage = '检查更新失败：$error';
        });
        _showMessage('检查更新失败，可稍后重试。');
      }
    });
  }

  Future<void> _startFaceFusion() async =>
      _invokeAction(_client.startFaceFusion);

  Future<void> _stopFaceFusion() async => _invokeAction(_client.stopFaceFusion);

  Future<void> _openBrowser() async => _invokeAction(_client.openBrowser);

  Future<void> _invokeAction(
    Future<Map<String, dynamic>> Function() action,
  ) async {
    if (_actionInFlight) {
      return;
    }
    setState(() {
      _actionInFlight = true;
    });
    try {
      final result = await action();
      if (result['ok'] == false) {
        _showMessage('${result['message'] ?? '操作失败。'}');
      }
    } catch (error) {
      _showMessage('操作失败：$error');
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 350));
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
      'bridge_offline' => '未连接',
      _ => _serviceState,
    };
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return _HomeDashboard(
          maxWidth: constraints.maxWidth,
          maxHeight: constraints.maxHeight,
          bridgeOnline: _bridgeOnline,
          serviceLabel: _serviceLabel,
          serviceMessage: _serviceMessage,
          webuiUrl: _webuiUrl,
          facefusionPid: _facefusionPid,
          metrics: _metrics,
          logs: _logs,
          busy: _actionInFlight,
          onStart: _startFaceFusion,
          onStop: _stopFaceFusion,
          onReload: _refresh,
          onOpenBrowser: _openBrowser,
        );
      },
    );
  }
}

class _ModelBootstrapDialog extends StatefulWidget {
  const _ModelBootstrapDialog();

  @override
  State<_ModelBootstrapDialog> createState() => _ModelBootstrapDialogState();
}

class _ModelBootstrapDialogState extends State<_ModelBootstrapDialog> {
  final BridgeClient _client = BridgeClient();
  Timer? _timer;

  Map<String, dynamic> _status = const <String, dynamic>{
    'state': 'missing',
    'message': '正在检查核心模型...',
    'percent': 0.0,
    'downloaded_bytes': 0,
    'total_bytes': 0,
    'speed_bps': 0.0,
  };
  bool _requestInFlight = false;
  bool _startingFaceFusion = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(
      const Duration(milliseconds: 700),
      (_) => _refresh(),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_requestInFlight) {
      return;
    }
    _requestInFlight = true;
    try {
      final status = await _client.getModelBootstrapStatus();
      if (!mounted) {
        return;
      }
      setState(() {
        _status = status;
      });
      if (status['ready'] == true) {
        await _startFaceFusionAndClose();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = {
            ..._status,
            'state': 'failed',
            'message': '模型状态读取失败。',
            'error': '$error',
          };
        });
      }
    } finally {
      _requestInFlight = false;
    }
  }

  Future<void> _startDownload() async {
    if (_isBusy) {
      return;
    }
    setState(() {
      _status = {
        ..._status,
        'state': 'starting',
        'message': '正在准备下载...',
        'error': null,
      };
    });
    try {
      final status = await _client.startModelBootstrap();
      if (mounted) {
        setState(() {
          _status = status;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = {
            ..._status,
            'state': 'failed',
            'message': '模型下载启动失败。',
            'error': '$error',
          };
        });
      }
    }
  }

  Future<void> _startFaceFusionAndClose() async {
    if (_startingFaceFusion) {
      return;
    }
    _startingFaceFusion = true;
    setState(() {
      _status = {..._status, 'message': '核心模型已完成，正在启动 FaceFusion...'};
    });
    try {
      await _client.startFaceFusion();
    } catch (_) {}
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  bool get _isBusy {
    final state = '${_status['state'] ?? ''}';
    return state == 'starting' || state == 'downloading' || _startingFaceFusion;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = '${_status['state'] ?? 'missing'}';
    final percent = ((_status['percent'] as num?)?.toDouble() ?? 0.0).clamp(
      0.0,
      100.0,
    );
    final downloadedBytes = (_status['downloaded_bytes'] as num?)?.toInt() ?? 0;
    final totalBytes = (_status['total_bytes'] as num?)?.toInt() ?? 0;
    final speedBps = (_status['speed_bps'] as num?)?.toDouble() ?? 0.0;
    final currentFile = '${_status['current_file'] ?? ''}';
    final currentLabel = '${_status['current_label'] ?? ''}';
    final error = '${_status['error'] ?? ''}';

    return AlertDialog(
      icon: Icon(
        state == 'failed'
            ? Icons.error_outline_rounded
            : Icons.cloud_download_outlined,
      ),
      title: const Text('下载核心模型'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${_status['message'] ?? '等待下载'}'),
            const SizedBox(height: 18),
            LinearProgressIndicator(value: percent <= 0 ? null : percent / 100),
            const SizedBox(height: 10),
            Row(
              children: [
                Text('${percent.toStringAsFixed(1)}%'),
                const Spacer(),
                Text(
                  '${_formatBytes(downloadedBytes)} / ${_formatBytes(totalBytes)}',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              speedBps > 0 ? '${_formatBytes(speedBps.round())}/s' : '等待网络响应',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (currentFile.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                currentLabel.isEmpty
                    ? currentFile
                    : '$currentLabel · $currentFile',
                style: theme.textTheme.bodyMedium,
              ),
            ],
            if (error.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                error,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton.icon(
          onPressed: _isBusy ? null : _startDownload,
          icon: Icon(
            state == 'failed' ? Icons.refresh_rounded : Icons.download_rounded,
          ),
          label: Text(state == 'failed' ? '重试下载' : '开始下载'),
        ),
      ],
    );
  }

  String _formatBytes(int value) {
    if (value <= 0) {
      return '0 B';
    }
    const units = ['B', 'KB', 'MB', 'GB'];
    var size = value.toDouble();
    var unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex += 1;
    }
    final fractionDigits = unitIndex == 0 ? 0 : 1;
    return '${size.toStringAsFixed(fractionDigits)} ${units[unitIndex]}';
  }
}

class _HomeDashboard extends StatelessWidget {
  const _HomeDashboard({
    required this.maxWidth,
    required this.maxHeight,
    required this.bridgeOnline,
    required this.serviceLabel,
    required this.serviceMessage,
    required this.webuiUrl,
    required this.facefusionPid,
    required this.metrics,
    required this.logs,
    required this.busy,
    required this.onStart,
    required this.onStop,
    required this.onReload,
    required this.onOpenBrowser,
  });

  final double maxWidth;
  final double maxHeight;
  final bool bridgeOnline;
  final String serviceLabel;
  final String serviceMessage;
  final String webuiUrl;
  final int? facefusionPid;
  final _MetricsSnapshot? metrics;
  final List<_LogEntry> logs;
  final bool busy;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onReload;
  final VoidCallback onOpenBrowser;

  @override
  Widget build(BuildContext context) {
    final metricsCards = <_MetricCardData>[
      _MetricCardData(
        title: 'CPU',
        value: metrics == null
            ? '--'
            : '${metrics!.cpuPercent.toStringAsFixed(0)}%',
        detail: metrics == null
            ? '等待系统指标'
            : '${metrics!.cpuPercent.toStringAsFixed(1)}%',
        icon: Icons.memory_rounded,
      ),
      _MetricCardData(
        title: '内存',
        value: metrics == null
            ? '--'
            : '${metrics!.memoryPercent.toStringAsFixed(0)}%',
        detail: metrics == null
            ? '等待系统指标'
            : '${metrics!.memoryUsedGb.toStringAsFixed(1)} / ${metrics!.memoryTotalGb.toStringAsFixed(1)} GB',
        icon: Icons.storage_rounded,
      ),
      _MetricCardData(
        title: 'GPU',
        value: metrics?.gpuPercent == null
            ? '未检测'
            : '${metrics!.gpuPercent!.toStringAsFixed(0)}%',
        detail: metrics?.gpuPercent == null
            ? '未发现 nvidia-smi'
            : '${metrics!.gpuPercent!.toStringAsFixed(1)}%',
        icon: Icons.graphic_eq_rounded,
      ),
      _MetricCardData(
        title: '显存',
        value: metrics?.gpuMemoryPercent == null
            ? '--'
            : '${metrics!.gpuMemoryPercent!.toStringAsFixed(0)}%',
        detail: metrics?.gpuMemoryPercent == null
            ? '等待 GPU 指标'
            : '${metrics!.gpuMemoryUsedMb}/${metrics!.gpuMemoryTotalMb} MB',
        icon: Icons.sd_storage_rounded,
      ),
      _MetricCardData(
        title: '进程 CPU',
        value: metrics?.facefusionProcess == null
            ? '--'
            : '${metrics!.facefusionProcess!.cpuPercent.toStringAsFixed(0)}%',
        detail: metrics?.facefusionProcess == null
            ? 'FaceFusion 未运行'
            : '${metrics!.facefusionProcess!.cpuPercent.toStringAsFixed(1)}%',
        icon: Icons.developer_board_rounded,
      ),
      _MetricCardData(
        title: '进程内存',
        value: metrics?.facefusionProcess == null
            ? '--'
            : '${metrics!.facefusionProcess!.memoryMb.toStringAsFixed(0)} MB',
        detail: metrics?.facefusionProcess == null
            ? 'FaceFusion 未运行'
            : '${metrics!.facefusionProcess!.memoryMb.toStringAsFixed(1)} MB',
        icon: Icons.dns_rounded,
      ),
    ];

    final compact = maxHeight < 820 || maxWidth < 1200;
    final overview = _HomeOverviewCard(
      compact: true,
      bridgeOnline: bridgeOnline,
      webuiUrl: webuiUrl,
      facefusionPid: facefusionPid,
      busy: busy,
      onReload: onReload,
      onOpenBrowser: onOpenBrowser,
    );
    final controls = _DashboardSurface(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: RuntimeControlPanel(
          compact: compact,
          bridgeOnline: bridgeOnline,
          busy: busy,
          serviceLabel: serviceLabel,
          serviceMessage: serviceMessage,
          webuiUrl: webuiUrl,
          facefusionPid: facefusionPid,
          onStart: onStart,
          onStop: onStop,
        ),
      ),
    );
    final resources = _MetricsGrid(cards: metricsCards, compact: compact);
    final logsPanel = _HomeLogCard(logs: logs);
    const gap = 16.0;

    if (maxWidth < 850 || maxHeight < 540) {
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            overview,
            const SizedBox(height: gap),
            controls,
            const SizedBox(height: gap),
            resources,
            const SizedBox(height: gap),
            SizedBox(height: 320, child: logsPanel),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        overview,
        const SizedBox(height: gap),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 6,
                child: LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    child: SizedBox(
                      height: constraints.maxHeight.clamp(
                        constraints.maxWidth < 600 ? 570.0 : 470.0,
                        double.infinity,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          controls,
                          const SizedBox(height: gap),
                          Expanded(child: resources),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: gap),
              Expanded(flex: 4, child: logsPanel),
            ],
          ),
        ),
      ],
    );
  }
}

/// 首页模块统一的边框、圆角与双层柔和投影。
class _DashboardSurface extends StatelessWidget {
  const _DashboardSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: StudioDepth.borderColor(context)),
        boxShadow: StudioDepth.shadows(context),
      ),
      child: child,
    );
  }
}

class _HomeOverviewCard extends StatelessWidget {
  const _HomeOverviewCard({
    this.compact = false,
    required this.bridgeOnline,
    required this.webuiUrl,
    required this.facefusionPid,
    required this.busy,
    required this.onReload,
    required this.onOpenBrowser,
  });

  final bool compact;
  final bool bridgeOnline;
  final String webuiUrl;
  final int? facefusionPid;
  final bool busy;
  final VoidCallback onReload;
  final VoidCallback onOpenBrowser;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summaryCards = <_SummaryCardData>[
      _SummaryCardData(
        title: '控制链路',
        value: bridgeOnline ? '已接管' : '等待连接',
        detail: 'Flutter -> Bridge -> FaceFusion',
      ),
      _SummaryCardData(
        title: '当前进程',
        value: facefusionPid == null ? '未运行' : '$facefusionPid',
        detail: facefusionPid == null ? '等待启动' : 'FaceFusion PID',
      ),
      _SummaryCardData(
        title: 'WebUI 地址',
        value: _compactUrl(webuiUrl),
        detail: webuiUrl,
      ),
    ];

    return _DashboardSurface(
      child: Padding(
        padding: EdgeInsets.all(compact ? 14 : 18),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 700
                ? 3
                : constraints.maxWidth >= 460
                ? 2
                : 1;
            final summarySpacing = compact ? 8.0 : 10.0;
            final itemWidth = _itemWidthFor(
              maxWidth: constraints.maxWidth,
              columns: columns,
              spacing: summarySpacing,
            );

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text('首页', style: theme.textTheme.titleLarge),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: bridgeOnline && !busy ? onReload : null,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('重新加载'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: bridgeOnline && !busy ? onOpenBrowser : null,
                      icon: const Icon(Icons.open_in_browser_rounded, size: 18),
                      label: const Text('浏览器打开'),
                    ),
                  ],
                ),
                SizedBox(height: compact ? 10 : 16),
                Wrap(
                  spacing: summarySpacing,
                  runSpacing: summarySpacing,
                  children: [
                    for (final card in summaryCards)
                      SizedBox(
                        width: itemWidth,
                        child: _SummaryMiniCard(card: card, compact: compact),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _MetricsGrid extends StatelessWidget {
  const _MetricsGrid({required this.cards, this.compact = false});

  final List<_MetricCardData> cards;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gridSpacing = compact ? 10.0 : 12.0;

    return _DashboardSurface(
      child: Padding(
        padding: EdgeInsets.all(compact ? 14 : 18),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 520
                ? 3
                : constraints.maxWidth >= 460
                ? 2
                : 1;
            final itemWidth = _itemWidthFor(
              maxWidth: constraints.maxWidth,
              columns: columns,
              spacing: gridSpacing,
            );

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '系统资源监控',
                  style:
                      (compact
                              ? theme.textTheme.titleSmall
                              : theme.textTheme.titleMedium)
                          ?.copyWith(fontWeight: FontWeight.w700),
                ),
                SizedBox(height: compact ? 3 : 6),
                Text(
                  '实时查看设备负载与推理进程占用',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: compact ? 1.15 : 1.35,
                    fontSize: compact ? 11.5 : null,
                  ),
                  maxLines: compact ? 1 : null,
                  overflow: compact ? TextOverflow.ellipsis : null,
                ),
                SizedBox(height: compact ? 8 : 14),
                if (constraints.hasBoundedHeight)
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, grid) {
                        final rows = (cards.length / columns).ceil();
                        final height =
                            (grid.maxHeight - gridSpacing * (rows - 1)) / rows;
                        return Wrap(
                          spacing: gridSpacing,
                          runSpacing: gridSpacing,
                          children: [
                            for (final card in cards)
                              SizedBox(
                                width: itemWidth,
                                height: height,
                                child: _MetricCard(
                                  card: card,
                                  compact: compact,
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  )
                else
                  Wrap(
                    spacing: gridSpacing,
                    runSpacing: gridSpacing,
                    children: [
                      for (final card in cards)
                        SizedBox(
                          width: itemWidth,
                          child: _MetricCard(card: card, compact: compact),
                        ),
                    ],
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.card, this.compact = false});

  final _MetricCardData card;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: compact ? 94 : 120),
      child: Container(
        padding: EdgeInsets.all(compact ? 10 : 14),
        decoration: BoxDecoration(
          color: theme.cardTheme.color,
          borderRadius: BorderRadius.circular(20),
          boxShadow: StudioDepth.shadows(context, subtle: true),
          border: Border.all(color: StudioDepth.borderColor(context)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  card.icon,
                  size: compact ? 14 : 15,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    card.title.toUpperCase(),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      letterSpacing: 0.8,
                      fontSize: compact ? 11 : null,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: compact ? 8 : 18),
            Text(
              card.value,
              style:
                  (compact
                          ? theme.textTheme.titleMedium
                          : theme.textTheme.titleLarge)
                      ?.copyWith(
                        fontWeight: FontWeight.w800,
                        height: 1.0,
                        fontSize: compact ? 22 : 32,
                      ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            SizedBox(height: compact ? 3 : 6),
            Text(
              card.detail,
              style: theme.textTheme.bodySmall?.copyWith(
                height: compact ? 1.12 : 1.25,
                fontSize: compact ? 11 : null,
              ),
              maxLines: compact ? 1 : 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeLogCard extends StatelessWidget {
  const _HomeLogCard({required this.logs});
  final List<_LogEntry> logs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return _DashboardSurface(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [Text('运行日志', style: theme.textTheme.titleMedium)],
            ),
            const SizedBox(height: 6),
            Text(
              'Bridge / FaceFusion · 最新日志在前',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  color: theme.brightness == Brightness.dark
                      ? const Color(0xFF171716)
                      : theme.colorScheme.surfaceContainerLowest,
                ),
                child: logs.isEmpty
                    ? Center(
                        child: Text(
                          '暂无日志输出。\n启动 FaceFusion 后，这里会持续显示运行日志。',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            height: 1.5,
                          ),
                        ),
                      )
                    : Scrollbar(
                        child: ListView.separated(
                          itemCount: logs.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 6),
                          itemBuilder: (context, index) {
                            final item = logs[index];
                            return Text(
                              '[${item.timestamp}] ${item.message}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontFamily: 'Consolas',
                                height: 1.35,
                              ),
                            );
                          },
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

class _SummaryMiniCard extends StatelessWidget {
  const _SummaryMiniCard({required this.card, this.compact = false});

  final _SummaryCardData card;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 9 : 12,
        vertical: compact ? 6 : 10,
      ),
      decoration: BoxDecoration(
        color: theme.brightness == Brightness.dark
            ? const Color(0xFF282724)
            : theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        boxShadow: StudioDepth.shadows(context, subtle: true),
        border: Border.all(color: StudioDepth.borderColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            card.title.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 0.75,
              fontSize: compact ? 9.5 : null,
            ),
          ),
          SizedBox(height: compact ? 3 : 6),
          Text(
            card.value,
            style:
                (compact
                        ? theme.textTheme.titleSmall
                        : theme.textTheme.titleMedium)
                    ?.copyWith(
                      fontWeight: FontWeight.w800,
                      height: 1.0,
                      fontSize: compact ? 13 : null,
                    ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          SizedBox(height: compact ? 1 : 4),
          Text(
            card.detail,
            style: theme.textTheme.bodySmall?.copyWith(
              height: compact ? 1.0 : 1.2,
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: compact ? 10.5 : null,
            ),
            maxLines: compact ? 1 : 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _MetricCardData {
  const _MetricCardData({
    required this.title,
    required this.value,
    required this.detail,
    required this.icon,
  });

  final String title;
  final String value;
  final String detail;
  final IconData icon;
}

class _SummaryCardData {
  const _SummaryCardData({
    required this.title,
    required this.value,
    required this.detail,
  });

  final String title;
  final String value;
  final String detail;
}

class _LogEntry {
  const _LogEntry({
    required this.id,
    required this.timestamp,
    required this.message,
  });

  factory _LogEntry.fromJson(Map<String, dynamic> json) {
    return _LogEntry(
      id: (json['id'] as num?)?.toInt() ?? 0,
      timestamp: '${json['timestamp'] ?? ''}',
      message: '${json['message'] ?? ''}',
    );
  }

  final int id;
  final String timestamp;
  final String message;
}

class _MetricsSnapshot {
  const _MetricsSnapshot({
    required this.cpuPercent,
    required this.memoryPercent,
    required this.memoryUsedGb,
    required this.memoryTotalGb,
    required this.gpuPercent,
    required this.gpuMemoryPercent,
    required this.gpuMemoryUsedMb,
    required this.gpuMemoryTotalMb,
    required this.facefusionProcess,
  });

  factory _MetricsSnapshot.fromJson(Map<String, dynamic> json) {
    final processJson = json['facefusion_process'] as Map<String, dynamic>?;
    return _MetricsSnapshot(
      cpuPercent: (json['cpu_percent'] as num?)?.toDouble() ?? 0,
      memoryPercent: (json['memory_percent'] as num?)?.toDouble() ?? 0,
      memoryUsedGb: (json['memory_used_gb'] as num?)?.toDouble() ?? 0,
      memoryTotalGb: (json['memory_total_gb'] as num?)?.toDouble() ?? 0,
      gpuPercent: (json['gpu_percent'] as num?)?.toDouble(),
      gpuMemoryPercent: (json['gpu_memory_percent'] as num?)?.toDouble(),
      gpuMemoryUsedMb: (json['gpu_memory_used_mb'] as num?)?.toInt(),
      gpuMemoryTotalMb: (json['gpu_memory_total_mb'] as num?)?.toInt(),
      facefusionProcess: processJson == null
          ? null
          : _FaceFusionProcessMetrics.fromJson(processJson),
    );
  }

  final double cpuPercent;
  final double memoryPercent;
  final double memoryUsedGb;
  final double memoryTotalGb;
  final double? gpuPercent;
  final double? gpuMemoryPercent;
  final int? gpuMemoryUsedMb;
  final int? gpuMemoryTotalMb;
  final _FaceFusionProcessMetrics? facefusionProcess;
}

class _FaceFusionProcessMetrics {
  const _FaceFusionProcessMetrics({
    required this.pid,
    required this.cpuPercent,
    required this.memoryMb,
  });

  factory _FaceFusionProcessMetrics.fromJson(Map<String, dynamic> json) {
    return _FaceFusionProcessMetrics(
      pid: (json['pid'] as num?)?.toInt() ?? 0,
      cpuPercent: (json['cpu_percent'] as num?)?.toDouble() ?? 0,
      memoryMb: (json['memory_mb'] as num?)?.toDouble() ?? 0,
    );
  }

  final int pid;
  final double cpuPercent;
  final double memoryMb;
}

double _itemWidthFor({
  required double maxWidth,
  required int columns,
  required double spacing,
}) {
  if (columns <= 1) {
    return maxWidth;
  }
  return (maxWidth - (columns - 1) * spacing) / columns;
}

String _compactUrl(String value) {
  return value.replaceFirst(RegExp(r'^https?://'), '');
}
