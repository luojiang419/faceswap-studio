import 'dart:convert';

import 'package:http/http.dart' as http;

class BridgeClient {
  BridgeClient({String? baseUrl}) : _baseUrl = baseUrl ?? 'http://127.0.0.1:50741';

  final String _baseUrl;

  Future<Map<String, dynamic>> getStatus() async => _getJson('/facefusion/status');

  Future<Map<String, dynamic>> getMetrics() async => _getJson('/metrics/system');

  Future<Map<String, dynamic>> getLogs({required int after}) async =>
      _getJson('/logs?after=$after&limit=200');

  Future<Map<String, dynamic>> startFaceFusion() async => _postJson('/facefusion/start');

  Future<Map<String, dynamic>> stopFaceFusion() async => _postJson('/facefusion/stop');

  Future<Map<String, dynamic>> openBrowser() async => _postJson('/facefusion/open-browser');

  Future<Map<String, dynamic>> getQueueTasks() async => _getJson('/queue/tasks');

  Future<Map<String, dynamic>> runQueue() async => _postJson('/queue/run');

  Future<Map<String, dynamic>> deleteQueueTask(String jobId) async =>
      _deleteJson('/queue/tasks/$jobId');

  Future<Map<String, dynamic>> getSettings() async => _getJson('/settings');

  Future<Map<String, dynamic>> updateSettings(Map<String, dynamic> payload) async =>
      _putJson('/settings', payload);

  Future<Map<String, dynamic>> getWorks() async => _getJson('/works');

  Future<Map<String, dynamic>> getFavorites() async => _getJson('/works/favorites');

  Future<Map<String, dynamic>> favoriteWork(String workId) async =>
      _postJson('/works/$workId/favorite');

  Future<Map<String, dynamic>> unfavoriteWork(String workId) async =>
      _deleteJson('/works/$workId/favorite');

  Future<Map<String, dynamic>> deleteWork(String workId) async =>
      _deleteJson('/works/$workId');

  Future<Map<String, dynamic>> _getJson(String path) async {
    final response = await http.get(
      Uri.parse('$_baseUrl$path'),
      headers: {'Accept': 'application/json'},
    );
    _ensureSuccess(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _postJson(String path) async {
    final response = await http.post(
      Uri.parse('$_baseUrl$path'),
      headers: {'Accept': 'application/json'},
    );
    _ensureSuccess(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _putJson(String path, Map<String, dynamic> payload) async {
    final response = await http.put(
      Uri.parse('$_baseUrl$path'),
      headers: {'Accept': 'application/json', 'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );
    _ensureSuccess(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _deleteJson(String path) async {
    final response = await http.delete(
      Uri.parse('$_baseUrl$path'),
      headers: {'Accept': 'application/json'},
    );
    _ensureSuccess(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  void _ensureSuccess(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }
    throw BridgeClientException('HTTP ${response.statusCode}: ${response.body}');
  }
}

class BridgeClientException implements Exception {
  BridgeClientException(this.message);

  final String message;

  @override
  String toString() => message;
}
