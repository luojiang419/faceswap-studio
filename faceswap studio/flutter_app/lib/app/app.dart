import 'package:faceswap_studio/app/theme/studio_theme.dart';
import 'package:faceswap_studio/app/widgets/studio_shell.dart';
import 'package:faceswap_studio/app/widgets/studio_window_lifecycle.dart';
import 'package:faceswap_studio/shared/services/bridge_client.dart';
import 'package:faceswap_studio/shared/services/startup_connection.dart';
import 'package:flutter/material.dart';

class FaceSwapStudioApp extends StatefulWidget {
  const FaceSwapStudioApp({super.key});

  @override
  State<FaceSwapStudioApp> createState() => _FaceSwapStudioAppState();
}

class _FaceSwapStudioAppState extends State<FaceSwapStudioApp> {
  final BridgeClient _client = BridgeClient();
  late final StartupConnection _startup;
  ThemeMode _themeMode = ThemeMode.light;
  bool _sidebarExpanded = false;

  @override
  void initState() {
    super.initState();
    _startup = StartupConnection(client: _client, onSettings: _applySettings);
    WidgetsBinding.instance.addPostFrameCallback((_) => _startup.start());
  }

  void _applySettings(Map<String, dynamic> settings) {
    if (!mounted) {
      return;
    }
    setState(() {
      _themeMode = '${settings['theme'] ?? 'light'}' == 'light'
          ? ThemeMode.light
          : ThemeMode.dark;
      _sidebarExpanded = settings['sidebar_expanded'] == true;
    });
  }

  @override
  void dispose() {
    _startup.dispose();
    super.dispose();
  }

  void _toggleTheme() {
    final nextTheme = _themeMode == ThemeMode.dark
        ? ThemeMode.light
        : ThemeMode.dark;
    setState(() {
      _themeMode = nextTheme;
    });
    _persistTheme(nextTheme);
  }

  Future<void> _persistTheme(ThemeMode mode) async {
    try {
      await _client.updateSettings({
        'theme': mode == ThemeMode.dark ? 'dark' : 'light',
      });
    } catch (_) {}
  }

  void _setSidebarExpanded(bool expanded) {
    if (_sidebarExpanded == expanded) {
      return;
    }
    setState(() {
      _sidebarExpanded = expanded;
    });
    _persistSidebarExpanded(expanded);
  }

  Future<void> _persistSidebarExpanded(bool expanded) async {
    try {
      await _client.updateSettings({'sidebar_expanded': expanded});
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '易容 Studio',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: StudioTheme.light(),
      darkTheme: StudioTheme.dark(),
      home: StudioWindowLifecycle(
        client: _client,
        child: StudioShell(
          themeMode: _themeMode,
          onToggleTheme: _toggleTheme,
          sidebarExpanded: _sidebarExpanded,
          onSidebarExpandedChanged: _setSidebarExpanded,
        ),
      ),
    );
  }
}
