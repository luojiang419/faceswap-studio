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
  bool video = false;
  int faceCount = 0;
  final Map<String, dynamic> options = {};
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
          // 视频控件布局独立于本机解码器；不创建真实的原生视频播放器。
          'target_path': video ? null : imagePath,
          'source_thumbnail': imagePath,
          'target_thumbnail': imagePath,
          'target_media_type': video ? 'video' : 'image',
          if (video) 'target_video_frame_total': 860,
          'can_submit': true,
        };
      case '/workspace/options':
        if (body.isNotEmpty) {
          options.addAll(jsonDecode(utf8.decode(body)) as Map<String, dynamic>);
        }
        return {'options': options};
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
          'target_media_type': video ? 'video' : 'image',
          if (video) ...{
            'frame_number': options['preview_frame_number'] ?? 500,
            'video_frame_total': 860,
          },
          'face_choices': [
            for (var i = 0; i < faceCount; i++)
              {'index': i, 'image_base64': png},
          ],
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
    // 等待按钮从禁用态切换后的颜色动画，避免把过渡中的灰字当作最终配色。
    await tester.pump(const Duration(milliseconds: 300));
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
      for (final label in ['上传人脸图片', '从形象库选择']) {
        final button = find.ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate((widget) => widget is FilledButton),
        );
        expect(button, findsOneWidget, reason: '$size 直接显示素材入口');
        expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
        expect(button.hitTestable(), findsOneWidget);
      }
      final uploadRect = tester.getRect(find.text('上传人脸图片'));
      final personaRect = tester.getRect(find.text('从形象库选择'));
      expect(uploadRect.center.dy, closeTo(personaRect.center.dy, 0.5));
      expect(uploadRect.right, lessThan(personaRect.left));
      expect(find.text('工作台'), findsNothing);
      for (final title in ['人脸参考', '待换脸视频', '原生预览']) {
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
      expect(runRect.top, greaterThanOrEqualTo(previewRect.top));
      if (previewRect.top == runRect.top) {
        expect(previewRect.left, lessThan(runRect.left));
      } else {
        expect(previewRect.bottom, lessThan(runRect.top));
      }
      expect(previewRect.bottom, lessThanOrEqualTo(size.height));
      expect(previewRect.height, greaterThanOrEqualTo(52));
      final actionsRect = tester.getRect(
        find.byKey(const ValueKey('workspace-actions-panel')),
      );
      final mediaRect = tester.getRect(
        find.byKey(const ValueKey('workspace-media-panel')),
      );
      expect(mediaRect.bottom, lessThan(actionsRect.top));
      expect(actionsRect.contains(previewRect.center), isTrue);
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
    await tester.tap(find.text('从形象库选择'));
    await tester.pumpAndSettle();
    expect(find.text('选择人物形象'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多素材操作').first);
    await tester.pumpAndSettle();
    expect(find.text('选择人物形象'), findsNothing);
    expect(find.text('保存人物形象'), findsOneWidget);
    expect(find.text('清空'), findsOneWidget);
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();
    fixture.online = false;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    for (final label in ['上传人脸图片', '从形象库选择']) {
      expect(
        tester
            .widget<FilledButton>(
              find.ancestor(
                of: find.text(label),
                matching: find.byWidgetPredicate(
                  (widget) => widget is FilledButton,
                ),
              ),
            )
            .onPressed,
        isNull,
      );
    }
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

  testWidgets('视频预览完整适配且无需纵向滚动，缩放后选帧和参考脸仍可操作', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    fixture.video = true;
    fixture.options['preview_frame_number'] = 500;

    Rect bounds(Finder finder) {
      final box = tester.renderObject<RenderBox>(finder);
      return MatrixUtils.transformRect(
        box.getTransformTo(null),
        Offset.zero & box.size,
      );
    }

    void checkFits(String state) {
      final panel = find.byKey(const ValueKey('workspace-preview-panel'));
      final panelRect = bounds(panel);
      final controls = find.byKey(const ValueKey('workspace-preview-controls'));
      final media = find.byKey(const ValueKey('workspace-preview-media'));
      for (final item in [controls, media]) {
        final rect = bounds(item);
        expect(rect.width, greaterThan(0), reason: state);
        expect(rect.height, greaterThan(0), reason: state);
        expect(
          panelRect.inflate(0.5).contains(rect.topLeft),
          isTrue,
          reason: state,
        );
        expect(
          panelRect.inflate(0.5).contains(rect.bottomRight),
          isTrue,
          reason: state,
        );
      }
      expect(bounds(media).bottom, lessThanOrEqualTo(bounds(controls).top));
      expect(
        find.descendant(of: panel, matching: find.byType(Scrollbar)),
        findsNothing,
      );
      for (final scrollable in tester.widgetList<Scrollable>(
        find.descendant(of: panel, matching: find.byType(Scrollable)),
      )) {
        expect(
          scrollable.axisDirection,
          anyOf(AxisDirection.left, AxisDirection.right),
        );
      }
      expect(tester.takeException(), isNull, reason: state);
    }

    for (final dark in [false, true]) {
      for (final size in [
        const Size(1384, 661),
        const Size(740, 850),
        const Size(676, 513),
        const Size(1000, 430),
      ]) {
        fixture.faceCount = 3;
        await show(tester, const WorkspacePage(), size, dark: dark, scale: 1.3);
        await capture(
          tester,
          'video-${dark ? 'dark' : 'light'}-${size.width.toInt()}-empty',
        );
        checkFits('$dark $size 未生成');
        expect(find.text('预览帧'), findsOneWidget);
        await tester.tap(find.text('生成预览'));
        await tester.pump(const Duration(milliseconds: 300));
        await capture(
          tester,
          'video-${dark ? 'dark' : 'light'}-${size.width.toInt()}-faces',
        );
        checkFits('$dark $size 有参考脸');
        final previousPreviews = fixture.previews;
        await tester.drag(find.byType(Slider).first, const Offset(30, 0));
        await tester.pump(const Duration(milliseconds: 300));
        expect(fixture.previews, greaterThan(previousPreviews));
        await tester.tap(find.byTooltip('人脸 #1'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(fixture.options['face_selector_mode'], 'reference');
        expect(fixture.options['reference_face_position'], 1);
        checkFits('$dark $size 切换参考脸');
        fixture.faceCount = 0;
        await tester.tap(find.text('重新生成预览'));
        await tester.pump(const Duration(milliseconds: 300));
        checkFits('$dark $size 无人脸');
        expect(find.text('当前帧未检测到人脸'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    }
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
    expect(find.text('人脸参考'), findsOneWidget);
    expect(find.text('待换脸视频'), findsOneWidget);
    expect(find.text('原生预览'), findsOneWidget);
    await capture(tester, 'shell-workspace-default');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
