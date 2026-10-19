import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../shared/services/bridge_client.dart';
import 'close_behavior_dialog.dart';

/// 将 Windows 关闭请求路由到当前主题下的 Flutter 弹窗。
class StudioWindowLifecycle extends StatefulWidget {
  const StudioWindowLifecycle({required this.child, this.client, super.key});

  final Widget child;
  final BridgeClient? client;

  @override
  State<StudioWindowLifecycle> createState() => _StudioWindowLifecycleState();
}

class _StudioWindowLifecycleState extends State<StudioWindowLifecycle> {
  static const _channel = MethodChannel('faceswap_studio/window');
  late final BridgeClient _client = widget.client ?? BridgeClient();
  late final Future<void> _initialization;
  bool _handlingClose = false;
  StudioCloseAction _lastAction = StudioCloseAction.background;
  Map<String, dynamic> _lastSettings = {
    'close_behavior': 'ask',
    'close_behavior_configured': false,
  };

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    if (_supported) {
      _channel.setMethodCallHandler(_onMethodCall);
      _initialization = _configureWindow();
    } else {
      _initialization = Future.value();
    }
  }

  String _normalize(Object? behavior) => switch (behavior) {
    'exit' => 'exit',
    'minimize_to_tray' => 'minimize_to_tray',
    _ => 'ask',
  };

  Future<void> _configureWindow() async {
    var behavior = 'ask';
    try {
      final settings = await _client.getSettings();
      _lastSettings = settings;
      behavior = _normalize(settings['close_behavior']);
    } catch (_) {}
    if (!mounted) return;
    try {
      await _channel.invokeMethod<void>('setCloseBehavior', {
        'close_behavior': behavior,
      });
    } catch (_) {}
  }

  Future<void> _onMethodCall(MethodCall call) async {
    if (call.method != 'closeRequested') throw MissingPluginException();
    if (_handlingClose || !mounted) return;
    _handlingClose = true;
    try {
      await _initialization;
      var settings = _lastSettings;
      try {
        settings = await _client.getSettings();
        _lastSettings = settings;
      } catch (_) {
        // Bridge 异常时仍允许用户看到关闭选项。
      }
      if (!mounted) return;
      final behavior = _normalize(settings['close_behavior']);
      if (behavior != 'ask') {
        await _applyAction(behavior);
        return;
      }
      final decision = await showStudioCloseDialog(
        context,
        initialAction: _lastAction,
        askEveryTime: settings['close_behavior_configured'] == true,
      );
      if (!mounted || decision == null) return;
      final action = decision.action == StudioCloseAction.exit
          ? 'exit'
          : 'minimize_to_tray';
      final preference = decision.askEveryTime ? 'ask' : action;
      // 先保存；失败时窗口保持打开，避免假称已经记住用户选择。
      try {
        _lastSettings = await _client.updateSettings({
          'close_behavior': preference,
        });
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: const Text('未能完成关闭操作：偏好未保存，可仅执行本次选择。'),
            action: SnackBarAction(
              label: action == 'exit' ? '仅本次关闭' : '仅本次转入后台',
              onPressed: () async {
                try {
                  await _applyAction(action);
                } catch (error) {
                  if (mounted) {
                    ScaffoldMessenger.maybeOf(
                      context,
                    )?.showSnackBar(SnackBar(content: Text('关闭操作失败：$error')));
                  }
                }
              },
            ),
          ),
        );
        return;
      }
      if (!mounted) return;
      _lastAction = decision.action;
      await _channel.invokeMethod<void>('setCloseBehavior', {
        'close_behavior': preference,
      });
      await _applyAction(action);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text('未能完成关闭操作，请重试：$error')));
      }
    } finally {
      _handlingClose = false;
    }
  }

  Future<void> _applyAction(String behavior) => _channel.invokeMethod<void>(
    'applyCloseAction',
    {'close_behavior': behavior},
  );

  @override
  void dispose() {
    if (_supported) _channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
