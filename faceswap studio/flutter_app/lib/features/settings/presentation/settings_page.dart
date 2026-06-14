import 'package:faceswap_studio/shared/services/bridge_client.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

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
  static const Set<String> _downloadModes = <String>{
    _domesticMirrorMode,
    _systemProxyMode,
    _customProxyMode,
  };

  final BridgeClient _client = BridgeClient();
  final TextEditingController _outputController = TextEditingController();
  final TextEditingController _customProxyController = TextEditingController();

  bool _loading = true;
  String _downloadMode = _domesticMirrorMode;
  String _statusMessage = '正在读取设置...';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _outputController.dispose();
    _customProxyController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    try {
      final settings = await _client.getSettings();
      _outputController.text = '${settings['default_output_dir'] ?? ''}';
      _downloadMode = _normalizeDownloadMode(
        '${settings['model_download_mode'] ?? _domesticMirrorMode}',
      );
      _customProxyController.text =
          '${settings['custom_proxy_url'] ?? 'http://127.0.0.1:7890'}';
      _statusMessage = '修改输出目录或模型下载方式后保存。新设置会在下次启动 FaceFusion 时生效。';
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
    setState(() {
      _outputController.text = selected;
    });
  }

  Future<void> _saveSettings() async {
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
      });
      _outputController.text = '${settings['default_output_dir'] ?? ''}';
      _downloadMode = _normalizeDownloadMode(
        '${settings['model_download_mode'] ?? _domesticMirrorMode}',
      );
      _customProxyController.text =
          '${settings['custom_proxy_url'] ?? 'http://127.0.0.1:7890'}';
      _statusMessage = '设置已保存。如果 FaceFusion 已启动，建议停止后重新启动，以让新的输出目录和下载方式生效。';
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('设置', style: theme.textTheme.headlineMedium),
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
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: '选择 FaceSwap Studio 默认输出目录',
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
                  Text('模型下载方式', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 10),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: const <ButtonSegment<String>>[
                        ButtonSegment<String>(
                          value: _domesticMirrorMode,
                          icon: Icon(Icons.cloud_download_outlined),
                          label: Text('国内镜像源'),
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
                    enabled: _downloadMode == _customProxyMode,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: '自定义代理地址',
                      hintText: 'http://127.0.0.1:7890',
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _loading ? null : _saveSettings,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('保存设置'),
                  ),
                  const Divider(height: 28),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('状态'),
                    subtitle: Text(_statusMessage),
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
