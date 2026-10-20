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
  bool previewFailed = false;
  bool invalidPreviewImage = false;
  Map<String, dynamic>? previewPayload;
  bool video = false;
  Completer<void>? sourceGate;
  Completer<void>? targetGate;
  int sourceProcessed = 0;
  bool sourceFailed = false;
  bool targetFailed = false;
  bool parallelImports = false;
  Completer<void>? draftGate;
  String? committedSource;
  String? committedTarget;
  late String importedFacePath;
  late String importedTargetPath;
  int sourceRequests = 0;
  int targetRequests = 0;
  int faceCount = 0;
  final Map<String, dynamic> options = {};
  late String imagePath;
  late String png;

  Object response(Uri uri, List<int> body) {
    switch (uri.path) {
      case '/workspace/draft/source-progress':
        return {
          'request_id': uri.queryParameters['request_id'],
          'processed': sourceProcessed,
          'total': 3,
          'recognized': sourceProcessed,
          'skipped': 0,
        };
      case '/workspace/draft/extract-source-faces':
        if (parallelImports && !sourceFailed) {
          committedSource = importedFacePath;
        }
        return {
          'ok': !sourceFailed,
          'message': sourceFailed ? '未检测到可用人脸' : '已提取源脸',
          'workspace': {
            'source_paths': [
              parallelImports ? committedSource ?? imagePath : imagePath,
            ],
            'source_thumbnail': parallelImports
                ? committedSource ?? imagePath
                : imagePath,
            // 故意返回另一侧的旧快照，验证前端只合并本次导入的区域。
            if (parallelImports) 'target_path': imagePath,
            if (parallelImports) 'target_thumbnail': imagePath,
            if (parallelImports) 'target_media_type': 'image',
          },
        };
      case '/workspace/draft/target-path':
        if (targetFailed) throw const SocketException('测试视频读取失败');
        if (parallelImports) committedTarget = importedTargetPath;
        return {
          'source_paths': [imagePath],
          'target_path': parallelImports ? committedTarget : imagePath,
          'target_media_type': 'image',
          'source_thumbnail': imagePath,
          'target_thumbnail': parallelImports ? committedTarget : imagePath,
        };
      case '/facefusion/status':
        if (!online) throw const SocketException('测试离线状态');
        return {
          'state': 'ready',
          'pid': 12345,
          'webui_url': 'http://127.0.0.1:7860',
        };
      case '/workspace/draft':
        if (parallelImports) {
          return {
            'source_paths': [committedSource ?? imagePath],
            'source_thumbnail': committedSource ?? imagePath,
            'target_path': committedTarget ?? imagePath,
            'target_thumbnail': committedTarget ?? imagePath,
            'target_media_type': 'image',
            'can_submit': true,
          };
        }
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
      case '/workspace/options/schema':
        return {
          'fields': {
            'face_selector_mode': {
              'type': 'select',
              'panel': 'advanced',
              'section': 'face_selector',
              'section_label': '人脸选择',
              'label': '选择模式',
              'choices': ['many', 'one', 'reference'],
            },
          },
        };
      case '/workspace/preview':
        previews++;
        previewPayload = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
        if (previewFailed) return {'ok': false, 'message': '测试预览失败'};
        return {
          'ok': true,
          'image_base64': invalidPreviewImage ? base64Encode([0, 1, 2]) : png,
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
    if (url.path == '/workspace/draft' && fixture.draftGate != null) {
      final snapshot = jsonEncode(fixture.response(url, body));
      await fixture.draftGate!.future;
      return _Response(snapshot);
    }
    if (url.path == '/workspace/preview') await fixture.previewGate?.future;
    if (url.path == '/workspace/draft/extract-source-faces') {
      fixture.sourceRequests++;
      await fixture.sourceGate?.future;
    }
    if (url.path == '/workspace/draft/target-path') {
      fixture.targetRequests++;
      await fixture.targetGate?.future;
    }
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
  Completer<void>? decodeGate;
  int pendingDecodes = 0;

  @override
  Future<ui.Codec> instantiateImageCodecWithSize(
    ui.ImmutableBuffer buffer, {
    ui.TargetImageSizeCallback? getTargetSize,
  }) async {
    final gate = decodeGate;
    if (gate != null) {
      pendingDecodes++;
      try {
        await gate.future;
      } finally {
        pendingDecodes--;
      }
    }
    return super.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: getTargetSize,
    );
  }

  @override
  bool get disableShadows => false;
}

void main() {
  final binding = _StudioVisualBinding();
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

  Future<void> finishPreview(WidgetTester tester) async {
    // 图片解码在引擎执行，让真实异步解码完成后再检查结果。
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pump();
  }

  testWidgets('预览从点击到对照图片解码始终显示粒子，失败可重试', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => binding.decodeGate = null);
    fixture.previewGate = Completer<void>();
    await show(tester, const WorkspacePage(), const Size(1384, 661));
    binding.decodeGate = Completer<void>();
    final loading = find.byKey(const ValueKey('workspace-preview-loading'));
    await tester.tap(find.text('生成预览'));
    await tester.pump();
    expect(loading, findsOneWidget);
    expect(find.text('正在生成预览'), findsOneWidget);
    expect(find.text('正在检测与裁切，请稍候'), findsNothing);
    await capture(tester, 'workspace-preview-particles');
    fixture.previewGate!.complete();
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(fixture.previews, 1);
    expect(binding.pendingDecodes, 3, reason: '等待单图、原图与换脸结果的真实解码');
    expect(loading, findsOneWidget);
    expect(find.text('正在预览'), findsOneWidget);
    binding.decodeGate!.complete();
    binding.decodeGate = null;
    await finishPreview(tester);
    expect(loading, findsNothing);
    expect(find.text('重新生成预览'), findsOneWidget);
    expect(find.text('已生成'), findsOneWidget);

    fixture.previewFailed = true;
    await tester.tap(find.text('重新生成预览'));
    await tester.pump();
    expect(loading, findsOneWidget);
    await finishPreview(tester);
    expect(loading, findsNothing);
    expect(find.text('测试预览失败'), findsOneWidget);
    fixture.previewFailed = false;
    fixture.invalidPreviewImage = true;
    await tester.tap(find.text('生成预览'));
    await tester.pump();
    await finishPreview(tester);
    expect(loading, findsNothing);
    expect(find.textContaining('预览图片无法解码'), findsOneWidget);
    fixture.invalidPreviewImage = false;
    await tester.tap(find.text('生成预览'));
    await tester.pump();
    await finishPreview(tester);
    expect(loading, findsNothing);
    expect(find.text('已生成'), findsOneWidget);
    fixture.previewGate = Completer<void>();
    await tester.tap(find.text('重新生成预览'));
    await tester.pump();
    expect(loading, findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    fixture.previewGate!.complete();
    await finishPreview(tester);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    '文件窗口返回前已绘制粒子，识别完成后持续到图片首帧',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const picker = MethodChannel('faceswap_studio/file_dialog');
      final picked = Completer<List<String>>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        picker,
        (_) => picked.future,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          picker,
          null,
        ),
      );
      fixture.sourceGate = Completer<void>();
      await show(tester, const WorkspacePage(), const Size(1384, 661));
      await tester.tap(find.text('上传人脸图片'));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('source-import-loading')),
        findsOneWidget,
      );
      expect(fixture.sourceRequests, 0, reason: '选择窗口未返回，格子下方已显示粒子');
      picked.complete([r'D:\素材\face.jpg']);
      await tester.pump();
      await tester.pump();
      expect(fixture.sourceRequests, 1);
      expect(find.text('正在识别人脸'), findsOneWidget);
      final previousPath = fixture.imagePath;
      final nextPath = '${temp.path}/new-face.png';
      File(nextPath).writeAsBytesSync(File(previousPath).readAsBytesSync());
      final decoded = await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(
          File(nextPath).readAsBytesSync(),
        );
        final frame = await codec.getNextFrame();
        codec.dispose();
        return frame.image;
      });
      final firstFrame = Completer<ImageInfo>();
      final imageProvider = FileImage(File(nextPath));
      PaintingBinding.instance.imageCache.putIfAbsent(
        imageProvider,
        () => OneFrameImageStreamCompleter(firstFrame.future),
      );
      addTearDown(() {
        if (!firstFrame.isCompleted) {
          firstFrame.complete(ImageInfo(image: decoded!));
        }
        PaintingBinding.instance.imageCache.evict(imageProvider);
      });
      fixture.imagePath = nextPath;
      fixture.sourceGate!.complete();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('正在处理新素材…'), findsNothing, reason: '提取请求已经结束');
      expect(
        find.byKey(const ValueKey('source-import-loading')),
        findsOneWidget,
        reason: '图片尚未解码出首帧，粒子必须继续显示',
      );
      await tester.pump(const Duration(seconds: 2));
      expect(
        find.byKey(const ValueKey('source-import-loading')),
        findsOneWidget,
      );
      firstFrame.complete(ImageInfo(image: decoded!));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('source-import-loading')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  for (final scenario in ['视频先完成', '人脸先完成', '人脸失败', '视频失败']) {
    final targetFirst = scenario != '人脸先完成';
    testWidgets(
      '人脸和视频同时导入，$scenario 且旧刷新不能覆盖',
      (tester) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        const picker = MethodChannel('faceswap_studio/file_dialog');
        fixture.parallelImports = true;
        fixture.sourceFailed = scenario == '人脸失败';
        fixture.targetFailed = scenario == '视频失败';
        fixture.importedFacePath = '${temp.path}/recognized-face.png';
        fixture.importedTargetPath = '${temp.path}/new-target.png';
        for (final path in [
          fixture.importedFacePath,
          fixture.importedTargetPath,
        ]) {
          File(fixture.imagePath).copySync(path);
          final decoded = await tester.runAsync(() async {
            final codec = await ui.instantiateImageCodec(
              File(path).readAsBytesSync(),
            );
            final frame = await codec.getNextFrame();
            codec.dispose();
            return frame.image;
          });
          PaintingBinding.instance.imageCache.putIfAbsent(
            FileImage(File(path)),
            () => OneFrameImageStreamCompleter(
              Future.value(ImageInfo(image: decoded!)),
            ),
          );
        }
        fixture.sourceGate = Completer<void>();
        fixture.targetGate = Completer<void>();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          picker,
          (call) async => (call.arguments as Map)['multiple'] == true
              ? [r'D:\素材\face.jpg']
              : [r'D:\素材\video.mp4'],
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            picker,
            null,
          ),
        );
        await show(tester, const WorkspacePage(), const Size(1384, 661));
        final sourceLoading = find.byKey(
          const ValueKey('source-import-loading'),
        );
        final targetLoading = find.byKey(
          const ValueKey('target-import-loading'),
        );
        FilledButton button(String label) => tester.widget<FilledButton>(
          find
              .ancestor(
                of: find.text(label),
                matching: find.byWidgetPredicate(
                  (widget) => widget is FilledButton,
                ),
              )
              .first,
        );
        Future<void> pick(String label) async {
          await tester.tap(find.text(label));
          await tester.pump();
          await tester.pump();
        }

        if (targetFirst) {
          await pick('上传人脸图片');
          expect(button('更换视频').onPressed, isNotNull, reason: '人脸识别不阻塞视频入口');
          if (scenario == '视频先完成') {
            await capture(tester, 'parallel-face-loading-video-enabled');
          }
          await pick('更换视频');
        } else {
          await pick('更换视频');
          expect(button('上传人脸图片').onPressed, isNotNull, reason: '视频读取也不阻塞人脸入口');
          await pick('上传人脸图片');
        }
        expect(fixture.sourceRequests, 1);
        expect(fixture.targetRequests, 1);
        expect(sourceLoading, findsOneWidget);
        expect(targetLoading, findsOneWidget);
        expect(button('上传人脸图片').onPressed, isNull);
        expect(button('更换视频').onPressed, isNull);
        expect(button('生成预览').onPressed, isNull);
        // 保留一份导入尚未完成时的定时刷新快照，故意延迟到两边完成后交付。
        fixture.draftGate = Completer<void>();
        await tester.pump(const Duration(seconds: 2));
        if (targetFirst) {
          fixture.targetGate!.complete();
        } else {
          fixture.sourceGate!.complete();
        }
        await finishPreview(tester);
        expect(button(targetFirst ? '更换视频' : '上传人脸图片').onPressed, isNotNull);
        expect(button(targetFirst ? '上传人脸图片' : '更换视频').onPressed, isNull);
        expect(targetFirst ? sourceLoading : targetLoading, findsOneWidget);
        expect(button('生成预览').onPressed, isNull, reason: '另一份素材仍未完成');
        if (targetFirst) {
          fixture.sourceGate!.complete();
        } else {
          fixture.targetGate!.complete();
        }
        await finishPreview(tester);
        expect(button('生成预览').onPressed, isNotNull);
        expect(
          find.text(
            fixture.sourceFailed ? 'portrait.png' : 'recognized-face.png',
          ),
          findsOneWidget,
        );
        expect(
          find.text(fixture.targetFailed ? 'portrait.png' : 'new-target.png'),
          findsOneWidget,
        );
        fixture.draftGate!.complete();
        await tester.pump();
        await tester.pump();
        expect(
          find.text(
            fixture.sourceFailed ? 'portrait.png' : 'recognized-face.png',
          ),
          findsOneWidget,
          reason: '旧刷新不能回退源脸',
        );
        expect(
          find.text(fixture.targetFailed ? 'portrait.png' : 'new-target.png'),
          findsOneWidget,
          reason: '旧刷新不能回退目标',
        );
        expect(sourceLoading, findsNothing);
        expect(targetLoading, findsNothing);
        await capture(
          tester,
          'parallel-import-${targetFirst ? 'target' : 'source'}-first',
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  testWidgets(
    '取消文件选择后立即恢复原图片和按钮',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const picker = MethodChannel('faceswap_studio/file_dialog');
      final picked = Completer<List<String>>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        picker,
        (_) => picked.future,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          picker,
          null,
        ),
      );
      await show(tester, const WorkspacePage(), const Size(1384, 661));
      await tester.tap(find.text('上传人脸图片'));
      await tester.pump();
      expect(find.text('正在识别人脸'), findsOneWidget);
      picked.complete([]);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('source-import-loading')), findsNothing);
      expect(fixture.sourceRequests, 0);
      final upload = find.ancestor(
        of: find.text('上传人脸图片'),
        matching: find.byType(FilledButton),
      );
      expect(tester.widget<FilledButton>(upload).onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    '视频选择返回前已显示 SVG，取消恢复并覆盖信息读取等待',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const picker = MethodChannel('faceswap_studio/file_dialog');
      var picked = Completer<List<String>>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        picker,
        (_) => picked.future,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          picker,
          null,
        ),
      );
      await show(tester, const WorkspacePage(), const Size(1384, 661));
      await tester.tap(find.text('更换视频'));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('target-import-loading')),
        findsOneWidget,
      );
      expect(fixture.targetRequests, 0);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('视频加载中'), findsOneWidget);
      picked.complete([]);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('target-import-loading')), findsNothing);
      expect(fixture.targetRequests, 0);
      picked = Completer<List<String>>();
      fixture.targetGate = Completer<void>();
      await tester.tap(find.text('更换视频'));
      await tester.pump();
      picked.complete([r'D:\素材\demo.mp4']);
      await tester.pump();
      await tester.pump();
      expect(fixture.targetRequests, 1);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('视频加载中'), findsOneWidget);
      fixture.targetGate!.complete();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      // 此测试使用已有缓存图片作为返回素材，真实解码另由 Windows 集成覆盖。
      expect(find.text('视频加载中'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    '导入格子在请求期间展示真实进度，失败与完成后恢复',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const picker = MethodChannel('faceswap_studio/file_dialog');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        picker,
        (_) async => [r'D:\素材\a.jpg', r'D:\素材\b.jpg', r'D:\素材\c.png'],
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          picker,
          null,
        ),
      );
      fixture.sourceGate = Completer<void>();
      await show(tester, const WorkspacePage(), const Size(1384, 661));
      await tester.tap(find.text('上传人脸图片'));
      await tester.pump();
      expect(find.text('正在识别人脸'), findsOneWidget);
      // 第一帧为原生窗口下方预绘制的等待态，随后更新选择数量。
      await tester.pump();
      await tester.pump();
      expect(find.text('已识别 0 张 / 共 3 张'), findsOneWidget);
      fixture.sourceProcessed = 2;
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(find.text('已识别 2 张 / 共 3 张'), findsOneWidget);
      await capture(tester, 'workspace-face-recognition');
      fixture.sourceFailed = true;
      fixture.sourceGate!.complete();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('正在识别人脸'), findsNothing);
      expect(find.text('未检测到可用人脸'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // 随后的单文件导入使用独立视频格子等待态。
      fixture.targetGate = Completer<void>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        picker,
        (_) async => [r'D:\素材\demo.mp4'],
      );
      await tester.tap(find.text('更换视频'));
      await tester.pump();
      expect(find.text('视频加载中'), findsOneWidget);
      await capture(tester, 'workspace-video-loading');
      fixture.targetGate!.complete();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('视频加载中'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

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
      await finishPreview(tester);
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

  testWidgets('参考脸固定横条、2倍悬浮与中文快捷模式和进阶面板同步', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    fixture.video = true;
    fixture.faceCount = 12;
    await show(tester, const WorkspacePage(), const Size(1384, 661));
    final strip = find.byKey(const ValueKey('workspace-reference-faces'));
    final mode = find.byKey(const ValueKey('workspace-face-mode'));
    expect(find.text('选择模式'), findsNothing, reason: '进阶面板默认收起');
    final initialStripHeight = tester.getSize(strip).height;
    expect(initialStripHeight, 52);
    expect(
      tester.getRect(mode).right,
      lessThan(tester.getRect(find.text('原生预览')).left),
    );
    await tester.tap(find.text('生成预览'));
    await tester.pump();
    await finishPreview(tester);
    expect(tester.getSize(strip).height, initialStripHeight);
    final firstFace = find.byKey(const ValueKey('reference-face-0'));
    final thumbnail = find.byKey(const ValueKey('reference-face-image-0'));
    final hoverImage = find.byKey(const ValueKey('reference-face-hover-0'));
    final media = find.byKey(const ValueKey('workspace-preview-media'));
    final mediaBeforeHover = tester.getRect(media);
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(firstFace));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 200));
    expect(hoverImage, findsOneWidget);
    expect(
      tester.getSize(hoverImage).width,
      closeTo(tester.getSize(thumbnail).width * 2, .1),
    );
    expect(
      tester.getSize(hoverImage).height,
      closeTo(tester.getSize(thumbnail).height * 2, .1),
    );
    expect(tester.getRect(media), mediaBeforeHover, reason: '浮层不占据主布局');
    await capture(tester, 'preview-face-strip-hover');
    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(hoverImage, findsNothing);
    await mouse.removePointer();
    final list = find.descendant(of: strip, matching: find.byType(ListView));
    await tester.drag(list, const Offset(-700, 0));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reference-face-11')).hitTestable(),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('reference-face-11')));
    await tester.pumpAndSettle();
    expect(fixture.options['face_selector_mode'], 'reference');
    expect(fixture.options['reference_face_position'], 11);
    expect(
      find.descendant(of: mode, matching: find.text('参考人脸')),
      findsOneWidget,
    );
    expect(find.text('已生成'), findsOneWidget, reason: '快捷设置保留当前预览供对照');
    for (final entry in {
      '多人': 'many',
      '单人': 'one',
      '参考人脸': 'reference',
    }.entries) {
      await tester.tap(mode);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, entry.key));
      await tester.pumpAndSettle();
      expect(fixture.options['face_selector_mode'], entry.value);
      expect(
        find.descendant(of: mode, matching: find.text(entry.key)),
        findsOneWidget,
      );
      expect(tester.getSize(strip).height, initialStripHeight);
    }
    await tester.tap(find.text('参数面板'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('进阶控制'));
    await tester.pumpAndSettle();
    expect(find.text('选择模式'), findsOneWidget);
    final select = find.byType(DropdownButtonFormField<String>);
    await tester.tap(select);
    await tester.pumpAndSettle();
    for (final label in ['多人', '单人', '参考人脸']) {
      expect(find.text(label), findsWidgets);
    }
    expect(find.text('many'), findsNothing);
    await tester.tap(find.text('单人').last);
    await tester.pumpAndSettle();
    expect(fixture.options['face_selector_mode'], 'one');
    expect(
      find.descendant(of: mode, matching: find.text('单人')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('折叠参数面板'));
    await tester.pumpAndSettle();
    expect(find.text('选择模式'), findsNothing);
    await capture(tester, 'preview-face-strip-mode');
    fixture.previewGate = Completer<void>();
    await tester.tap(find.text('生成预览'));
    await tester.pump();
    expect(tester.widget<PopupMenuButton<String>>(mode).enabled, isFalse);
    fixture.previewGate!.complete();
    await finishPreview(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
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
        final strip = find.byKey(const ValueKey('workspace-reference-faces'));
        final stripHeight = tester.getSize(strip).height;
        expect(find.text('预览帧'), findsOneWidget);
        fixture.previewGate = Completer<void>();
        await tester.tap(find.text('生成预览'));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('workspace-preview-loading')),
          findsOneWidget,
        );
        await capture(
          tester,
          'video-${dark ? 'dark' : 'light'}-${size.width.toInt()}-loading',
        );
        checkFits('$dark $size 生成等待');
        fixture.previewGate!.complete();
        await tester.pump(const Duration(milliseconds: 300));
        await capture(
          tester,
          'video-${dark ? 'dark' : 'light'}-${size.width.toInt()}-faces',
        );
        checkFits('$dark $size 有参考脸');
        expect(tester.getSize(strip).height, closeTo(stripHeight, .1));
        final previousPreviews = fixture.previews;
        await tester.drag(find.byType(Slider).first, const Offset(30, 0));
        await tester.pump(const Duration(milliseconds: 300));
        await finishPreview(tester);
        expect(fixture.previews, greaterThan(previousPreviews));
        await tester.tap(find.byKey(const ValueKey('reference-face-1')));
        await tester.pump(const Duration(milliseconds: 300));
        await finishPreview(tester);
        expect(fixture.options['face_selector_mode'], 'reference');
        expect(fixture.options['reference_face_position'], 1);
        checkFits('$dark $size 切换参考脸');
        fixture.faceCount = 0;
        await tester.tap(find.text('重新生成预览'));
        await tester.pump(const Duration(milliseconds: 300));
        await finishPreview(tester);
        checkFits('$dark $size 无人脸');
        expect(tester.getSize(strip).height, closeTo(stripHeight, .1));
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
