import 'dart:io';
import 'dart:ui' as ui;

import 'package:faceswap_studio/app/theme/studio_theme.dart';
import 'package:faceswap_studio/app/widgets/studio_shell.dart';
import 'package:faceswap_studio/shared/widgets/runtime_control_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('运行按钮浅深主题及启用禁用布局检查', (tester) async {
    HttpOverrides.global = null;
    tester.view.physicalSize = const Size(840, 350);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final name in ['Microsoft YaHei UI', 'Roboto', 'Ahem']) {
      final loader = FontLoader(name);
      loader.addFont(
        Future.value(
          ByteData.sublistView(
            File('C:/Windows/Fonts/msyh.ttc').readAsBytesSync(),
          ),
        ),
      );
      await loader.load();
    }
    final key = GlobalKey();
    final output = Directory('../../build/theme-preview')
      ..createSync(recursive: true);
    final iconFont = FontLoader('MaterialIcons');
    iconFont.addFont(
      Future.value(
        ByteData.sublistView(
          File(
            'D:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytesSync(),
        ),
      ),
    );
    await iconFont.load();
    Future<void> show(bool dark, bool online) async {
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: dark ? StudioTheme.dark() : StudioTheme.light(),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 640,
                  height: 260,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: RuntimeControlPanel(
                        bridgeOnline: online,
                        busy: false,
                        serviceLabel: online ? '就绪' : '离线',
                        serviceMessage: online ? '服务已连接，准备开始创作。' : 'Bridge 未连接',
                        webuiUrl: 'http://127.0.0.1:7860',
                        facefusionPid: null,
                        onStart: () {},
                        onStop: () {},
                        onOpenBrowser: () {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    Future<void> settle() async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 700)),
      );
      await tester.pump(const Duration(milliseconds: 250));
      if (find.text('稍后').evaluate().isNotEmpty) {
        await tester.tap(find.text('稍后'));
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    Future<void> capture(String name) async {
      await settle();
      final error = tester.takeException();
      expect(error, isNull, reason: name);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final frame = await boundary.toImage();
        final bytes = await frame.toByteData(format: ui.ImageByteFormat.png);
        File(
          '${output.path}/$name.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
        frame.dispose();
      });
    }

    for (final dark in [false, true]) {
      for (final online in [false, true]) {
        await show(dark, online);
        await capture(
          '${dark ? 'dark' : 'light'}-buttons-${online ? 'enabled' : 'disabled'}',
        );
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
  testWidgets('六个页面的浅深主题布局与图标预览', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var mode = ThemeMode.light;
    var expanded = false;
    final key = GlobalKey();
    final output = Directory('../../build/theme-preview')
      ..createSync(recursive: true);
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: StudioTheme.light(),
            darkTheme: StudioTheme.dark(),
            themeMode: mode,
            home: StudioShell(
              themeMode: mode,
              onToggleTheme: () => setState(
                () => mode = mode == ThemeMode.light
                    ? ThemeMode.dark
                    : ThemeMode.light,
              ),
              sidebarExpanded: expanded,
              onSidebarExpandedChanged: (value) =>
                  setState(() => expanded = value),
            ),
          ),
        ),
      ),
    );
    for (final theme in ['light', 'dark']) {
      if (theme == 'dark') {
        await tester.tap(find.byTooltip('深色主题'));
        await tester.pump(const Duration(milliseconds: 300));
      }
      for (final page in ['首页', '工作台', '人物形象', '作品管理', '设置', '关于']) {
        await tester.tap(find.text(page).first);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '$theme-$page');
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final frame = await boundary.toImage();
          final bytes = await frame.toByteData(format: ui.ImageByteFormat.png);
          File(
            '${output.path}/$theme-$page.png',
          ).writeAsBytesSync(bytes!.buffer.asUint8List());
          frame.dispose();
        });
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 40));
    await tester.pump();
  });
}
