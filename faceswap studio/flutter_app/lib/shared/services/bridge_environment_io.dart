import 'dart:io';

String? runtimeBridgeUrl() {
  final port = Platform.environment['FACESWAP_STUDIO_BRIDGE_PORT'];
  return port == null ? null : 'http://127.0.0.1:$port';
}
