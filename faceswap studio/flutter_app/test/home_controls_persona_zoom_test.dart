import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:faceswap_studio/app/theme/studio_theme.dart';
import 'package:faceswap_studio/features/home/presentation/home_page.dart';
import 'package:faceswap_studio/features/personas/presentation/personas_page.dart';
import 'package:faceswap_studio/features/workspace/presentation/workspace_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// 所有请求在内存中响应，不连接用户服务、不修改真实配置。
class _Fixture extends HttpOverrides {
  double scale = 100;
  bool online = true;
  bool failSave = false;
  int refreshes = 0;
  int browsers = 0;
  Completer<void>? readGate;
  Completer<void>? writeGate;
  final writes = <double>[];

  Future<Object> respond(String method, Uri uri, List<int> body) async {
    switch (uri.path) {
      case '/settings':
        if (method == 'PUT') {
          final value =
              (jsonDecode(utf8.decode(body))['persona_grid_scale'] as num)
                  .toDouble();
          writes.add(value);
          await writeGate?.future;
          if (failSave) throw const SocketException('测试保存失败');
          scale = value;
        } else {
          final value = scale;
          await readGate?.future;
          return {'persona_grid_scale': value, 'auto_check_updates': false};
        }
        return {'persona_grid_scale': scale, 'auto_check_updates': false};
      case '/personas':
        return {
          'root': '测试人物库',
          'items': List.generate(
            12,
            (i) => {
              'id': '$i',
              'name': '人物 ${i + 1}',
              'face_count': 12,
              'updated_at': '2026-10-19',
            },
          ),
        };
      case '/facefusion/status':
        refreshes++;
        if (!online) throw const SocketException('测试离线');
        return {'state': 'ready', 'pid': 1234};
      case '/facefusion/open-browser':
        browsers++;
        return {'ok': true};
      case '/models/bootstrap':
        return {'ready': true};
      default:
        return <String, dynamic>{};
    }
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) => _Client(this);
}

class _Client extends Fake implements HttpClient {
  _Client(this.fixture);
  final _Fixture fixture;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _Request(fixture, method, url);
  @override
  void close({bool force = false}) {}
}

class _Headers extends Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  void forEach(void Function(String name, List<String> values) action) =>
      action('content-type', ['application/json']);
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this.fixture, this.requestMethod, this.url);
  final _Fixture fixture;
  final String requestMethod;
  final Uri url;
  final body = <int>[];
  @override
  final HttpHeaders headers = _Headers();
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  int contentLength = -1;
  @override
  bool persistentConnection = true;
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final bytes in stream) {
      body.addAll(bytes);
    }
  }

  @override
  Future<HttpClientResponse> close() async =>
      _Response(jsonEncode(await fixture.respond(requestMethod, url, body)));
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.body);
  final String body;
  @override
  int get statusCode => 200;
  @override
  String get reasonPhrase => 'OK';
  @override
  bool get isRedirect => false;
  @override
  bool get persistentConnection => false;
  @override
  int get contentLength => utf8.encode(body).length;
  @override
  final HttpHeaders headers = _Headers();
  @override
  List<RedirectInfo> get redirects => [];
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(utf8.encode(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Fixture fixture;
  final boundaryKey = GlobalKey();
  const zoomTooltip = '调节人物格子尺寸（Ctrl＋滚轮）';
  final slider = find.byKey(const ValueKey('persona-grid-scale-slider'));
  final grid = find.byKey(const ValueKey('persona-grid'));

  setUp(() async {
    fixture = _Fixture();
    HttpOverrides.global = fixture;
    for (final entry in {
      'Microsoft YaHei UI': 'C:/Windows/Fonts/msyh.ttc',
      'MaterialIcons':
          'D:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      if (File(entry.value).existsSync()) {
        await (FontLoader(entry.key)..addFont(
              Future.value(
                ByteData.sublistView(File(entry.value).readAsBytesSync()),
              ),
            ))
            .load();
      }
    }
  });
  tearDown(() {
    HttpOverrides.global = null;
  });

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> show(
    WidgetTester tester,
    Widget page, {
    Size size = const Size(1100, 700),
    bool dark = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: dark ? StudioTheme.dark() : StudioTheme.light(),
          home: Scaffold(
            body: Padding(padding: const EdgeInsets.all(24), child: page),
          ),
        ),
      ),
    );
    await flush(tester);
  }

  Future<void> capture(WidgetTester tester, String name) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump();
    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final output = Directory('../../build/persona-zoom-preview')
        ..createSync(recursive: true);
      File(
        '${output.path}/$name.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> wheel(
    WidgetTester tester, {
    bool ctrl = true,
    double delta = -120,
  }) async {
    if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getTopLeft(grid) + const Offset(100, 100),
        scrollDelta: Offset(0, delta),
      ),
    );
    if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  testWidgets('首页顶部承接操作入口且在线离线均无 Bridge 状态框', (tester) async {
    await show(tester, const HomePage());
    expect(
      find.textContaining(RegExp(r'^(Bridge|FaceFusion) (在线|离线)$')),
      findsNothing,
    );
    expect(find.text('Bridge'), findsNothing);
    expect(find.text('浏览器打开'), findsOneWidget);
    final reload = find
        .ancestor(
          of: find.text('重新加载'),
          matching: find.byWidgetPredicate((w) => w is FilledButton),
        )
        .first;
    expect(tester.getRect(reload).bottom, lessThan(110));
    final before = fixture.refreshes;
    await tester.tap(reload);
    await tester.pump();
    expect(fixture.refreshes, greaterThan(before));
    await capture(tester, 'home-controls-light');
    await tester.tap(find.text('浏览器打开'));
    await flush(tester);
    expect(fixture.browsers, 1);
    fixture.online = false;
    await tester.pump(const Duration(seconds: 2));
    await flush(tester);
    expect(tester.widget<FilledButton>(reload).onPressed, isNull);
    expect(find.text('Bridge 离线'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await show(tester, const WorkspacePage());
    expect(find.text('重新加载'), findsNothing);
    expect(find.text('FaceFusion 在线'), findsNothing);
    expect(find.text('Bridge 在线'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('悬停和固定滑块、10%与800%真实尺寸、重置及普通滚轮', (tester) async {
    await show(tester, const PersonasPage());
    expect(slider, findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    await mouse.moveTo(tester.getCenter(find.byTooltip(zoomTooltip)));
    await tester.pump();
    expect(slider, findsOneWidget);
    await mouse.moveTo(const Offset(1, 1));
    await tester.pump();
    expect(slider, findsNothing);
    await tester.tap(find.byTooltip(zoomTooltip));
    await tester.pump();
    expect(tester.widget<Slider>(slider).value, 100);
    expect(tester.getSize(find.byType(FittedBox).first), const Size(344, 400));
    await capture(tester, 'personas-100-light');
    tester.widget<Slider>(slider).onChanged!(10);
    await flush(tester);
    expect(
      tester.getSize(find.byType(FittedBox).first).width,
      closeTo(34.4, .01),
    );
    expect(tester.takeException(), isNull);
    await wheel(tester, delta: 120);
    expect(tester.widget<Slider>(slider).value, 10);
    await capture(tester, 'personas-10-light');
    tester.widget<Slider>(slider).onChanged!(800);
    await flush(tester);
    expect(
      tester.getSize(find.byType(FittedBox).first),
      const Size(2752, 3200),
    );
    await wheel(tester);
    expect(tester.widget<Slider>(slider).value, 800);
    final horizontal = find.byWidgetPredicate(
      (w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
    );
    final horizontalController = tester
        .widget<SingleChildScrollView>(horizontal)
        .controller!;
    expect(horizontalController.position.maxScrollExtent, greaterThan(0));
    horizontalController.jumpTo(500);
    await tester.pump();
    expect(horizontalController.offset, 500);
    expect(tester.takeException(), isNull);
    await capture(tester, 'personas-800-light');
    await tester.tap(find.byTooltip('恢复 100%'));
    await flush(tester);
    expect(tester.widget<Slider>(slider).value, 100);
    final controller = tester.widget<GridView>(grid).controller!;
    final offset = controller.offset;
    await wheel(tester, delta: 120);
    expect(tester.widget<Slider>(slider).value, 90);
    expect(controller.offset, offset);
    await wheel(tester, ctrl: false, delta: 120);
    expect(tester.widget<Slider>(slider).value, 90);
    expect(controller.offset, greaterThan(offset));
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
    await mouse.removePointer();
  });

  testWidgets('离页立即保存、连续写入顺序及返回恢复', (tester) async {
    await show(tester, const PersonasPage());
    await wheel(tester);
    await wheel(tester);
    await wheel(tester);
    fixture.writeGate = Completer<void>();
    addTearDown(() {
      if (!fixture.writeGate!.isCompleted) fixture.writeGate!.complete();
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await flush(tester);
    expect(fixture.writes, [130]);
    await show(tester, const PersonasPage());
    await wheel(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(fixture.writes, [130]);
    fixture.writeGate!.complete();
    await flush(tester);
    expect(fixture.writes, [130, 110]);
    expect(fixture.scale, 110);
    await tester.pumpWidget(const SizedBox.shrink());
    await show(tester, const PersonasPage());
    await tester.tap(find.byTooltip(zoomTooltip));
    await tester.pump();
    expect(tester.widget<Slider>(slider).value, 110);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('迟到的初始配置不覆盖手动缩放，保存失败明确提示', (tester) async {
    fixture.scale = 300;
    fixture.readGate = Completer<void>();
    await show(tester, const PersonasPage());
    await wheel(tester);
    fixture.readGate!.complete();
    await tester.pump();
    await tester.tap(find.byTooltip(zoomTooltip));
    await tester.pump();
    expect(tester.widget<Slider>(slider).value, 110);
    fixture.failSave = true;
    await flush(tester);
    expect(find.textContaining('保存人物尺寸设置失败'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('浅深主题、窄窗口与极端倍率均无布局异常', (tester) async {
    for (final dark in [false, true]) {
      for (final scale in [10.0, 100.0, 800.0]) {
        fixture.scale = scale;
        await show(
          tester,
          const PersonasPage(),
          size: const Size(480, 540),
          dark: dark,
        );
        await tester.tap(find.byTooltip(zoomTooltip));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '$dark $scale');
        expect(tester.getRect(slider).left, greaterThanOrEqualTo(0));
        expect(tester.getRect(find.text('添加人物')).bottom, lessThan(540));
        await capture(tester, 'personas-narrow-$dark-${scale.toInt()}');
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });
}
