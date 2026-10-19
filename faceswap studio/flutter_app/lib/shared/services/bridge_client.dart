import 'dart:convert';
import 'bridge_environment.dart';

import 'package:http/http.dart' as http;

class BridgeClient {
  BridgeClient({String? baseUrl})
    : _baseUrl = _normalizeBaseUrl(baseUrl ?? _defaultBaseUrl());

  final String _baseUrl;
  static const Duration _defaultTimeout = Duration(seconds: 20);
  static const Duration _previewTimeout = Duration(seconds: 330);
  static const Duration _uploadTimeout = Duration(seconds: 330);

  String get baseUrl => _baseUrl;

  static String _defaultBaseUrl() {
    const configured = String.fromEnvironment('FACESWAP_STUDIO_BRIDGE_URL');
    if (configured.isNotEmpty) {
      return configured;
    }
    final runtime = runtimeBridgeUrl();
    if (runtime != null) return runtime;
    final current = Uri.base;
    if ((current.scheme == 'http' || current.scheme == 'https') &&
        current.hasAuthority) {
      return '${current.scheme}://${current.authority}';
    }
    return 'http://127.0.0.1:52741';
  }

  static String _normalizeBaseUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.endsWith('/')) {
      return trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  Future<Map<String, dynamic>> confirmStartup() async =>
      _postJson('/updates/healthy');

  Future<Map<String, dynamic>> probeStartup() async =>
      _getJson('/health', timeout: const Duration(milliseconds: 750));

  Future<Map<String, dynamic>> getStatus() async =>
      _getJson('/facefusion/status');

  Future<Map<String, dynamic>> getMetrics() async =>
      _getJson('/metrics/system');

  Future<Map<String, dynamic>> getLogs({required int after}) async =>
      _getJson('/logs?after=$after&limit=200');

  Future<Map<String, dynamic>> startFaceFusion() async =>
      _postJson('/facefusion/start');

  Future<Map<String, dynamic>> stopFaceFusion() async =>
      _postJson('/facefusion/stop');

  Future<Map<String, dynamic>> openBrowser() async =>
      _postJson('/facefusion/open-browser');

  Future<Map<String, dynamic>> getStudioStatus() async =>
      _getJson('/studio/status');

  Future<Map<String, dynamic>> openStudioBrowser() async =>
      _postJson('/studio/open-browser');

  Future<Map<String, dynamic>> getModelBootstrapStatus() async =>
      _getJson('/models/bootstrap');

  Future<Map<String, dynamic>> startModelBootstrap() async =>
      _postJson('/models/bootstrap/start');

  Future<Map<String, dynamic>> getUpdateStatus() async =>
      _getJson('/updates/status');

  Future<Map<String, dynamic>> checkUpdates() async =>
      _postJson('/updates/check');

  Future<Map<String, dynamic>> downloadUpdate() async =>
      _postJson('/updates/download');

  Future<Map<String, dynamic>> openUpdatePrompt({
    bool automatic = false,
  }) async => _postJson('/updates/prompt?automatic=$automatic');

  Future<Map<String, dynamic>> scheduleUpdate() async =>
      _postJson('/updates/schedule');

  Future<Map<String, dynamic>> applyUpdate() async =>
      _postJson('/updates/apply');

  Future<Map<String, dynamic>> getWorkspaceDraft() async =>
      _getJson('/workspace/draft');

  Future<Map<String, dynamic>> getWorkspaceOptionsSchema() async =>
      _getJson('/workspace/options/schema');

  Future<Map<String, dynamic>> getWorkspaceOptions() async =>
      _getJson('/workspace/options');

  Future<Map<String, dynamic>> updateWorkspaceOptions(
    Map<String, dynamic> payload,
  ) async => _putJson('/workspace/options', payload);

  Future<Map<String, dynamic>> resetWorkspaceOptions() async =>
      _deleteJson('/workspace/options');

  Future<Map<String, dynamic>> previewWorkspace(
    Map<String, dynamic> payload,
  ) async => _postJsonWithPayload(
    '/workspace/preview',
    payload,
    timeout: _previewTimeout,
  );

  Future<Map<String, dynamic>> setWorkspaceSourcePaths(
    List<String> paths,
  ) async => _putJson('/workspace/draft/source-paths', {'paths': paths});

  Future<Map<String, dynamic>> uploadWorkspaceSources(
    List<BridgeUploadFile> files,
  ) async => _multipartJson(
    '/studio/uploads/workspace-source',
    'files',
    files,
    timeout: _uploadTimeout,
  );

  Future<Map<String, dynamic>> extractWorkspaceSourceFaces(
    List<String> paths,
  ) async => _postJsonWithPayload('/workspace/draft/extract-source-faces', {
    'paths': paths,
  }, timeout: _previewTimeout);

  Future<Map<String, dynamic>> clearWorkspaceSourcePaths() async =>
      _deleteJson('/workspace/draft/source-paths');

  Future<Map<String, dynamic>> setWorkspaceTargetPath(String path) async =>
      _putJson('/workspace/draft/target-path', {'path': path});

  Future<Map<String, dynamic>> uploadWorkspaceTarget(
    BridgeUploadFile file,
  ) async => _multipartJson('/studio/uploads/workspace-target', 'file', [
    file,
  ], timeout: _uploadTimeout);

  Future<Map<String, dynamic>> clearWorkspaceTargetPath() async =>
      _deleteJson('/workspace/draft/target-path');

  Future<Map<String, dynamic>> queueWorkspace() async =>
      _postJson('/workspace/queue');

  Future<Map<String, dynamic>> runWorkspace() async =>
      _postJson('/workspace/run');

  Future<Map<String, dynamic>> getPersonas() async => _getJson('/personas');

  Future<Map<String, dynamic>> savePersona(String name) async =>
      _postJsonWithPayload('/personas', {'name': name});

  Future<Map<String, dynamic>> savePersonaFromImages(
    String name,
    List<String> paths,
  ) async => _postJsonWithPayload('/personas/from-images', {
    'name': name,
    'paths': paths,
  }, timeout: _previewTimeout);

  Future<Map<String, dynamic>> usePersona(String personaId) async =>
      _postJson('/personas/$personaId/use');

  Future<Map<String, dynamic>> deletePersona(String personaId) async =>
      _deleteJson('/personas/$personaId');

  Future<Map<String, dynamic>> openPersonaDirectory(String personaId) async =>
      _postJson('/personas/$personaId/open-directory');

  Future<Map<String, dynamic>> getQueueTasks() async =>
      _getJson('/queue/tasks');

  Future<Map<String, dynamic>> runQueue() async => _postJson('/queue/run');

  Future<Map<String, dynamic>> clearCompletedQueueTasks() async =>
      _deleteJson('/queue/tasks/completed');

  Future<Map<String, dynamic>> cancelQueueTask(String jobId) async =>
      _postJson('/queue/tasks/$jobId/cancel');

  Future<Map<String, dynamic>> deleteQueueTask(String jobId) async =>
      _deleteJson('/queue/tasks/$jobId');

  Future<Map<String, dynamic>> prepareVideoPlayback(String path) async =>
      _postJsonWithPayload('/media/playback-proxy', {
        'path': path,
      }, timeout: _previewTimeout);

  Future<Map<String, dynamic>> getSettings() async => _getJson('/settings');

  Future<Map<String, dynamic>> updateSettings(
    Map<String, dynamic> payload,
  ) async => _putJson('/settings', payload);

  Future<Map<String, dynamic>> getWorks() async => _getJson('/works');

  Future<Map<String, dynamic>> getFavorites() async =>
      _getJson('/works/favorites');

  Future<Map<String, dynamic>> favoriteWork(String workId) async =>
      _postJson('/works/$workId/favorite');

  Future<Map<String, dynamic>> unfavoriteWork(String workId) async =>
      _deleteJson('/works/$workId/favorite');

  Future<Map<String, dynamic>> deleteWork(String workId) async =>
      _deleteJson('/works/$workId');

  Future<Map<String, dynamic>> openWorkDirectory(String workId) async =>
      _postJson('/works/$workId/open-directory');

  String workDownloadUrl(String workId) =>
      '$_baseUrl/works/${Uri.encodeComponent(workId)}/download';

  String mediaUrlForPath(String path) =>
      '$_baseUrl/studio/media?path=${Uri.encodeQueryComponent(path)}';

  String resolveUrl(String value) {
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    if (value.startsWith('/')) {
      return '$_baseUrl$value';
    }
    return value;
  }

  Future<Map<String, dynamic>> _getJson(
    String path, {
    Duration timeout = _defaultTimeout,
  }) async {
    final response = await http
        .get(
          Uri.parse('$_baseUrl$path'),
          headers: {'Accept': 'application/json'},
        )
        .timeout(timeout, onTimeout: _handleTimeout);
    _ensureSuccess(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _postJson(String path) async {
    final response = await http
        .post(
          Uri.parse('$_baseUrl$path'),
          headers: {'Accept': 'application/json'},
        )
        .timeout(_defaultTimeout, onTimeout: _handleTimeout);
    _ensureSuccess(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _postJsonWithPayload(
    String path,
    Map<String, dynamic> payload, {
    Duration timeout = _defaultTimeout,
  }) async {
    final response = await http
        .post(
          Uri.parse('$_baseUrl$path'),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(payload),
        )
        .timeout(timeout, onTimeout: _handleTimeout);
    _ensureSuccess(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _putJson(
    String path,
    Map<String, dynamic> payload,
  ) async {
    final response = await http
        .put(
          Uri.parse('$_baseUrl$path'),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(payload),
        )
        .timeout(_defaultTimeout, onTimeout: _handleTimeout);
    _ensureSuccess(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _deleteJson(String path) async {
    final response = await http
        .delete(
          Uri.parse('$_baseUrl$path'),
          headers: {'Accept': 'application/json'},
        )
        .timeout(_defaultTimeout, onTimeout: _handleTimeout);
    _ensureSuccess(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _multipartJson(
    String path,
    String fieldName,
    List<BridgeUploadFile> files, {
    Duration timeout = _defaultTimeout,
  }) async {
    final request = http.MultipartRequest('POST', Uri.parse('$_baseUrl$path'));
    request.headers['Accept'] = 'application/json';
    for (final file in files) {
      request.files.add(
        http.MultipartFile.fromBytes(
          fieldName,
          file.bytes,
          filename: file.name,
        ),
      );
    }
    final streamed = await request.send().timeout(timeout);
    final response = await http.Response.fromStream(streamed).timeout(timeout);
    _ensureSuccess(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  http.Response _handleTimeout() {
    throw BridgeClientException('Bridge 请求超时，请确认 易容 Studio Bridge 正在运行。');
  }

  void _ensureSuccess(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }
    throw BridgeClientException(
      'HTTP ${response.statusCode}: ${response.body}',
    );
  }
}

class BridgeClientException implements Exception {
  BridgeClientException(this.message);

  final String message;

  @override
  String toString() => message;
}

class BridgeUploadFile {
  const BridgeUploadFile({required this.name, required this.bytes});

  final String name;
  final List<int> bytes;
}
