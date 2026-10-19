import 'package:faceswap_studio/shared/services/bridge_client.dart';
import 'package:faceswap_studio/shared/widgets/studio_update_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class UpdateClient extends BridgeClient {
  UpdateClient(this.scenario);
  final String scenario;
  final requests = <String>[];
  @override
  Future<Map<String, dynamic>> checkUpdates() async {
    requests.add('check');
    return {
      'state': scenario == 'current' || scenario == 'failed'
          ? scenario
          : 'update_available',
      'update_available': scenario != 'current' && scenario != 'failed',
      'delta_available': scenario != 'current' && scenario != 'failed',
    };
  }

  @override
  Future<Map<String, dynamic>> openUpdatePrompt({
    bool automatic = false,
  }) async {
    requests.add('prompt:$automatic');
    return {
      'native_prompt_opened': scenario != 'launch_failed' && scenario != 'skipped',
      'prompt_skipped': scenario == 'skipped',
      'error': 'native failure',
    };
  }

  @override
  Future<Map<String, dynamic>> downloadUpdate() async =>
      throw StateError('用户尚未选择，不得自动下载');
}

void main() {
  for (final scenario in [
    'available',
    'current',
    'failed',
    'launch_failed',
    'skipped',
  ]) {
    testWidgets(
      'Windows 更新流程 $scenario 直接路由独立窗口',
      (tester) async {
        late BuildContext screen;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                screen = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        final client = UpdateClient(scenario);
        final flow = startStudioUpdateFlow(
          screen,
          client: client,
          autoDownload: true,
          automatic: true,
        );
        if (scenario == 'launch_failed') {
          await expectLater(flow, throwsA(isA<BridgeClientException>()));
        } else {
          await flow;
        }
        expect(
          client.requests,
          scenario == 'current' || scenario == 'failed'
              ? ['check']
              : ['check', 'prompt:true'],
        );
        expect(find.byType(StudioUpdateDialog), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }
}
