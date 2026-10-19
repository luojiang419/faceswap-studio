import 'dart:convert';
import 'dart:io';

Directory? _studioRoot;

Future<Directory?> _findRoot() async {
  if (_studioRoot != null) return _studioRoot;
  if (!Platform.isWindows ||
      !Platform.resolvedExecutable.toLowerCase().endsWith(
        'faceswap_studio.exe',
      )) {
    return null;
  }
  var directory = File(Platform.resolvedExecutable).parent;
  for (var depth = 0; depth < 8; depth++) {
    final studio = Directory('${directory.path}/faceswap studio');
    if (await Directory('${studio.path}/runtime').exists()) {
      _studioRoot = studio;
      return studio;
    }
    directory = directory.parent;
  }
  return null;
}

Future<Map<String, dynamic>> _read(String relative) async {
  try {
    final studio = await _findRoot();
    if (studio == null) return {};
    final text = await File('${studio.path}/$relative').readAsString();
    return jsonDecode(text.replaceFirst('\uFEFF', '')) as Map<String, dynamic>;
  } catch (_) {
    return {};
  }
}

Future<Map<String, dynamic>> readLocalStartupSettings() async {
  final saved = await _read('runtime/settings.json');
  return saved.isNotEmpty ? saved : _read('config/settings.json');
}

Future<Map<String, dynamic>> readLocalStartupState() =>
    _read('runtime/startup-state.json');
