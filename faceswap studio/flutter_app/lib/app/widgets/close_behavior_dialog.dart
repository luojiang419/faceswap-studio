import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/studio_depth.dart';

enum StudioCloseAction { exit, background }

class StudioCloseDecision {
  const StudioCloseDecision({required this.action, required this.askEveryTime});

  final StudioCloseAction action;
  final bool askEveryTime;
}

Future<StudioCloseDecision?> showStudioCloseDialog(
  BuildContext context, {
  StudioCloseAction initialAction = StudioCloseAction.background,
  bool askEveryTime = false,
}) => showDialog<StudioCloseDecision>(
  context: context,
  barrierDismissible: false,
  builder: (_) => StudioCloseDialog(
    initialAction: initialAction,
    askEveryTime: askEveryTime,
  ),
);

class StudioCloseDialog extends StatefulWidget {
  const StudioCloseDialog({
    super.key,
    this.initialAction = StudioCloseAction.background,
    this.askEveryTime = false,
  });

  final StudioCloseAction initialAction;
  final bool askEveryTime;

  @override
  State<StudioCloseDialog> createState() => _StudioCloseDialogState();
}

class _StudioCloseDialogState extends State<StudioCloseDialog> {
  late StudioCloseAction _action = widget.initialAction;
  late bool _askEveryTime = widget.askEveryTime;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final exit = _action == StudioCloseAction.exit;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.pop(context),
      },
      child: Focus(
        autofocus: true,
        child: Dialog(
          backgroundColor: colors.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: StudioDepth.borderColor(context)),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(24),
                boxShadow: StudioDepth.shadows(context, floating: true),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: colors.primary.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Icon(
                            Icons.power_settings_new_rounded,
                            color: colors.primary,
                            size: 26,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: '取消关闭',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded, size: 20),
                          style: IconButton.styleFrom(
                            foregroundColor: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    Text(
                      '关闭易容 Studio？',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontSize: 23,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text('选择关闭方式，将自动记住你的偏好。', style: theme.textTheme.bodySmall),
                    const SizedBox(height: 24),
                    _CloseActionTile(
                      action: StudioCloseAction.exit,
                      selected: exit,
                      title: '关闭软件',
                      description: '退出易容 Studio，结束后台进程',
                      icon: Icons.power_settings_new_rounded,
                      onSelected: () =>
                          setState(() => _action = StudioCloseAction.exit),
                    ),
                    const SizedBox(height: 12),
                    _CloseActionTile(
                      action: StudioCloseAction.background,
                      selected: !exit,
                      title: '后台运行',
                      description: '收起到系统托盘，任务继续运行',
                      icon: Icons.picture_in_picture_alt_rounded,
                      onSelected: () => setState(
                        () => _action = StudioCloseAction.background,
                      ),
                    ),
                    const SizedBox(height: 22),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: Text('每次询问', style: theme.textTheme.titleMedium),
                      subtitle: Text(
                        _askEveryTime ? '下次关闭窗口时仍显示此弹窗' : '记住本次选择，之后不再询问',
                        style: theme.textTheme.bodySmall,
                      ),
                      value: _askEveryTime,
                      onChanged: (value) =>
                          setState(() => _askEveryTime = value),
                    ),
                    const SizedBox(height: 12),
                    Divider(color: StudioDepth.borderColor(context)),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Icon(
                          Icons.tune_rounded,
                          size: 14,
                          color: colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '可随时在「设置 · 关闭行为」中修改',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('取消'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: FilledButton(
                            onPressed: () => Navigator.pop(
                              context,
                              StudioCloseDecision(
                                action: _action,
                                askEveryTime: _askEveryTime,
                              ),
                            ),
                            style: FilledButton.styleFrom(
                              backgroundColor: colors.primary,
                              foregroundColor: colors.onPrimary,
                              shadowColor: colors.primary.withValues(
                                alpha: 0.16,
                              ),
                            ),
                            child: Text(exit ? '确认关闭' : '转入后台'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CloseActionTile extends StatelessWidget {
  const _CloseActionTile({
    required this.action,
    required this.selected,
    required this.title,
    required this.description,
    required this.icon,
    required this.onSelected,
  });

  final StudioCloseAction action;
  final bool selected;
  final String title;
  final String description;
  final IconData icon;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          color: selected
              ? colors.primary.withValues(alpha: 0.08)
              : colors.surfaceContainer,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? colors.primary.withValues(alpha: 0.65)
                : StudioDepth.borderColor(context),
          ),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('close-action-${action.name}'),
            onTap: onSelected,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
              child: Row(
                children: [
                  Icon(
                    icon,
                    color: selected ? colors.primary : colors.onSurfaceVariant,
                    size: 23,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: theme.textTheme.titleMedium),
                        const SizedBox(height: 4),
                        Text(description, style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: selected ? colors.primary : colors.outline,
                    size: 21,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
