import 'package:faceswap_studio/shared/services/bridge_client.dart';
import 'package:faceswap_studio/shared/widgets/studio_update_dialog.dart';
import 'package:flutter/material.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  static const String _intro =
      'FaceSwap Studio 采用 Flutter 作为正式跨平台前端，'
      'FaceFusion 作为推理引擎，Python Bridge 作为中间适配层。';
  static const String _disclaimer =
      '本软件仅限合法、合规与经授权场景使用，不得用于侵犯他人肖像权、隐私权、'
      '著作权或任何非法用途，违者需自行承担全部法律责任。';
  static const String _contact = '联系作者：QQ 419773176 / 微信 15085152352';

  final BridgeClient _client = BridgeClient();

  bool _checkingUpdates = false;

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 1080;
        final sidePanelWidth = constraints.maxWidth >= 1440 ? 360.0 : 320.0;

        return SizedBox.expand(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: isWide
                  ? _buildWideLayout(theme, sidePanelWidth)
                  : _buildCompactLayout(theme),
            ),
          ),
        );
      },
    );
  }

  Widget _buildWideLayout(ThemeData theme, double sidePanelWidth) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('关于', style: theme.textTheme.headlineMedium),
        const SizedBox(height: 12),
        Text(_intro, style: theme.textTheme.bodyLarge?.copyWith(height: 1.55)),
        const SizedBox(height: 24),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _AboutPanel(
                      title: '使用说明',
                      icon: Icons.gpp_good_outlined,
                      child: Text(
                        _disclaimer,
                        style: theme.textTheme.bodyLarge?.copyWith(height: 1.7),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: _AboutPanel(
                        title: '技术架构',
                        icon: Icons.account_tree_outlined,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '当前桌面端以统一工作台为核心，负责连接推理能力、参数面板、生成队列和作品管理。',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                height: 1.6,
                              ),
                            ),
                            const SizedBox(height: 18),
                            Wrap(
                              spacing: 14,
                              runSpacing: 14,
                              children: const [
                                _AboutTechCard(label: '正式前端', value: 'Flutter'),
                                _AboutTechCard(
                                  label: '推理引擎',
                                  value: 'FaceFusion',
                                ),
                                _AboutTechCard(
                                  label: '适配层',
                                  value: 'Python Bridge',
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 24),
              SizedBox(
                width: sidePanelWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _AboutPanel(
                      title: '运行栈',
                      icon: Icons.layers_outlined,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '桌面壳层：Flutter Windows',
                            style: theme.textTheme.bodyLarge,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '生成能力：FaceFusion / FFmpeg / 本地模型资源',
                            style: theme.textTheme.bodyLarge,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '数据链路：Bridge 统一调度配置、队列和输出路径',
                            style: theme.textTheme.bodyLarge,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _AboutPanel(
                      title: '联系信息',
                      icon: Icons.alternate_email_rounded,
                      child: SelectableText(
                        _contact,
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _AboutPanel(
                      title: '版本更新',
                      icon: Icons.system_update_alt_rounded,
                      child: _buildUpdateContent(theme),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: _AboutPanel(
                        title: '当前阶段',
                        icon: Icons.rocket_launch_outlined,
                        child: Align(
                          alignment: Alignment.bottomLeft,
                          child: Text(
                            'Flutter Windows 桌面壳层骨架',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCompactLayout(ThemeData theme) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('关于', style: theme.textTheme.headlineMedium),
          const SizedBox(height: 12),
          Text(
            _intro,
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.55),
          ),
          const SizedBox(height: 18),
          _AboutPanel(
            title: '使用说明',
            icon: Icons.gpp_good_outlined,
            child: Text(
              _disclaimer,
              style: theme.textTheme.bodyLarge?.copyWith(height: 1.7),
            ),
          ),
          const SizedBox(height: 16),
          _AboutPanel(
            title: '技术架构',
            icon: Icons.account_tree_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '当前桌面端以统一工作台为核心，负责连接推理能力、参数面板、生成队列和作品管理。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: const [
                    _AboutTechCard(label: '正式前端', value: 'Flutter'),
                    _AboutTechCard(label: '推理引擎', value: 'FaceFusion'),
                    _AboutTechCard(label: '适配层', value: 'Python Bridge'),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _AboutPanel(
            title: '运行栈',
            icon: Icons.layers_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('桌面壳层：Flutter Windows', style: theme.textTheme.bodyLarge),
                const SizedBox(height: 10),
                Text(
                  '生成能力：FaceFusion / FFmpeg / 本地模型资源',
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 10),
                Text(
                  '数据链路：Bridge 统一调度配置、队列和输出路径',
                  style: theme.textTheme.bodyLarge,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _AboutPanel(
            title: '联系信息',
            icon: Icons.alternate_email_rounded,
            child: SelectableText(_contact, style: theme.textTheme.bodyLarge),
          ),
          const SizedBox(height: 16),
          _AboutPanel(
            title: '版本更新',
            icon: Icons.system_update_alt_rounded,
            child: _buildUpdateContent(theme),
          ),
          const SizedBox(height: 16),
          _AboutPanel(
            title: '当前阶段',
            icon: Icons.rocket_launch_outlined,
            child: Text(
              'Flutter Windows 桌面壳层骨架',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUpdateContent(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '可随时检查 GitHub 发布更新；发现可用增量包后，可直接在软件内下载并安装。',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.6,
          ),
        ),
        const SizedBox(height: 14),
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
    );
  }
}

class _AboutPanel extends StatelessWidget {
  const _AboutPanel({required this.title, required this.child, this.icon});

  final String title;
  final Widget child;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
              ],
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _AboutTechCard extends StatelessWidget {
  const _AboutTechCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: 176,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.24),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
