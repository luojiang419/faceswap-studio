import 'package:faceswap_studio/shared/services/bridge_client.dart';
import 'package:faceswap_studio/shared/widgets/studio_update_dialog.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    required this.themeMode,
    required this.onToggleTheme,
    super.key,
  });

  final ThemeMode themeMode;
  final VoidCallback onToggleTheme;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const String _domesticMirrorMode = 'domestic_mirror';
  static const String _systemProxyMode = 'system_proxy';
  static const String _customProxyMode = 'custom_proxy';
  static const String _closeBehaviorMinimizeToTray = 'minimize_to_tray';
  static const String _closeBehaviorExit = 'exit';
  static const String _defaultCustomProxyUrl = 'http://127.0.0.1:7890';
  static const double _defaultContentAnalyserScore = 100;
  static const double _minContentAnalyserScore = 100;
  static const double _maxContentAnalyserScore = 300;
  static const int _contentAnalyserScoreDivisions = 40;
  static const Set<String> _downloadModes = <String>{
    _domesticMirrorMode,
    _systemProxyMode,
    _customProxyMode,
  };
  static const Set<String> _closeBehaviors = <String>{
    _closeBehaviorMinimizeToTray,
    _closeBehaviorExit,
  };

  final BridgeClient _client = BridgeClient();
  static const MethodChannel _windowChannel = MethodChannel(
    'faceswap_studio/window',
  );
  final TextEditingController _outputController = TextEditingController();
  final TextEditingController _customProxyController = TextEditingController();

  bool _loading = true;
  String _downloadMode = _domesticMirrorMode;
  String _closeBehavior = _closeBehaviorMinimizeToTray;
  double _contentAnalyserScore = _defaultContentAnalyserScore;
  String _statusMessage = '正在读取设置...';
  String _savedOutputDir = '';
  String _savedDownloadMode = _domesticMirrorMode;
  String _savedCustomProxyUrl = '';
  String _savedCloseBehavior = _closeBehaviorMinimizeToTray;
  double _savedContentAnalyserScore = _defaultContentAnalyserScore;
  bool _studioStatusLoading = true;
  bool _studioAvailable = false;
  String _studioStatusMessage = '正在检查实验性 Web 工作台...';
  String _studioLocalUrl = '';
  List<String> _studioLanUrls = const <String>[];
  bool _checkingUpdates = false;
  bool _autoCheckUpdates = true;

  bool get _hasUnsavedChanges =>
      _outputController.text.trim() != _savedOutputDir ||
      _downloadMode != _savedDownloadMode ||
      _customProxyController.text.trim() != _savedCustomProxyUrl ||
      _closeBehavior != _savedCloseBehavior ||
      (_contentAnalyserScore - _savedContentAnalyserScore).abs() > 0.001;

  String get _visibleStatusMessage {
    if (_loading) {
      return _statusMessage;
    }
    if (_hasUnsavedChanges) {
      if (_statusMessage.startsWith('保存设置失败')) {
        return '有未保存更改。$_statusMessage';
      }
      return '有未保存更改，请点击“保存设置”应用。';
    }
    return _statusMessage;
  }

  @override
  void initState() {
    super.initState();
    _outputController.addListener(_handleSettingsEdited);
    _customProxyController.addListener(_handleSettingsEdited);
    _loadSettings();
    _loadStudioStatus();
  }

  @override
  void dispose() {
    _outputController.removeListener(_handleSettingsEdited);
    _customProxyController.removeListener(_handleSettingsEdited);
    _outputController.dispose();
    _customProxyController.dispose();
    super.dispose();
  }

  void _handleSettingsEdited() {
    if (!mounted || _loading) {
      return;
    }
    setState(() {});
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

  Future<void> _checkForUpdates() async {
    if (_checkingUpdates) {
      return;
    }
    setState(() {
      _checkingUpdates = true;
    });
    try {
      await startStudioUpdateFlow(
        context,
        client: _client,
        autoDownload: true,
        showMessage: _showMessage,
      );
    } catch (error) {
      _showMessage('检查更新失败：$error');
    } finally {
      if (mounted) {
        setState(() {
          _checkingUpdates = false;
        });
      }
    }
  }

  Future<void> _loadSettings() async {
    try {
      final settings = await _client.getSettings();
      _autoCheckUpdates = settings['auto_check_updates'] != false;
      final outputDir = '${settings['default_output_dir'] ?? ''}';
      final downloadMode = _normalizeDownloadMode(
        '${settings['model_download_mode'] ?? _domesticMirrorMode}',
      );
      final closeBehavior = _normalizeCloseBehavior(
        '${settings['close_behavior'] ?? _closeBehaviorMinimizeToTray}',
      );
      final customProxyUrl =
          '${settings['custom_proxy_url'] ?? _defaultCustomProxyUrl}';
      final contentAnalyserScore = _normalizeContentAnalyserScore(
        settings['content_analyser_score'],
      );
      _outputController.text = outputDir;
      _downloadMode = downloadMode;
      _closeBehavior = closeBehavior;
      _contentAnalyserScore = contentAnalyserScore;
      await _applyCloseBehaviorToWindow(_closeBehavior);
      _customProxyController.text = customProxyUrl;
      _rememberSavedSettings(
        outputDir: outputDir,
        downloadMode: downloadMode,
        customProxyUrl: customProxyUrl,
        closeBehavior: closeBehavior,
        contentAnalyserScore: contentAnalyserScore,
      );
      _statusMessage =
          '修改输出目录、模型下载方式、自定义代理、关闭行为或 NSFW 阈值后保存。新设置会在下次启动 FaceFusion 时生效。';
    } catch (error) {
      _statusMessage = '读取设置失败: $error';
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _selectOutputDirectory() async {
    final selected = await getDirectoryPath(
      initialDirectory: _outputController.text,
    );
    if (selected == null) {
      return;
    }
    _outputController.text = selected;
  }

  Future<void> _loadStudioStatus() async {
    if (mounted) {
      setState(() {
        _studioStatusLoading = true;
      });
    }
    try {
      final status = await _client.getStudioStatus();
      _applyStudioStatus(status);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _studioAvailable = false;
        _studioStatusMessage = '检查 Web 工作台失败: $error';
        _studioLocalUrl = '';
        _studioLanUrls = const <String>[];
        _studioStatusLoading = false;
      });
    }
  }

  Future<void> _openStudioBrowser() async {
    if (_studioStatusLoading) {
      return;
    }
    setState(() {
      _studioStatusLoading = true;
      _studioStatusMessage = '正在打开实验性 Web 工作台...';
    });
    try {
      final status = await _client.openStudioBrowser();
      _applyStudioStatus(status);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _studioStatusMessage = '打开 Web 工作台失败: $error';
        _studioStatusLoading = false;
      });
    }
  }

  void _applyStudioStatus(Map<String, dynamic> status) {
    if (!mounted) {
      return;
    }
    final lanUrls = (status['lan_urls'] as List<dynamic>? ?? const <dynamic>[])
        .map((item) => '$item')
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    setState(() {
      _studioAvailable = status['available'] == true;
      _studioStatusMessage = '${status['message'] ?? 'Web 工作台状态未知。'}';
      _studioLocalUrl = '${status['local_url'] ?? ''}';
      _studioLanUrls = lanUrls;
      _studioStatusLoading = false;
    });
  }

  Future<void> _saveSettings() async {
    if (_loading || !_hasUnsavedChanges) {
      return;
    }
    setState(() {
      _loading = true;
      _statusMessage = '正在保存设置...';
    });
    try {
      final settings = await _client.updateSettings({
        'default_output_dir': _outputController.text.trim(),
        'theme': widget.themeMode == ThemeMode.dark ? 'dark' : 'light',
        'model_download_mode': _downloadMode,
        'custom_proxy_url': _customProxyController.text.trim(),
        'close_behavior': _closeBehavior,
        'content_analyser_score': _contentAnalyserScore,
      });
      final outputDir = '${settings['default_output_dir'] ?? ''}';
      final downloadMode = _normalizeDownloadMode(
        '${settings['model_download_mode'] ?? _domesticMirrorMode}',
      );
      final closeBehavior = _normalizeCloseBehavior(
        '${settings['close_behavior'] ?? _closeBehaviorMinimizeToTray}',
      );
      final customProxyUrl =
          '${settings['custom_proxy_url'] ?? _defaultCustomProxyUrl}';
      final contentAnalyserScore = _normalizeContentAnalyserScore(
        settings['content_analyser_score'],
      );
      _outputController.text = outputDir;
      _downloadMode = downloadMode;
      _closeBehavior = closeBehavior;
      _contentAnalyserScore = contentAnalyserScore;
      await _applyCloseBehaviorToWindow(_closeBehavior);
      _customProxyController.text = customProxyUrl;
      _rememberSavedSettings(
        outputDir: outputDir,
        downloadMode: downloadMode,
        customProxyUrl: customProxyUrl,
        closeBehavior: closeBehavior,
        contentAnalyserScore: contentAnalyserScore,
      );
      _statusMessage =
          '设置已保存。关闭行为已立即生效；如果 FaceFusion 已启动，建议停止后重新启动，以让新的输出目录、下载方式和 NSFW 阈值生效。';
    } catch (error) {
      _statusMessage = '保存设置失败: $error';
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  String _normalizeDownloadMode(String value) {
    return _downloadModes.contains(value) ? value : _domesticMirrorMode;
  }

  String _normalizeCloseBehavior(String value) {
    return _closeBehaviors.contains(value)
        ? value
        : _closeBehaviorMinimizeToTray;
  }

  double _normalizeContentAnalyserScore(Object? value) {
    final parsed = double.tryParse('$value');
    if (parsed == null) {
      return _defaultContentAnalyserScore;
    }
    final clamped = parsed.clamp(
      _minContentAnalyserScore,
      _maxContentAnalyserScore,
    );
    return (clamped / 5).roundToDouble() * 5;
  }

  void _rememberSavedSettings({
    required String outputDir,
    required String downloadMode,
    required String customProxyUrl,
    required String closeBehavior,
    required double contentAnalyserScore,
  }) {
    _savedOutputDir = outputDir.trim();
    _savedDownloadMode = downloadMode;
    _savedCustomProxyUrl = customProxyUrl.trim();
    _savedCloseBehavior = closeBehavior;
    _savedContentAnalyserScore = contentAnalyserScore;
  }

  Future<void> _applyCloseBehaviorToWindow(String closeBehavior) async {
    try {
      await _windowChannel.invokeMethod<void>('setCloseBehavior', {
        'close_behavior': closeBehavior,
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('设置', style: theme.textTheme.headlineMedium)),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: _checkingUpdates ? null : _checkForUpdates,
              icon: _checkingUpdates
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.system_update_alt_rounded),
              label: Text(_checkingUpdates ? '检查中' : '检查更新'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '这里负责保存主题、默认输出目录和模型下载方式。输出目录由本地 Bridge 持久化，并作为队列与作品管理的统一根目录。',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 18),
        Expanded(
          child: Card(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启动时检查软件更新'),
                    subtitle: const Text('通过魔搭检查签名更新，安装前会提示；保留模型、配置与作品。'),
                    value: _autoCheckUpdates,
                    onChanged: _loading
                        ? null
                        : (value) async {
                            try {
                              await _client.updateSettings({
                                'auto_check_updates': value,
                              });
                              if (mounted) {
                                setState(() => _autoCheckUpdates = value);
                              }
                            } catch (error) {
                              _showMessage('更新设置保存失败：$error');
                            }
                          },
                  ),
                  const Divider(height: 28),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('主题模式'),
                    subtitle: Text(
                      widget.themeMode == ThemeMode.dark
                          ? '当前为暗色主题'
                          : '当前为浅色主题',
                    ),
                    trailing: Switch(
                      value: widget.themeMode == ThemeMode.dark,
                      onChanged: (_) => widget.onToggleTheme(),
                    ),
                  ),
                  const Divider(height: 28),
                  Text('默认输出目录', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _outputController,
                    enabled: !_loading,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: '选择 易容 Studio 默认输出目录',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: _loading ? null : _selectOutputDirectory,
                        icon: const Icon(Icons.folder_open_rounded),
                        label: const Text('选择目录'),
                      ),
                    ],
                  ),
                  const Divider(height: 28),
                  Text('关闭行为', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 10),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const <ButtonSegment<String>>[
                      ButtonSegment<String>(
                        value: _closeBehaviorMinimizeToTray,
                        icon: Icon(Icons.minimize_rounded),
                        label: Text('最小化到托盘'),
                      ),
                      ButtonSegment<String>(
                        value: _closeBehaviorExit,
                        icon: Icon(Icons.close_rounded),
                        label: Text('关闭程序'),
                      ),
                    ],
                    selected: <String>{_closeBehavior},
                    onSelectionChanged: _loading
                        ? null
                        : (selection) {
                            if (selection.isEmpty) {
                              return;
                            }
                            setState(() {
                              _closeBehavior = selection.first;
                            });
                          },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _closeBehavior == _closeBehaviorMinimizeToTray
                        ? '点击窗口关闭按钮时会隐藏到系统托盘，可从托盘恢复或退出。'
                        : '点击窗口关闭按钮时会直接退出 易容 Studio。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Divider(height: 28),
                  Text('模型下载方式', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(
                    '优先从魔搭补齐模型；标记“外网下载”的模型自动检测并使用系统代理。已安装模型会校验复用。',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: const <ButtonSegment<String>>[
                        ButtonSegment<String>(
                          value: _domesticMirrorMode,
                          icon: Icon(Icons.cloud_download_outlined),
                          label: Text('魔搭直连'),
                        ),
                        ButtonSegment<String>(
                          value: _systemProxyMode,
                          icon: Icon(Icons.settings_ethernet_rounded),
                          label: Text('系统代理'),
                        ),
                        ButtonSegment<String>(
                          value: _customProxyMode,
                          icon: Icon(Icons.tune_rounded),
                          label: Text('自定义代理'),
                        ),
                      ],
                      selected: <String>{_downloadMode},
                      onSelectionChanged: _loading
                          ? null
                          : (selection) {
                              if (selection.isEmpty) {
                                return;
                              }
                              setState(() {
                                _downloadMode = selection.first;
                              });
                            },
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _customProxyController,
                    enabled: !_loading && _downloadMode == _customProxyMode,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: '自定义代理地址',
                      hintText: 'http://127.0.0.1:7890',
                    ),
                  ),
                  const Divider(height: 28),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'NSFW 检测阈值',
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      Text(
                        _contentAnalyserScore.toStringAsFixed(0),
                        style: theme.textTheme.titleMedium,
                      ),
                    ],
                  ),
                  Slider(
                    value: _contentAnalyserScore,
                    min: _minContentAnalyserScore,
                    max: _maxContentAnalyserScore,
                    divisions: _contentAnalyserScoreDivisions,
                    label: _contentAnalyserScore.toStringAsFixed(0),
                    onChanged: _loading
                        ? null
                        : (value) {
                            setState(() {
                              _contentAnalyserScore =
                                  _normalizeContentAnalyserScore(value);
                            });
                          },
                  ),
                  Text(
                    '默认 100，提高后可减少误判；FaceFusion 已启动时请重启后生效。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _loading || !_hasUnsavedChanges
                        ? null
                        : _saveSettings,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('保存设置'),
                  ),
                  const Divider(height: 28),
                  Text('实验性功能', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 10),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.42),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.science_outlined,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Web 工作台（实验性开发）',
                                      style: theme.textTheme.titleSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '用于在浏览器端体验工作台和生成队列。当前仍在实验阶段，入口暂放在设置页，不进入主导航。',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              FilledButton.tonalIcon(
                                onPressed:
                                    _studioStatusLoading || !_studioAvailable
                                    ? null
                                    : _openStudioBrowser,
                                icon: const Icon(Icons.open_in_browser_rounded),
                                label: const Text('打开 Web 工作台（实验性）'),
                              ),
                              OutlinedButton.icon(
                                onPressed: _studioStatusLoading
                                    ? null
                                    : _loadStudioStatus,
                                icon: const Icon(Icons.refresh_rounded),
                                label: const Text('刷新状态'),
                              ),
                              if (_studioStatusLoading)
                                const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _studioStatusMessage,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: _studioAvailable
                                  ? theme.colorScheme.onSurfaceVariant
                                  : theme.colorScheme.error,
                            ),
                          ),
                          if (_studioLocalUrl.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Text('本机地址', style: theme.textTheme.labelLarge),
                            SelectableText(_studioLocalUrl),
                          ],
                          if (_studioLanUrls.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Text('局域网地址', style: theme.textTheme.labelLarge),
                            for (final url in _studioLanUrls)
                              SelectableText(url),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 28),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('状态'),
                    subtitle: Text(_visibleStatusMessage),
                    trailing: _loading
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                  ),
                  const Divider(height: 28),
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Windows 首发策略'),
                    subtitle: Text(
                      '当前按 Windows 优先开发与验证，后续再扩展 macOS / Linux 适配。',
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
}
