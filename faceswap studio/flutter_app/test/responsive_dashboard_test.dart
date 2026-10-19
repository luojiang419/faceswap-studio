import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:faceswap_studio/app/theme/studio_theme.dart';
import 'package:faceswap_studio/app/widgets/studio_shell.dart';
import 'package:faceswap_studio/features/home/presentation/home_page.dart';
import 'package:faceswap_studio/features/workspace/presentation/workspace_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// 所有请求在内存中响应，避免布局测试连接用户的 Bridge 或修改真实素材。
class _Fixture extends HttpOverrides {
  bool online = true;
  int previews = 0;
  Completer<void>? previewGate;
  Map<String, dynamic>? previewPayload;
  late String imagePath;
  late String png;

  Object response(Uri uri, List<int> body) {
    switch (uri.path) {
      case '/facefusion/status':
        if (!online) throw const SocketException('测试离线状态');
        return {
          'state': 'ready',
          'pid': 12345,
          'webui_url': 'http://127.0.0.1:7860',
        };
      case '/workspace/draft':
        return {
          'source_paths': [imagePath],
          'target_path': imagePath,
          'source_thumbnail': imagePath,
          'target_thumbnail': imagePath,
          'target_media_type': 'image',
          'can_submit': true,
        };
      case '/workspace/preview':
        previews++;
        previewPayload = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
        return {
          'ok': true,
          'image_base64': png,
          'before_image_base64': png,
          'after_image_base64': png,
          'width': 120,
          'height': 180,
          'target_media_type': 'image',
          'face_choices': [],
        };
      case '/models/bootstrap':
        return {'ready': true};
      case '/settings':
        return {'auto_check_updates': false};
      case '/logs':
        return {
          'latest_id': 1,
          'entries': [
            {
              'id': 1,
              'timestamp': '10:00:00',
              'message': 'FaceFusion WebUI is ready.',
            },
          ],
        };
      case '/metrics/system':
        return {
          'cpu_percent': 24,
          'memory_percent': 42,
          'memory_used_gb': 32,
          'memory_total_gb': 64,
          'gpu_percent': 78,
          'gpu_memory_percent': 50,
        };
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
      _Request(fixture, url);
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
  _Request(this.fixture, this.url);
  final _Fixture fixture;
  final Uri url;
  final List<int> body = [];
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
  Future<HttpClientResponse> close() async {
    if (url.path == '/workspace/preview') await fixture.previewGate?.future;
    return _Response(jsonEncode(fixture.response(url, body)));
  }
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

class _StudioVisualBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get disableShadows => false;
}

void main() {
  _StudioVisualBinding();
  final sizes = [
    const Size(1100, 613),
    const Size(1366, 768),
    const Size(1636, 1032),
    const Size(2276, 1392),
    const Size(740, 552),
    const Size(676, 513),
    const Size(740, 850),
    const Size(1000, 430),
  ];
  late _Fixture fixture;
  late Directory temp;
  final boundaryKey = GlobalKey();

  setUp(() async {
    fixture = _Fixture();
    temp = Directory.systemTemp.createTempSync('studio-layout-');
    fixture.imagePath = '${temp.path}/portrait.png';
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 120, 180),
      Paint()..color = const Color(0xFFB5C5A0),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(120, 180);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final data = bytes!.buffer.asUint8List();
    File(fixture.imagePath).writeAsBytesSync(data);
    fixture.png = base64Encode(data);
    PaintingBinding.instance.imageCache.putIfAbsent(
      FileImage(File(fixture.imagePath)),
      () => OneFrameImageStreamCompleter(
        Future.value(ImageInfo(image: image.clone())),
      ),
    );
    image.dispose();
    picture.dispose();
    HttpOverrides.global = fixture;
    final font = FontLoader('Microsoft YaHei UI')
      ..addFont(
        Future.value(
          ByteData.sublistView(
            File('C:/Windows/Fonts/msyh.ttc').readAsBytesSync(),
          ),
        ),
      );
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        Future.value(
          ByteData.sublistView(
            File(
              'D:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ).readAsBytesSync(),
          ),
        ),
      );
    await icons.load();
  });
  tearDown(() {
    HttpOverrides.global = null;
    temp.deleteSync(recursive: true);
  });

  Future<void> show(
    WidgetTester tester,
    Widget page,
    Size size, {
    bool dark = true,
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: dark ? StudioTheme.dark() : StudioTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(body: page),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> capture(WidgetTester tester, String name) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump();
    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final output = Directory('../../build/layout-preview')
        ..createSync(recursive: true);
      File(
        '${output.path}/$name.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('三格在多尺寸和字体缩放下可见，底部预览保持原调用与按钮顺序', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final size in sizes) {
      await show(tester, const WorkspacePage(), size);
      expect(tester.takeException(), isNull, reason: '$size 初始布局');
      expect(find.text('工作台'), findsNothing);
      for (final title in ['SOURCE', 'TARGET', '原生预览']) {
        final rect = tester.getRect(find.text(title));
        expect(
          (Offset.zero & size).contains(rect.topLeft),
          isTrue,
          reason: '$size $title',
        );
      }
      final preview = find
          .ancestor(
            of: find.text('生成预览'),
            matching: find.byWidgetPredicate((w) => w is FilledButton),
          )
          .first;
      expect(tester.widget<FilledButton>(preview).onPressed, isNotNull);
      final previewRect = tester.getRect(preview);
      final runRect = tester.getRect(
        find
            .ancestor(
              of: find.text('立即生成'),
              matching: find.byWidgetPredicate(
                (widget) => widget is ButtonStyleButton,
              ),
            )
            .first,
      );
      expect(previewRect.left, lessThan(runRect.left));
      expect(previewRect.top, runRect.top);
      expect(previewRect.bottom, lessThanOrEqualTo(size.height));
      for (final element
          in find
              .byWidgetPredicate(
                (widget) => widget is Image && widget.image is FileImage,
              )
              .evaluate()) {
        final image = element.renderObject! as RenderBox;
        final rect = image.localToGlobal(Offset.zero) & image.size;
        expect(rect.height, greaterThan(40), reason: '$size 素材预览高度');
        expect(rect.width, greaterThan(40), reason: '$size 素材预览宽度');
        expect(
          rect.bottom,
          lessThan(previewRect.top),
          reason: '$size 素材保持在操作栏上方',
        );
      }
      fixture.previewGate = Completer<void>();
      await tester.tap(preview);
      await tester.pump();
      expect(find.text('正在预览'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find
                  .ancestor(
                    of: find.text('正在预览'),
                    matching: find.byWidgetPredicate((w) => w is FilledButton),
                  )
                  .first,
            )
            .onPressed,
        isNull,
      );
      fixture.previewGate!.complete();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('重新生成预览'), findsOneWidget);
      expect(fixture.previewPayload!['source_paths'], [fixture.imagePath]);
      expect(fixture.previewPayload!['target_path'], fixture.imagePath);
      expect(tester.takeException(), isNull, reason: '$size 预览后布局');
      await capture(
        tester,
        'workspace-${size.width.toInt()}x${size.height.toInt()}',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
    await show(
      tester,
      const WorkspacePage(),
      const Size(1100, 613),
      dark: false,
      scale: 1.3,
    );
    expect(tester.takeException(), isNull, reason: '130% 字体');
    await capture(tester, 'workspace-light-130percent');
    await tester.tap(find.byTooltip('更多素材操作').first);
    await tester.pumpAndSettle();
    expect(find.text('选择人物形象'), findsOneWidget);
    expect(find.text('保存人物形象'), findsOneWidget);
    expect(find.text('清空'), findsOneWidget);
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();
    fixture.online = false;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find
                .ancestor(
                  of: find.text('生成预览'),
                  matching: find.byWidgetPredicate((w) => w is FilledButton),
                )
                .first,
          )
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('首页使用全宽模块并适配浅深主题与矮窗口', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final dark in [true, false]) {
      for (final size in sizes) {
        await show(tester, const HomePage(), size, dark: dark);
        expect(tester.takeException(), isNull, reason: '$size $dark 首页布局');
        expect(find.byType(FittedBox), findsNothing);
        expect(find.text('系统资源监控'), findsOneWidget);
        expect(find.text('运行日志'), findsOneWidget);
        await capture(
          tester,
          'home-${dark ? 'dark' : 'light'}-${size.width.toInt()}x${size.height.toInt()}',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    }
  });

  testWidgets('默认窗口展开导航后首页与工作台完整显示', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await show(
      tester,
      StudioShell(
        themeMode: ThemeMode.dark,
        onToggleTheme: () {},
        sidebarExpanded: true,
        onSidebarExpandedChanged: (_) {},
      ),
      const Size(1384, 661),
    );
    expect(tester.takeException(), isNull);
    await capture(tester, 'shell-home-default');
    await tester.tap(find.text('工作台'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.text('工作台'), findsOneWidget);
    expect(find.text('SOURCE'), findsOneWidget);
    expect(find.text('TARGET'), findsOneWidget);
    expect(find.text('原生预览'), findsOneWidget);
    await capture(tester, 'shell-workspace-default');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
