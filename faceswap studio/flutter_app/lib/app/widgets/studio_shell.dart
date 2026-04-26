import 'package:faceswap_studio/features/about/presentation/about_page.dart';
import 'package:faceswap_studio/features/home/presentation/home_page.dart';
import 'package:faceswap_studio/features/settings/presentation/settings_page.dart';
import 'package:faceswap_studio/features/works/presentation/works_page.dart';
import 'package:faceswap_studio/features/workspace/presentation/workspace_page.dart';
import 'package:flutter/material.dart';

enum StudioSection { home, workspace, works, settings, about }

class StudioShell extends StatefulWidget {
  const StudioShell({
    required this.themeMode,
    required this.onToggleTheme,
    super.key,
  });

  final ThemeMode themeMode;
  final VoidCallback onToggleTheme;

  @override
  State<StudioShell> createState() => _StudioShellState();
}

class _StudioShellState extends State<StudioShell> {
  StudioSection _section = StudioSection.home;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints.tightFor(width: 290),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Facefusion Studion',
                          style: theme.textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Flutter 桌面壳层已初始化，后续从这里接入 FaceFusion Bridge。',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 24),
                        Expanded(
                          child: NavigationRail(
                            extended: true,
                            selectedIndex: StudioSection.values.indexOf(_section),
                            onDestinationSelected: (index) {
                              setState(() {
                                _section = StudioSection.values[index];
                              });
                            },
                            destinations: const [
                              NavigationRailDestination(
                                icon: Icon(Icons.home_outlined),
                                selectedIcon: Icon(Icons.home_rounded),
                                label: Text('首页'),
                              ),
                              NavigationRailDestination(
                                icon: Icon(Icons.dashboard_customize_outlined),
                                selectedIcon: Icon(Icons.dashboard_customize),
                                label: Text('工作台'),
                              ),
                              NavigationRailDestination(
                                icon: Icon(Icons.photo_library_outlined),
                                selectedIcon: Icon(Icons.photo_library),
                                label: Text('作品管理'),
                              ),
                              NavigationRailDestination(
                                icon: Icon(Icons.settings_outlined),
                                selectedIcon: Icon(Icons.settings),
                                label: Text('设置'),
                              ),
                              NavigationRailDestination(
                                icon: Icon(Icons.info_outline),
                                selectedIcon: Icon(Icons.info),
                                label: Text('关于'),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: widget.onToggleTheme,
                          icon: Icon(
                            widget.themeMode == ThemeMode.dark
                                ? Icons.light_mode_outlined
                                : Icons.dark_mode_outlined,
                          ),
                          label: Text(
                            widget.themeMode == ThemeMode.dark ? '切换浅色主题' : '切换暗色主题',
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0x221AC6E4) : const Color(0x140F9FB8),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Text(
                            '当前阶段：Flutter 壳层骨架\n下阶段：Bridge + 首页运行控制',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: IndexedStack(
                  index: StudioSection.values.indexOf(_section),
                  children: [
                    const HomePage(key: ValueKey('home')),
                    const WorkspacePage(key: ValueKey('workspace')),
                    const WorksPage(key: ValueKey('works')),
                    SettingsPage(
                      key: const ValueKey('settings'),
                      themeMode: widget.themeMode,
                      onToggleTheme: widget.onToggleTheme,
                    ),
                    const AboutPage(key: ValueKey('about')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
