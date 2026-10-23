import 'package:faceswap_studio/app/theme/studio_depth.dart';
import 'package:faceswap_studio/features/about/presentation/about_page.dart';
import 'package:faceswap_studio/features/home/presentation/home_page.dart';
import 'package:faceswap_studio/features/personas/presentation/personas_page.dart';
import 'package:faceswap_studio/features/settings/presentation/settings_page.dart';
import 'package:faceswap_studio/features/works/presentation/works_page.dart';
import 'package:faceswap_studio/features/workspace/presentation/workspace_page.dart';
import 'package:faceswap_studio/shared/widgets/studio_brand_mark.dart';
import 'package:faceswap_studio/shared/widgets/studio_hover_focus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../shared/services/studio_fullscreen.dart';

enum StudioSection { home, workspace, personas, works, settings, about }

class StudioShell extends StatefulWidget {
  const StudioShell({
    required this.themeMode,
    required this.onToggleTheme,
    required this.sidebarExpanded,
    required this.onSidebarExpandedChanged,
    super.key,
  });

  final ThemeMode themeMode;
  final VoidCallback onToggleTheme;
  final bool sidebarExpanded;
  final ValueChanged<bool> onSidebarExpandedChanged;

  @override
  State<StudioShell> createState() => _StudioShellState();
}

class _StudioShellState extends State<StudioShell> {
  StudioSection _section = StudioSection.home;

  Widget _buildSection() {
    return switch (_section) {
      StudioSection.home => const HomePage(key: ValueKey('home')),
      StudioSection.workspace => const WorkspacePage(
        key: ValueKey('workspace'),
      ),
      StudioSection.personas => const PersonasPage(key: ValueKey('personas')),
      StudioSection.works => const WorksPage(key: ValueKey('works')),
      StudioSection.settings => SettingsPage(
        key: const ValueKey('settings'),
        themeMode: widget.themeMode,
        onToggleTheme: widget.onToggleTheme,
      ),
      StudioSection.about => const AboutPage(key: ValueKey('about')),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final expanded = widget.sidebarExpanded;
    const labels = ['首页', '工作台', '人物形象', '作品管理', '设置', '关于'];
    const icons = [
      Icons.space_dashboard_outlined,
      Icons.tune_rounded,
      Icons.badge_outlined,
      Icons.photo_library_outlined,
      Icons.settings_outlined,
      Icons.info_outline_rounded,
    ];
    final page = Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              width: expanded ? 236 : 122,
              decoration: BoxDecoration(
                color: scheme.surface,
                border: Border(right: BorderSide(color: scheme.outlineVariant)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 24),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const StudioBrandMark(),
                      if (expanded) ...[
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '易容 Studio',
                            style: theme.textTheme.titleMedium?.copyWith(
                              height: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 30),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(3, 4, 8, 12),
                      itemCount: labels.length,
                      separatorBuilder: (_, index) => const SizedBox(height: 9),
                      itemBuilder: (context, index) {
                        final selected = _section.index == index;
                        final color = selected
                            ? scheme.onPrimaryContainer
                            : scheme.onSurfaceVariant;
                        return Material(
                          elevation: selected ? 4 : 1.5,
                          shadowColor: Colors.black.withValues(
                            alpha: theme.brightness == Brightness.dark
                                ? 0.4
                                : 0.16,
                          ),
                          surfaceTintColor: Colors.transparent,
                          color: selected
                              ? scheme.primaryContainer
                              : scheme.surface,
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => setState(
                              () => _section = StudioSection.values[index],
                            ),
                            child: Container(
                              constraints: const BoxConstraints(minHeight: 65),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: selected
                                      ? scheme.primary.withValues(alpha: 0.16)
                                      : StudioDepth.borderColor(context),
                                ),
                              ),
                              padding: const EdgeInsets.symmetric(
                                vertical: 12,
                                horizontal: 8,
                              ),
                              child: expanded
                                  ? Row(
                                      children: [
                                        Icon(
                                          icons[index],
                                          size: 21,
                                          color: color,
                                        ),
                                        const SizedBox(width: 12),
                                        Text(
                                          labels[index],
                                          style: TextStyle(
                                            color: color,
                                            fontSize: 13,
                                            fontWeight: selected
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    )
                                  : Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          icons[index],
                                          size: 21,
                                          color: selected
                                              ? scheme.primary
                                              : color,
                                        ),
                                        const SizedBox(height: 7),
                                        Text(
                                          labels[index],
                                          style: TextStyle(
                                            color: color,
                                            fontSize: 12,
                                            fontWeight: selected
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Divider(),
                  ValueListenableBuilder<bool>(
                    valueListenable: StudioFullscreen.active,
                    builder: (_, active, _) => IconButton(
                      onPressed: StudioFullscreen.toggle,
                      tooltip: active ? '退出软件全屏（F11）' : '软件全屏（F11）',
                      icon: Icon(
                        active
                            ? Icons.fullscreen_exit_rounded
                            : Icons.fullscreen_rounded,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: widget.onToggleTheme,
                    tooltip: widget.themeMode == ThemeMode.dark
                        ? '浅色主题'
                        : '深色主题',
                    icon: Icon(
                      widget.themeMode == ThemeMode.dark
                          ? Icons.light_mode_outlined
                          : Icons.dark_mode_outlined,
                    ),
                  ),
                  IconButton(
                    onPressed: () => widget.onSidebarExpandedChanged(!expanded),
                    tooltip: expanded ? '折叠导航' : '展开导航',
                    icon: Icon(
                      expanded
                          ? Icons.keyboard_double_arrow_left_rounded
                          : Icons.keyboard_double_arrow_right_rounded,
                    ),
                  ),
                  if (expanded) ...[
                    const SizedBox(height: 10),
                    Text('本地 AI 换脸工作台', style: theme.textTheme.bodySmall),
                  ],
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: _section == StudioSection.workspace
                    ? const EdgeInsets.fromLTRB(24, 8, 24, 16)
                    : const EdgeInsets.all(24),
                child: _buildSection(),
              ),
            ),
          ],
        ),
      ),
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f11): StudioFullscreen.toggle,
      },
      child: Focus(autofocus: true, child: StudioHoverFocus(child: page)),
    );
  }
}
