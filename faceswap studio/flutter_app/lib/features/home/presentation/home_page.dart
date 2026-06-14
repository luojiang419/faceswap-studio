import 'dart:async';

import 'package:faceswap_studio/shared/services/bridge_client.dart';
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
  bool _updatePromptShown = false;

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
        final status = await _client.checkUpdates();
        if (!mounted) {
          return;
        }
        final state = '${status['state'] ?? ''}';
        final shouldPrompt =
            status['update_available'] == true &&
            !_updatePromptShown &&
            {
              'update_available',
              'downloading',
              'downloaded',
              'failed',
              'full_required',
            }.contains(state);
        if (!shouldPrompt) {
          return;
        }
        _updatePromptShown = true;
        await showDialog<void>(
          context: context,
          barrierDismissible: state != 'downloading' && state != 'applying',
          builder: (context) => _UpdateDialog(initialStatus: status),
        );
        await _refresh();
      } catch (_) {}
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
      await action();
    } catch (_) {
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
      'bridge_offline' => 'Bridge 离线',
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

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.initialStatus});

  final Map<String, dynamic> initialStatus;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  final BridgeClient _client = BridgeClient();
  Timer? _timer;

  late Map<String, dynamic> _status;
  bool _requestInFlight = false;
  bool _actionInFlight = false;

  @override
  void initState() {
    super.initState();
    _status = Map<String, dynamic>.from(widget.initialStatus);
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
      final status = await _client.getUpdateStatus();
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
            'message': '更新状态读取失败。',
            'error': '$error',
          };
        });
      }
    } finally {
      _requestInFlight = false;
    }
  }

  Future<void> _download() async {
    if (_isBusy) {
      return;
    }
    setState(() {
      _actionInFlight = true;
      _status = {
        ..._status,
        'state': 'downloading',
        'message': '正在下载更新包...',
        'error': null,
      };
    });
    try {
      final status = await _client.downloadUpdate();
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
            'message': '更新下载启动失败。',
            'error': '$error',
          };
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _actionInFlight = false;
        });
      }
    }
  }

  Future<void> _retryCheck() async {
    if (_isBusy) {
      return;
    }
    setState(() {
      _actionInFlight = true;
      _status = {
        ..._status,
        'state': 'checking',
        'message': '正在重新检查更新...',
        'error': null,
      };
    });
    try {
      final status = await _client.checkUpdates();
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
            'message': '检查更新失败。',
            'error': '$error',
          };
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _actionInFlight = false;
        });
      }
    }
  }

  Future<void> _apply() async {
    if (_isBusy) {
      return;
    }
    setState(() {
      _actionInFlight = true;
      _status = {
        ..._status,
        'state': 'applying',
        'message': '正在启动更新程序...',
        'error': null,
      };
    });
    try {
      final status = await _client.applyUpdate();
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
            'message': '更新程序启动失败。',
            'error': '$error',
          };
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _actionInFlight = false;
        });
      }
    }
  }

  bool get _isBusy {
    final state = '${_status['state'] ?? ''}';
    return _actionInFlight ||
        state == 'checking' ||
        state == 'downloading' ||
        state == 'applying';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = '${_status['state'] ?? 'idle'}';
    final currentVersion = '${_status['current_version'] ?? '--'}';
    final latestVersion = '${_status['latest_version'] ?? '--'}';
    final percent = ((_status['percent'] as num?)?.toDouble() ?? 0.0).clamp(
      0.0,
      100.0,
    );
    final downloadedBytes = (_status['downloaded_bytes'] as num?)?.toInt() ?? 0;
    final totalBytes = (_status['total_bytes'] as num?)?.toInt() ?? 0;
    final speedBps = (_status['speed_bps'] as num?)?.toDouble() ?? 0.0;
    final assetName = '${_status['asset_name'] ?? ''}';
    final error = '${_status['error'] ?? ''}';
    final fullInstallerUrl = '${_status['full_installer_url'] ?? ''}';
    final releaseUrl = '${_status['release_url'] ?? ''}';
    final hasDelta = _status['delta_available'] == true;
    final canInstall = state == 'downloaded';
    final canDownload =
        hasDelta && {'update_available', 'failed'}.contains(state);
    final progressVisible =
        state == 'downloading' || state == 'downloaded' || totalBytes > 0;

    return AlertDialog(
      icon: Icon(
        state == 'failed'
            ? Icons.error_outline_rounded
            : state == 'downloaded'
            ? Icons.system_update_alt_rounded
            : Icons.new_releases_outlined,
      ),
      title: const Text('发现新版本'),
      content: SizedBox(
        width: 540,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${_status['message'] ?? '发现可用更新。'}'),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                _UpdateInfoChip(label: '当前版本', value: currentVersion),
                _UpdateInfoChip(label: '最新版本', value: latestVersion),
                if (totalBytes > 0)
                  _UpdateInfoChip(
                    label: '更新包',
                    value: _formatBytes(totalBytes),
                  ),
              ],
            ),
            if (assetName.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                assetName,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (progressVisible) ...[
              const SizedBox(height: 18),
              LinearProgressIndicator(
                value: state == 'downloading' && percent <= 0
                    ? null
                    : percent / 100,
              ),
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
                speedBps > 0
                    ? '${_formatBytes(speedBps.round())}/s'
                    : state == 'downloaded'
                    ? '下载完成'
                    : '等待网络响应',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (state == 'full_required' && fullInstallerUrl.isNotEmpty) ...[
              const SizedBox(height: 14),
              SelectableText(
                fullInstallerUrl,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ] else if (state == 'full_required' && releaseUrl.isNotEmpty) ...[
              const SizedBox(height: 14),
              SelectableText(
                releaseUrl,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
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
        TextButton(
          onPressed: _isBusy ? null : () => Navigator.of(context).pop(),
          child: const Text('稍后'),
        ),
        if (state == 'failed')
          OutlinedButton.icon(
            onPressed: _isBusy ? null : _retryCheck,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重新检查'),
          ),
        if (canDownload)
          FilledButton.icon(
            onPressed: _isBusy ? null : _download,
            icon: const Icon(Icons.download_rounded),
            label: const Text('立即更新'),
          ),
        if (state == 'downloading')
          FilledButton.icon(
            onPressed: null,
            icon: const Icon(Icons.downloading_rounded),
            label: const Text('下载中'),
          ),
        if (canInstall)
          FilledButton.icon(
            onPressed: _isBusy ? null : _apply,
            icon: const Icon(Icons.system_update_alt_rounded),
            label: const Text('安装并重启'),
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

class _UpdateInfoChip extends StatelessWidget {
  const _UpdateInfoChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Text(
          '$label  $value',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
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
  final VoidCallback onOpenBrowser;

  bool get _useTwoPaneLayout => maxWidth >= 960;
  bool get _useStableDefaultWindowLayout =>
      _useTwoPaneLayout && (maxWidth <= 1040 || maxHeight <= 660);

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

    final mainPane = _HomeMainPane(
      bridgeOnline: bridgeOnline,
      serviceLabel: serviceLabel,
      serviceMessage: serviceMessage,
      webuiUrl: webuiUrl,
      facefusionPid: facefusionPid,
      metricsCards: metricsCards,
      busy: busy,
      onStart: onStart,
      onStop: onStop,
      onOpenBrowser: onOpenBrowser,
    );
    final logPane = _HomeLogCard(bridgeOnline: bridgeOnline, logs: logs);

    if (_useStableDefaultWindowLayout) {
      return _StableHomeThreePane(
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        bridgeOnline: bridgeOnline,
        serviceLabel: serviceLabel,
        serviceMessage: serviceMessage,
        webuiUrl: webuiUrl,
        facefusionPid: facefusionPid,
        metricsCards: metricsCards,
        logs: logs,
        busy: busy,
        onStart: onStart,
        onStop: onStop,
        onOpenBrowser: onOpenBrowser,
      );
    }

    if (_useTwoPaneLayout) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            flex: 64,
            child: LayoutBuilder(
              builder: (context, paneConstraints) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.only(right: 4),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minWidth: paneConstraints.maxWidth,
                      minHeight: maxHeight,
                    ),
                    child: mainPane,
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 16),
          Flexible(flex: 36, child: logPane),
        ],
      );
    }

    var logHeight = maxHeight * 0.52;
    if (logHeight < 360) {
      logHeight = 360;
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.only(right: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          mainPane,
          const SizedBox(height: 16),
          SizedBox(height: logHeight, child: logPane),
        ],
      ),
    );
  }
}

class _HomeMainPane extends StatelessWidget {
  const _HomeMainPane({
    required this.bridgeOnline,
    required this.serviceLabel,
    required this.serviceMessage,
    required this.webuiUrl,
    required this.facefusionPid,
    required this.metricsCards,
    required this.busy,
    required this.onStart,
    required this.onStop,
    required this.onOpenBrowser,
  });

  final bool bridgeOnline;
  final String serviceLabel;
  final String serviceMessage;
  final String webuiUrl;
  final int? facefusionPid;
  final List<_MetricCardData> metricsCards;
  final bool busy;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onOpenBrowser;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HomeOverviewCard(
          bridgeOnline: bridgeOnline,
          serviceLabel: serviceLabel,
          webuiUrl: webuiUrl,
          facefusionPid: facefusionPid,
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: RuntimeControlPanel(
              compact: false,
              bridgeOnline: bridgeOnline,
              busy: busy,
              serviceLabel: serviceLabel,
              serviceMessage: serviceMessage,
              webuiUrl: webuiUrl,
              facefusionPid: facefusionPid,
              onStart: onStart,
              onStop: onStop,
              onOpenBrowser: onOpenBrowser,
            ),
          ),
        ),
        const SizedBox(height: 16),
        _MetricsGrid(cards: metricsCards),
      ],
    );
  }
}

class _HomeOverviewCard extends StatelessWidget {
  const _HomeOverviewCard({
    this.compact = false,
    required this.bridgeOnline,
    required this.serviceLabel,
    required this.webuiUrl,
    required this.facefusionPid,
  });

  final bool compact;
  final bool bridgeOnline;
  final String serviceLabel;
  final String webuiUrl;
  final int? facefusionPid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summaryCards = <_SummaryCardData>[
      _SummaryCardData(
        title: 'Bridge',
        value: bridgeOnline ? '在线' : '离线',
        detail: '本地桥接',
      ),
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

    return Card(
      child: Padding(
        padding: EdgeInsets.all(compact ? 14 : 18),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= (compact ? 620 : 760)
                ? 4
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
                Text(
                  '首页',
                  style: compact
                      ? theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        )
                      : theme.textTheme.headlineMedium,
                ),
                SizedBox(height: compact ? 6 : 8),
                Text(
                  bridgeOnline
                      ? '左侧主区聚合运行概览、控制与资源监控，右侧整列持续显示运行日志。'
                      : 'Bridge 当前离线，请先恢复本地桥接环境后再启动 FaceFusion。',
                  style:
                      (compact
                              ? theme.textTheme.bodyMedium
                              : theme.textTheme.bodyLarge)
                          ?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: compact ? 1.18 : 1.4,
                            fontSize: compact ? 13 : null,
                          ),
                  maxLines: compact ? 1 : null,
                  overflow: compact ? TextOverflow.ellipsis : null,
                ),
                SizedBox(height: compact ? 10 : 14),
                Wrap(
                  spacing: summarySpacing,
                  runSpacing: summarySpacing,
                  children: [
                    _StatusPill(
                      compact: compact,
                      active: bridgeOnline,
                      label: bridgeOnline ? 'Bridge 在线' : 'Bridge 离线',
                    ),
                    _StatusPill(
                      compact: compact,
                      active: serviceLabel == '在线' || serviceLabel == '启动中',
                      label: 'FaceFusion $serviceLabel',
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

    return Card(
      child: Padding(
        padding: EdgeInsets.all(compact ? 14 : 18),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= (compact ? 620 : 760)
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
                  '关键系统指标与 FaceFusion 进程占用会持续刷新，宽度不足时会自动换列。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: compact ? 1.15 : 1.35,
                    fontSize: compact ? 11.5 : null,
                  ),
                  maxLines: compact ? 1 : null,
                  overflow: compact ? TextOverflow.ellipsis : null,
                ),
                SizedBox(height: compact ? 8 : 14),
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
      constraints: BoxConstraints(minHeight: compact ? 80 : 108),
      child: Container(
        padding: EdgeInsets.all(compact ? 10 : 14),
        decoration: BoxDecoration(
          color: theme.cardTheme.color,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
          ),
        ),
        child: Column(
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
                      ?.copyWith(fontWeight: FontWeight.w800, height: 1.0),
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
  const _HomeLogCard({required this.bridgeOnline, required this.logs});

  final bool bridgeOnline;
  final List<_LogEntry> logs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('运行日志', style: theme.textTheme.titleMedium),
                _StatusPill(
                  active: bridgeOnline,
                  label: bridgeOnline ? 'Bridge 在线' : 'Bridge 离线',
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Bridge 与 FaceFusion 的日志会持续汇总到这里，最新日志显示在最前面。',
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
                      ? const Color(0xFF071019)
                      : const Color(0xFFF8FBFF),
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
            ? const Color(0x161AC6E4)
            : const Color(0x120F9FB8),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.22),
        ),
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

class _StatusPill extends StatelessWidget {
  const _StatusPill({
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
                .withValues(alpha: active ? 0.16 : 0.7),
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

class _StableHomeThreePane extends StatelessWidget {
  const _StableHomeThreePane({
    required this.maxWidth,
    required this.maxHeight,
    required this.bridgeOnline,
    required this.serviceLabel,
    required this.serviceMessage,
    required this.webuiUrl,
    required this.facefusionPid,
    required this.metricsCards,
    required this.logs,
    required this.busy,
    required this.onStart,
    required this.onStop,
    required this.onOpenBrowser,
  });

  final double maxWidth;
  final double maxHeight;
  final bool bridgeOnline;
  final String serviceLabel;
  final String serviceMessage;
  final String webuiUrl;
  final int? facefusionPid;
  final List<_MetricCardData> metricsCards;
  final List<_LogEntry> logs;
  final bool busy;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onOpenBrowser;

  @override
  Widget build(BuildContext context) {
    const gap = 12.0;
    const designWidth = 1046.0;
    const designHeight = 748.0;
    const logWidth = 272.0;
    const overviewHeight = 224.0;
    const controlHeight = 196.0;
    const sectionGap = 12.0;

    final leftWidth = designWidth - logWidth - gap;
    final metricsHeight =
        designHeight - overviewHeight - controlHeight - (sectionGap * 2);

    return Center(
      child: FittedBox(
        fit: BoxFit.contain,
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: designWidth,
          height: designHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: leftWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: overviewHeight,
                      child: _HomeOverviewCard(
                        compact: true,
                        bridgeOnline: bridgeOnline,
                        serviceLabel: serviceLabel,
                        webuiUrl: webuiUrl,
                        facefusionPid: facefusionPid,
                      ),
                    ),
                    const SizedBox(height: sectionGap),
                    SizedBox(
                      height: controlHeight,
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: RuntimeControlPanel(
                            compact: true,
                            bridgeOnline: bridgeOnline,
                            busy: busy,
                            serviceLabel: serviceLabel,
                            serviceMessage: serviceMessage,
                            webuiUrl: webuiUrl,
                            facefusionPid: facefusionPid,
                            onStart: onStart,
                            onStop: onStop,
                            onOpenBrowser: onOpenBrowser,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: sectionGap),
                    SizedBox(
                      height: metricsHeight,
                      child: _MetricsGrid(cards: metricsCards, compact: true),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: gap),
              SizedBox(
                width: logWidth,
                child: _HomeLogCard(bridgeOnline: bridgeOnline, logs: logs),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
