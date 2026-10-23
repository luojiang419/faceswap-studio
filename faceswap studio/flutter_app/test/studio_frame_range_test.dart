import 'package:faceswap_studio/shared/widgets/studio_frame_range.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('I/O 包含当前帧，反向标点保持非空，全片清除裁剪', (tester) async {
    int? start, end;
    var current = 106;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return StudioFrameRange(
                total: 551,
                currentFrame: current,
                start: start,
                end: end,
                onChanged: (a, b) => setState(() {
                  start = a;
                  end = b;
                }),
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('clip-mark-in')));
    await tester.pump();
    expect(start, 106);
    expect(end, 551);
    update(() => current = 200);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('clip-mark-out')));
    await tester.pump();
    expect(start, 106);
    expect(end, 201);
    expect(find.textContaining('95 帧'), findsOneWidget);
    update(() => current = 550);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('clip-mark-in')));
    await tester.pump();
    expect(start, 550);
    expect(end, 551);
    await tester.tap(find.byKey(const ValueKey('clip-reset')));
    await tester.pump();
    expect(start, isNull);
    expect(end, isNull);
  });

  testWidgets('拖动区间提交实际帧边界，生成时不可操作', (tester) async {
    int? start, end;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudioFrameRange(
            total: 100,
            currentFrame: 20,
            start: 10,
            end: 80,
            onChanged: (a, b) {
              start = a;
              end = b;
            },
          ),
        ),
      ),
    );
    final slider = tester.widget<RangeSlider>(find.byType(RangeSlider));
    slider.onChanged!(const RangeValues(25, 40));
    slider.onChangeEnd!(const RangeValues(25, 40));
    await tester.pump();
    expect(start, 25);
    expect(end, 41);
    final rect = tester.getRect(find.byType(RangeSlider));
    await tester.dragFrom(
      Offset(rect.left + 24 + (rect.width - 48) * 79 / 99, rect.center.dy),
      const Offset(-120, 0),
    );
    await tester.pump();
    expect(end, lessThan(80));
    expect(end, greaterThan(start!));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StudioFrameRange(
            total: 100,
            currentFrame: 20,
            start: null,
            end: null,
            onChanged: null,
          ),
        ),
      ),
    );
    expect(
      tester.widget<RangeSlider>(find.byType(RangeSlider)).onChanged,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('clip-mark-in')))
          .onPressed,
      isNull,
    );
  });
}
