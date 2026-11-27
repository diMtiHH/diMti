import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:universe_lab/aura_renderer.dart';

import 'aura_test_support.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await warmUpAuraShaders();
  });
  test('60 and 120 Hz clocks keep even cadence without fractional drift', () {
    for (final display in [60, 120]) {
      for (final target in [20, 30, 60]) {
        final cadence = AuraFrameCadence(), accepted = <int>[];
        for (var frame = 0; frame < display * 60; ++frame) {
          if (cadence.accept(
            Duration(microseconds: (frame * 1000000 / display).round()),
            target,
          ))
            accepted.add(frame);
        }
        expect(accepted.length, target * 60);
        for (var i = 1; i < accepted.length; ++i) {
          expect(accepted[i] - accepted[i - 1], display ~/ target);
        }
        expect(cadence.accept(const Duration(minutes: 5), target), isTrue);
        expect(cadence.accept(const Duration(minutes: 5), target), isFalse);
      }
    }
  });
  testWidgets(
    'five minutes animate a single atmosphere image; style replaces it once',
    (tester) async {
      final controller = AuraInteractionController();
      Widget app(String background) => MaterialApp(
        home: Center(
          child: SizedBox(
            width: 96,
            height: 160,
            child: AuraScene(
              background: background,
              showForm: false,
              interaction: controller,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      AuraPainter painter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<AuraPainter>()
          .single;
      await tester.pumpWidget(app('aurora'));
      await settleAuraRaster(tester);
      final cache = painter().raster!,
          initial = cache.image,
          count = cache.startedFrames;
      for (var i = 0; i < 3000; ++i) {
        if (i % 300 == 0) {
          controller.pulse();
          await tester.pumpWidget(app('aurora'));
        }
        await tester.pump(const Duration(milliseconds: 100), EnginePhase.build);
      }
      expect(cache.startedFrames, count);
      expect(identical(cache.image, initial), isTrue);
      expect(cache.inFlight, 0);
      await tester.pumpWidget(app('galaxy'));
      await settleAuraRaster(tester);
      expect(cache.startedFrames, count + 1);
      expect(identical(cache.image, initial), isFalse);
      await tester.pumpWidget(const SizedBox());
      expect(cache.image, isNull);
      expect(cache.imageShader, isNull);
      controller.dispose();
    },
  );
  testWidgets(
    'vector details use real 3x pixels and every live frame changes',
    (tester) async {
      const key = ValueKey('sharp-frame');
      final controller = AuraInteractionController();
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox.square(
                dimension: 180,
                child: AuraScene(
                  background: 'aurora',
                  form: 'constellation',
                  showBackground: false,
                  interaction: controller,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
      );
      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<AuraPainter>()
          .single;
      expect(painter.raster, isNull);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(key),
      );
      Future<List<int>> frame(double ratio) async =>
          (await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: ratio);
            try {
              return (await image.toByteData())!.buffer.asUint8List().toList();
            } finally {
              image.dispose();
            }
          }))!;
      final high = await frame(3), low = await frame(1);
      var detailPixels = 0;
      for (var y = 0; y < 540; ++y) {
        for (var x = 0; x < 540; ++x) {
          final a = high[(y * 540 + x) * 4 + 3],
              b = low[((y ~/ 3) * 180 + x ~/ 3) * 4 + 3];
          if ((a - b).abs() > 16) ++detailPixels;
        }
      }
      expect(
        detailPixels,
        greaterThan(500),
        reason: 'Fine geometry must not be a nearest-upscaled 1x image.',
      );
      var previous = high;
      for (var i = 0; i < 10; ++i) {
        await tester.pump(const Duration(microseconds: 16667));
        final next = await frame(3);
        expect(next, isNot(orderedEquals(previous)));
        previous = next;
      }
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
