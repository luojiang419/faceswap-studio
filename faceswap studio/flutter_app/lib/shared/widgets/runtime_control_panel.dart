import 'package:flutter/material.dart';

class RuntimeControlPanel extends StatelessWidget {
  const RuntimeControlPanel({
    this.compact = false,
    required this.bridgeOnline,
    required this.busy,
    required this.serviceLabel,
    required this.serviceMessage,
    required this.webuiUrl,
    required this.facefusionPid,
    required this.onStart,
    required this.onStop,
    required this.onOpenBrowser,
    super.key,
  });

  final bool compact;
  final bool bridgeOnline;
  final bool busy;
  final String serviceLabel;
  final String serviceMessage;
  final String webuiUrl;
  final int? facefusionPid;
  final VoidCallback? onStart;
  final VoidCallback? onStop;
  final VoidCallback? onOpenBrowser;

  bool get _isFaceFusionRunning =>
      serviceLabel == '在线' || serviceLabel == '启动中' || serviceLabel == '停止中';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = serviceLabel == '在线' || serviceLabel == '启动中';

    return LayoutBuilder(
      builder: (context, constraints) {
        final topGap = compact ? 8.0 : 14.0;
        final bodyGap = compact ? 5.0 : 8.0;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: active
                            ? const Color(0xFF22C55E)
                            : theme.colorScheme.onSurfaceVariant.withValues(
                                alpha: 0.6,
                              ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '运行控制',
                      style:
                          (compact
                                  ? theme.textTheme.labelMedium
                                  : theme.textTheme.labelLarge)
                              ?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                letterSpacing: compact ? 0.7 : 0.9,
                              ),
                    ),
                  ],
                ),
                _InlineStatusBadge(
                  active: bridgeOnline,
                  label: bridgeOnline ? 'Bridge 在线' : 'Bridge 离线',
                ),
              ],
            ),
            SizedBox(height: topGap),
            Text(
              serviceLabel,
              style:
                  (compact
                          ? theme.textTheme.titleMedium
                          : theme.textTheme.headlineSmall)
                      ?.copyWith(fontWeight: FontWeight.w800, height: 1.0),
            ),
            SizedBox(height: bodyGap),
            Text(
              serviceMessage,
              style:
                  (compact
                          ? theme.textTheme.bodySmall
                          : theme.textTheme.bodyMedium)
                      ?.copyWith(
                        height: compact ? 1.1 : 1.35,
                        fontSize: compact ? 11.5 : null,
                      ),
              maxLines: compact ? 1 : null,
              overflow: compact ? TextOverflow.ellipsis : null,
            ),
            SizedBox(height: bodyGap),
            Text(
              facefusionPid == null
                  ? webuiUrl
                  : 'PID $facefusionPid · $webuiUrl',
              style: theme.textTheme.bodySmall?.copyWith(
                height: compact ? 1.15 : 1.3,
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: compact ? 11 : null,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            SizedBox(height: compact ? 10 : 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: bridgeOnline && !_isFaceFusionRunning && !busy
                      ? onStart
                      : null,
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('启动 FaceFusion'),
                  style: FilledButton.styleFrom(
                    minimumSize: Size(compact ? 156 : 178, 38),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    textStyle: TextStyle(
                      fontFamily: theme.textTheme.labelLarge?.fontFamily,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: bridgeOnline && _isFaceFusionRunning && !busy
                      ? onStop
                      : null,
                  icon: const Icon(Icons.stop_rounded, size: 16),
                  label: const Text('停止'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(82, 38),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    textStyle: TextStyle(
                      fontFamily: theme.textTheme.labelLarge?.fontFamily,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: bridgeOnline && !busy ? onOpenBrowser : null,
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: const Text('浏览器打开'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(126, 38),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    textStyle: TextStyle(
                      fontFamily: theme.textTheme.labelLarge?.fontFamily,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _InlineStatusBadge extends StatelessWidget {
  const _InlineStatusBadge({required this.active, required this.label});

  final bool active;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color:
            (active
                    ? theme.colorScheme.primary
                    : theme.colorScheme.surfaceContainerHighest)
                .withValues(alpha: active ? 0.14 : 0.72),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: active
              ? theme.colorScheme.primary.withValues(alpha: 0.24)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          color: active
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
