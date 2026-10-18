import 'package:faceswap_studio/features/workspace/presentation/workspace_options_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('外网模型显示来源及自动系统代理提示，提交原始模型值', (tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final schema = WorkspaceOptionsSchema.fromJson({
      'fields': {
        'frame_colorizer_model': {
          'type': 'select',
          'panel': 'common',
          'section': 'frame_colorizer',
          'section_label': '画面上色',
          'label': '模型',
          'choices': ['ddcolor', 'deoldify_stable'],
          'choice_labels': {'deoldify_stable': 'deoldify_stable · 外网下载'},
        },
      },
    });
    Map<String, dynamic>? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkspaceOptionsPanel(
            compact: false,
            busy: false,
            targetMediaType: 'image',
            targetVideoFrameTotal: null,
            schema: schema,
            state: const WorkspaceOptionsState(
              version: 1,
              targetMediaType: 'image',
              options: {'frame_colorizer_model': 'deoldify_stable'},
            ),
            onUpdateOptions: (values, {bool clearPreview = true}) async {
              submitted = values;
            },
            onResetOptions: () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('deoldify_stable · 外网下载'), findsWidgets);
    expect(find.textContaining('自动检测并使用系统代理'), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ddcolor').last);
    await tester.pumpAndSettle();
    expect(submitted, {'frame_colorizer_model': 'ddcolor'});
    expect(tester.takeException(), isNull);
  });
}
