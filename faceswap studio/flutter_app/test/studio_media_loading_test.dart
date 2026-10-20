import 'dart:io';
import 'dart:ui' as ui;

import 'package:faceswap_studio/app/theme/studio_theme.dart';
import 'package:faceswap_studio/shared/widgets/studio_media_loading.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final font = FontLoader('Microsoft YaHei UI')
      ..addFont(
        Future.value(
          ByteData.sublistView(
            File('C:/Windows/Fonts/msyh.ttc').readAsBytesSync(),
          ),
        ),
      );
    await font.load();
  });

  testWidgets('加载动画适配浅深主题、窄格和文字缩放并导出预览', (tester) async {
    final key = GlobalKey();
    for (final dark in [true, false]) {
      for (final kind in StudioMediaLoadingKind.values) {
        for (final size in [const Size(300, 340), const Size(180, 160)]) {
          for (final scale in [1.0, 1.8]) {
            await tester.pumpWidget(
              MaterialApp(
                theme: dark ? StudioTheme.dark() : StudioTheme.light(),
                home: Scaffold(
                  body: Center(
                    child: RepaintBoundary(
                      key: key,
                      child: MediaQuery(
                        data: MediaQueryData(
                          textScaler: TextScaler.linear(scale),
                          disableAnimations: true,
                        ),
                        child: SizedBox(
                          width: size.width,
                          height: size.height,
                          child: ColoredBox(
                            color: dark
                                ? const Color(0xFF20201E)
                                : const Color(0xFFF3F1EE),
                            child: StudioMediaLoading(
                              kind: kind,
                              processed: 2,
                              total: 5,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: '$dark $kind $size $scale',
            );
            if (size.width == 300 && scale == 1) {
              final boundary =
                  key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              await tester.runAsync(() async {
                final image = await boundary.toImage(pixelRatio: 2);
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final folder = Directory('../../build/loading-preview')
                  ..createSync(recursive: true);
                File(
                  '${folder.path}/${kind.name}-${dark ? 'dark' : 'light'}.png',
                ).writeAsBytesSync(bytes!.buffer.asUint8List());
                image.dispose();
              });
            }
          }
        }
      }
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('单张不显示批次数字，正常动态可停止并安全销毁', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StudioMediaLoading(kind: StudioMediaLoadingKind.face),
        ),
      ),
    );
    expect(find.text('正在识别人脸'), findsOneWidget);
    expect(find.textContaining('已识别'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
