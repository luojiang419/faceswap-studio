import 'package:faceswap_studio/app/theme/studio_depth.dart';
import 'package:faceswap_studio/app/theme/studio_theme.dart';
import 'package:faceswap_studio/app/widgets/close_behavior_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    final font = FontLoader('Microsoft YaHei UI')
      ..addFont(rootBundle.load('preview-font/msyh.ttc'));
    await font.load();
  }
  runApp(
    CloseBehaviorPreviewApp(
      initialThemeMode: Uri.base.queryParameters['theme'] == 'light'
          ? ThemeMode.light
          : ThemeMode.dark,
    ),
  );
}

class CloseBehaviorPreviewApp extends StatefulWidget {
  const CloseBehaviorPreviewApp({
    super.key,
    this.initialThemeMode = ThemeMode.dark,
    this.autoOpen = true,
  });

  final ThemeMode initialThemeMode;
  final bool autoOpen;

  @override
  State<CloseBehaviorPreviewApp> createState() =>
      _CloseBehaviorPreviewAppState();
}

class _CloseBehaviorPreviewAppState extends State<CloseBehaviorPreviewApp> {
  late ThemeMode _themeMode = widget.initialThemeMode;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: '易容 Studio · 关闭行为演示',
    theme: StudioTheme.light(),
    darkTheme: StudioTheme.dark(),
    themeMode: _themeMode,
    home: _PreviewHome(
      autoOpen: widget.autoOpen,
      onToggleTheme: () => setState(() {
        _themeMode = _themeMode == ThemeMode.dark
            ? ThemeMode.light
            : ThemeMode.dark;
      }),
    ),
  );
}

enum _Preference { exit, background, ask }

class _PreviewHome extends StatefulWidget {
  const _PreviewHome({required this.autoOpen, required this.onToggleTheme});

  final bool autoOpen;
  final VoidCallback onToggleTheme;

  @override
  State<_PreviewHome> createState() => _PreviewHomeState();
}

class _PreviewHomeState extends State<_PreviewHome> {
  _Preference? _preference;
  StudioCloseAction _lastAction = StudioCloseAction.background;
  StudioCloseAction? _closedState;
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _requestClose());
    }
  }

  Future<void> _requestClose() async {
    if (_dialogOpen) return;
    if (_preference == _Preference.exit ||
        _preference == _Preference.background) {
      setState(() {
        _closedState = _preference == _Preference.exit
            ? StudioCloseAction.exit
            : StudioCloseAction.background;
      });
      return;
    }
    _dialogOpen = true;
    final decision = await showStudioCloseDialog(
      context,
      initialAction: _lastAction,
      askEveryTime: _preference == _Preference.ask,
    );
    _dialogOpen = false;
    if (!mounted || decision == null) return;
    setState(() {
      _lastAction = decision.action;
      _preference = decision.askEveryTime
          ? _Preference.ask
          : decision.action == StudioCloseAction.exit
          ? _Preference.exit
          : _Preference.background;
      _closedState = decision.action;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final status = switch (_preference) {
      null => '首次关闭时询问，确认后记住你的选择。',
      _Preference.exit => '已记住：关闭软件。下次关闭时直接退出。',
      _Preference.background => '已记住：后台运行。下次关闭时直接收起到托盘。',
      _Preference.ask => '每次关闭窗口时，都会询问你希望如何处理。',
    };

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              height: 62,
              padding: const EdgeInsets.only(left: 24, right: 12),
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border(
                  bottom: BorderSide(color: StudioDepth.borderColor(context)),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.masks_outlined, color: colors.primary, size: 25),
                  const SizedBox(width: 12),
                  Text('易容 Studio', style: theme.textTheme.titleMedium),
                  const SizedBox(width: 14),
                  Text('交互演示', style: theme.textTheme.bodySmall),
                  const Spacer(),
                  IconButton(
                    tooltip: '切换主题',
                    onPressed: widget.onToggleTheme,
                    icon: Icon(
                      theme.brightness == Brightness.dark
                          ? Icons.light_mode_outlined
                          : Icons.dark_mode_outlined,
                    ),
                  ),
                  IconButton(
                    tooltip: '演示点击关闭',
                    onPressed: _requestClose,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(28),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 660),
                    child: Container(
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: StudioDepth.borderColor(context),
                        ),
                        boxShadow: StudioDepth.shadows(context),
                      ),
                      child: _closedState == null
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('关闭行为', style: theme.textTheme.titleLarge),
                                const SizedBox(height: 8),
                                Text(status, style: theme.textTheme.bodyMedium),
                                const SizedBox(height: 24),
                                LayoutBuilder(
                                  builder: (context, constraints) =>
                                      SegmentedButton<_Preference>(
                                        showSelectedIcon: false,
                                        direction: constraints.maxWidth < 420
                                            ? Axis.vertical
                                            : Axis.horizontal,
                                        segments: const [
                                          ButtonSegment(
                                            value: _Preference.exit,
                                            label: Text('关闭软件'),
                                          ),
                                          ButtonSegment(
                                            value: _Preference.background,
                                            label: Text('后台运行'),
                                          ),
                                          ButtonSegment(
                                            value: _Preference.ask,
                                            label: Text('每次询问'),
                                          ),
                                        ],
                                        emptySelectionAllowed:
                                            _preference == null,
                                        selected: {?_preference},
                                        onSelectionChanged: (selection) =>
                                            setState(() {
                                              if (selection.isNotEmpty) {
                                                _preference = selection.first;
                                              }
                                            }),
                                      ),
                                ),
                                const SizedBox(height: 28),
                                Wrap(
                                  spacing: 12,
                                  runSpacing: 12,
                                  children: [
                                    FilledButton.icon(
                                      onPressed: _requestClose,
                                      icon: const Icon(
                                        Icons.close_rounded,
                                        size: 18,
                                      ),
                                      label: const Text('演示点击关闭'),
                                    ),
                                    OutlinedButton(
                                      onPressed: () {
                                        setState(() => _preference = null);
                                        _requestClose();
                                      },
                                      child: const Text('重新体验首次关闭'),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 22),
                                Text(
                                  '此处仅演示关闭效果，不会退出正在使用的软件。',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            )
                          : Column(
                              children: [
                                Icon(
                                  _closedState == StudioCloseAction.exit
                                      ? Icons.power_settings_new_rounded
                                      : Icons.picture_in_picture_alt_rounded,
                                  size: 40,
                                  color: colors.primary,
                                ),
                                const SizedBox(height: 20),
                                Text(
                                  _closedState == StudioCloseAction.exit
                                      ? '已演示关闭软件'
                                      : '已演示转入后台',
                                  style: theme.textTheme.titleLarge,
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  status,
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyMedium,
                                ),
                                const SizedBox(height: 26),
                                FilledButton(
                                  onPressed: () =>
                                      setState(() => _closedState = null),
                                  child: Text(
                                    _closedState == StudioCloseAction.exit
                                        ? '重新打开演示窗口'
                                        : '从托盘恢复演示窗口',
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  '恢复后再次点击右上角关闭，体验已记住的行为。',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ),
                    ),
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
