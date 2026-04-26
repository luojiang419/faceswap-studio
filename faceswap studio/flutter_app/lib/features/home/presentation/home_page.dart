import 'dart:async';

import 'package:faceswap_studio/shared/services/bridge_client.dart';
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
  int _lastLogId = 0;
  String _serviceState = 'stopped';
  String _serviceMessage = 'Bridge 未连接';
  String _webuiUrl = 'http://127.0.0.1:7860';
  int? _facefusionPid;
  _MetricsSnapshot? _metrics;

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
      ]);

      final status = results[0] as Map<String, dynamic>;
      final metrics = results[1] as Map<String, dynamic>;
      final logs = results[2] as Map<String, dynamic>;

      final entries =
          (logs['entries'] as List<dynamic>? ?? const <dynamic>[])
              .cast<Map<String, dynamic>>();

      final latestLogs = List<_LogEntry>.from(_logs)
        ..addAll(entries.map(_LogEntry.fromJson));
      if (latestLogs.length > 300) {
        latestLogs.removeRange(0, latestLogs.length - 300);
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
        _lastLogId = (logs['latest_id'] as num?)?.toInt() ?? _lastLogId;
        _logs
          ..clear()
          ..addAll(latestLogs);
      });
    } catch (error) {
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

  Future<void> _startFaceFusion() async {
    await _invokeAction(_client.startFaceFusion);
  }

  Future<void> _stopFaceFusion() async {
    await _invokeAction(_client.stopFaceFusion);
  }

  Future<void> _openBrowser() async {
    await _invokeAction(_client.openBrowser);
  }

  Future<void> _invokeAction(
    Future<Map<String, dynamic>> Function() action,
  ) async {
    try {
      await action();
    } catch (_) {
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('首页', style: theme.textTheme.headlineMedium)),
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
              onPressed: _bridgeOnline ? _openBrowser : null,
              icon: const Icon(Icons.open_in_browser_rounded),
              label: const Text('在浏览器打开'),
            ),
            const SizedBox(width: 10),
            IconButton(
              onPressed: _refresh,
              tooltip: '刷新状态',
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _bridgeOnline
              ? 'Bridge 已连接，当前通过本地 Python Bridge 控制 FaceFusion 启停、资源监控和日志采集。'
              : 'Bridge 当前不可用；如果你是直接运行 Flutter，可改用根目录启动脚本拉起完整联动环境。',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 18),
        Expanded(
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  children: [
                    _MetricCard(
                      title: 'FaceFusion 服务',
                      value: _serviceLabel,
                      detail:
                          '$_serviceMessage\nWebUI: $_webuiUrl${_facefusionPid == null ? '' : '\nPID: $_facefusionPid'}',
                    ),
                    const SizedBox(height: 14),
                    _MetricCard(
                      title: '系统资源',
                      value: _metrics == null ? '--' : '${_metrics!.cpuPercent.toStringAsFixed(0)}%',
                      detail:
                          _metrics == null
                              ? '等待 Bridge 返回系统指标'
                              : 'CPU ${_metrics!.cpuPercent.toStringAsFixed(1)}% · '
                                  '内存 ${_metrics!.memoryPercent.toStringAsFixed(1)}%\n'
                                  '${_metrics!.memoryUsedGb.toStringAsFixed(1)} / ${_metrics!.memoryTotalGb.toStringAsFixed(1)} GB',
                    ),
                    const SizedBox(height: 14),
                    _MetricCard(
                      title: 'GPU / 显存',
                      value: _metrics?.gpuPercent == null
                          ? '未检测'
                          : '${_metrics!.gpuPercent!.toStringAsFixed(0)}%',
                      detail:
                          _metrics?.gpuPercent == null
                              ? '未发现 nvidia-smi，已降级为仅展示 CPU / 内存'
                              : 'GPU ${_metrics!.gpuPercent!.toStringAsFixed(1)}%\n'
                                  '显存 ${_metrics!.gpuMemoryUsedMb}/${_metrics!.gpuMemoryTotalMb} MB · '
                                  '${_metrics!.gpuMemoryPercent!.toStringAsFixed(1)}%',
                    ),
                    const SizedBox(height: 14),
                    _MetricCard(
                      title: 'FaceFusion 进程',
                      value: _metrics?.facefusionProcess == null
                          ? '--'
                          : '${_metrics!.facefusionProcess!.cpuPercent.toStringAsFixed(0)}%',
                      detail:
                          _metrics?.facefusionProcess == null
                              ? 'FaceFusion 未运行'
                              : '进程 CPU ${_metrics!.facefusionProcess!.cpuPercent.toStringAsFixed(1)}%\n'
                                  '进程内存 ${_metrics!.facefusionProcess!.memoryMb.toStringAsFixed(1)} MB',
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                flex: 4,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text('运行日志', style: theme.textTheme.titleLarge),
                            const Spacer(),
                            Text(
                              _bridgeOnline ? 'Bridge 在线' : 'Bridge 离线',
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: _bridgeOnline
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.error,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Expanded(
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(18),
                              color: theme.brightness == Brightness.dark
                                  ? const Color(0xFF071019)
                                  : const Color(0xFFF8FBFF),
                            ),
                            child: _logs.isEmpty
                                ? Text(
                                    '暂无日志输出。\n启动 FaceFusion 后，这里会持续显示 Bridge 与 FaceFusion 的运行日志。',
                                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.7),
                                  )
                                : ListView.separated(
                                    itemCount: _logs.length,
                                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                                    itemBuilder: (context, index) {
                                      final item = _logs[index];
                                      return Text(
                                        '[${item.timestamp}] ${item.message}',
                                        style: theme.textTheme.bodyMedium?.copyWith(
                                          fontFamily: 'Consolas',
                                          height: 1.5,
                                        ),
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
            ],
          ),
        ),
      ],
    );
  }

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
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
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
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
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
              const Spacer(),
              Text(value, style: theme.textTheme.headlineMedium),
              const SizedBox(height: 12),
              Text(detail, style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
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
      facefusionProcess:
          processJson == null ? null : _FaceFusionProcessMetrics.fromJson(processJson),
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
