import 'dart:async';

import 'package:faceswap_studio/shared/services/bridge_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<void> showStudioUpdateDialog(
  BuildContext context, {
  required Map<String, dynamic> initialStatus,
  bool barrierDismissible = true,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (context) => StudioUpdateDialog(initialStatus: initialStatus),
  );
}

Future<void> startStudioUpdateFlow(
  BuildContext context, {
  required BridgeClient client,
  bool autoDownload = false,
  void Function(String message)? showMessage,
}) async {
  var status = await client.checkUpdates();
  if (!context.mounted) {
    return;
  }

  final state = '${status['state'] ?? ''}';
  if (autoDownload &&
      status['update_available'] == true &&
      status['delta_available'] == true &&
      state == 'update_available') {
    status = await client.downloadUpdate();
    if (!context.mounted) {
      return;
    }
  }

  final dialogState = '${status['state'] ?? ''}';
  final shouldShowDialog =
      {
        'update_available',
        'full_required',
        'downloading',
        'downloaded',
        'failed',
      }.contains(dialogState) ||
      status['scheduled_for_next_launch'] == true;

  if (!shouldShowDialog) {
    showMessage?.call('${status['message'] ?? '当前已是最新版本。'}');
    return;
  }

  await showStudioUpdateDialog(
    context,
    initialStatus: status,
    barrierDismissible:
        dialogState != 'downloading' && dialogState != 'applying',
  );
}

class StudioUpdateDialog extends StatefulWidget {
  const StudioUpdateDialog({required this.initialStatus, super.key});

  final Map<String, dynamic> initialStatus;

  @override
  State<StudioUpdateDialog> createState() => _StudioUpdateDialogState();
}

class _StudioUpdateDialogState extends State<StudioUpdateDialog> {
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

  Future<void> _schedule() async {
    if (_isBusy) {
      return;
    }
    setState(() {
      _actionInFlight = true;
      _status = {..._status, 'message': '正在安排下次启动时更新...', 'error': null};
    });
    try {
      final status = await _client.scheduleUpdate();
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
            'message': '安排下次启动更新失败。',
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

  Future<void> _copyExternalUrl() async {
    final url = _externalUrl;
    if (url.isEmpty || _isBusy) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('下载链接已复制。')));
  }

  bool get _isBusy {
    final state = '${_status['state'] ?? ''}';
    return _actionInFlight ||
        state == 'checking' ||
        state == 'downloading' ||
        state == 'applying';
  }

  String get _externalUrl {
    final fullInstallerUrl = '${_status['full_installer_url'] ?? ''}'.trim();
    if (fullInstallerUrl.isNotEmpty) {
      return fullInstallerUrl;
    }
    return '${_status['release_url'] ?? ''}'.trim();
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
    final scheduledForNextLaunch = _status['scheduled_for_next_launch'] == true;
    final canInstall = state == 'downloaded';
    final canDownload =
        hasDelta && {'update_available', 'failed'}.contains(state);
    final progressVisible =
        state == 'downloading' || state == 'downloaded' || totalBytes > 0;
    final title = switch (state) {
      'downloaded' when scheduledForNextLaunch => '更新已安排',
      'downloaded' => '更新已就绪',
      'downloading' => '下载更新',
      'failed' => '更新失败',
      'current' => '检查更新',
      _ => '发现新版本',
    };

    return AlertDialog(
      icon: Icon(
        state == 'failed'
            ? Icons.error_outline_rounded
            : state == 'downloaded'
            ? Icons.system_update_alt_rounded
            : state == 'current'
            ? Icons.verified_outlined
            : Icons.new_releases_outlined,
      ),
      title: Text(title),
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
            if (scheduledForNextLaunch) ...[
              const SizedBox(height: 12),
              Text(
                '已安排在下次启动时自动安装，关闭程序后再次启动即可完成更新。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
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
          child: Text(state == 'current' ? '知道了' : '稍后'),
        ),
        if (state == 'failed')
          OutlinedButton.icon(
            onPressed: _isBusy ? null : _retryCheck,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重新检查'),
          ),
        if (state == 'full_required' && _externalUrl.isNotEmpty)
          OutlinedButton.icon(
            onPressed: _isBusy ? null : _copyExternalUrl,
            icon: const Icon(Icons.link_rounded),
            label: Text(fullInstallerUrl.isNotEmpty ? '复制安装器链接' : '复制发布页链接'),
          ),
        if (canDownload)
          FilledButton.icon(
            onPressed: _isBusy ? null : _download,
            icon: const Icon(Icons.download_rounded),
            label: Text(state == 'failed' ? '重新下载' : '下载更新'),
          ),
        if (state == 'downloading')
          FilledButton.icon(
            onPressed: null,
            icon: const Icon(Icons.downloading_rounded),
            label: const Text('下载中'),
          ),
        if (canInstall && !scheduledForNextLaunch)
          OutlinedButton.icon(
            onPressed: _isBusy ? null : _schedule,
            icon: const Icon(Icons.schedule_rounded),
            label: const Text('下次启动时更新'),
          ),
        if (scheduledForNextLaunch)
          OutlinedButton.icon(
            onPressed: null,
            icon: const Icon(Icons.schedule_rounded),
            label: const Text('已安排下次启动'),
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text('$label：$value', style: theme.textTheme.labelLarge),
      ),
    );
  }
}
