import 'package:faceswap_studio/app/theme/studio_theme.dart';
import 'package:faceswap_studio/app/widgets/studio_shell.dart';
import 'package:faceswap_studio/shared/services/bridge_client.dart';
import 'package:flutter/material.dart';

class FaceSwapStudioApp extends StatefulWidget {
  const FaceSwapStudioApp({super.key});

  @override
  State<FaceSwapStudioApp> createState() => _FaceSwapStudioAppState();
}

class _FaceSwapStudioAppState extends State<FaceSwapStudioApp> {
  final BridgeClient _client = BridgeClient();
  ThemeMode _themeMode = ThemeMode.dark;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final settings = await _client.getSettings();
      if (!mounted) {
        return;
      }
      setState(() {
        _themeMode = '${settings['theme'] ?? 'dark'}' == 'light' ? ThemeMode.light : ThemeMode.dark;
      });
    } catch (_) {
    }
  }

  void _toggleTheme() {
    final nextTheme = _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
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
    } catch (_) {
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Facefusion Studion',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: StudioTheme.light(),
      darkTheme: StudioTheme.dark(),
      home: StudioShell(
        themeMode: _themeMode,
        onToggleTheme: _toggleTheme,
      ),
    );
  }
}
