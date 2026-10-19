import 'dart:io';
import 'dart:ui' as ui;

import 'package:faceswap_studio/app/widgets/close_behavior_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/close_behavior_preview.dart';

class _PreviewBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get disableShadows => false;
}

void main() {
  _PreviewBinding();

  setUpAll(() async {
    for (final entry in {
      'Microsoft YaHei UI': 'C:/Windows/Fonts/msyh.ttc',
      'MaterialIcons':
          'D:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            Future.value(
              ByteData.sublistView(File(entry.value).readAsBytesSync()),
            ),
          ))
          .load();
    }
  });

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byTooltip('演示点击关闭'));
    await tester.pumpAndSettle();
  }

  for (final action in StudioCloseAction.values) {
    testWidgets('选择 ${action.name} 后直接执行，恢复后不再询问', (tester) async {
      await tester.pumpWidget(const CloseBehaviorPreviewApp(autoOpen: false));
      await open(tester);
      expect(find.byType(StudioCloseDialog), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('close-action-${action.name}')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(action == StudioCloseAction.exit ? '确认关闭' : '转入后台'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(StudioCloseDialog), findsNothing);
      expect(
        find.text(action == StudioCloseAction.exit ? '已演示关闭软件' : '已演示转入后台'),
        findsOneWidget,
      );
      await tester.tap(
        find.text(action == StudioCloseAction.exit ? '重新打开演示窗口' : '从托盘恢复演示窗口'),
      );
      await tester.pumpAndSettle();
      await open(tester);
      expect(find.byType(StudioCloseDialog), findsNothing);
      expect(
        find.text(action == StudioCloseAction.exit ? '已演示关闭软件' : '已演示转入后台'),
        findsOneWidget,
      );
    });
  }

  testWidgets('开启每次询问后执行本次选择，恢复后仍询问', (tester) async {
    await tester.pumpWidget(const CloseBehaviorPreviewApp(autoOpen: false));
    await open(tester);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('转入后台'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从托盘恢复演示窗口'));
    await tester.pumpAndSettle();
    await open(tester);
    expect(find.byType(StudioCloseDialog), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
  });

  testWidgets('取消不执行动作也不记住选择，设置可改为每次询问', (tester) async {
    await tester.pumpWidget(const CloseBehaviorPreviewApp(autoOpen: false));
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('close-action-exit')));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('首次关闭时询问，确认后记住你的选择。'), findsOneWidget);
    await tester.tap(find.text('每次询问'));
    await tester.pumpAndSettle();
    await open(tester);
    expect(find.byType(StudioCloseDialog), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(StudioCloseDialog), findsNothing);
  });

  testWidgets('真实弹窗深浅主题、窄屏和文字缩放无溢出并导出截图', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    tester.view.devicePixelRatio = 1;
    final key = GlobalKey();
    for (final theme in [ThemeMode.dark, ThemeMode.light]) {
      for (final size in [
        const Size(1040, 900),
        const Size(380, 720),
        const Size(900, 760),
      ]) {
        tester.view.physicalSize = size;
        tester.platformDispatcher.textScaleFactorTestValue = size.width == 900
            ? 1.3
            : 1;
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: CloseBehaviorPreviewApp(
              key: ValueKey('$theme-$size'),
              initialThemeMode: theme,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$theme $size');
        expect(find.byType(StudioCloseDialog), findsOneWidget);
        final dialog = tester.getRect(find.byType(Dialog));
        expect(dialog.top, greaterThanOrEqualTo(0));
        expect(dialog.bottom, lessThanOrEqualTo(size.height));
        final confirm = find.text('转入后台');
        await tester.ensureVisible(confirm);
        await tester.pumpAndSettle();
        expect(confirm.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = Directory(
            '../../build/close-behavior-preview/screenshots',
          )..createSync(recursive: true);
          File(
            '${output.path}/${theme.name}-${size.width.toInt()}.png',
          ).writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    }
  });
}
