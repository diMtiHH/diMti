import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:universe_lab/aura_renderer.dart';

import 'aura_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(warmUpAuraShaders);
  test(
    'soft atmosphere texture is bounded; fine details use native pixels',
    () {
      const logical = ui.Size(390, 844);
      final background = auraRasterSize(logical, form: false);
      expect(background.width, lessThanOrEqualTo(768));
      expect(background.height, lessThanOrEqualTo(1536));
      final previousPixels = logical.width * logical.height * 9;
      expect(
        background.width * background.height / previousPixels,
        lessThan(.4),
      );
      final form = auraRasterSize(const ui.Size(430, 430), form: true);
      expect(form, const ui.Size(512, 512));
      expect(
        auraRasterSize(const ui.Size(430, 430), form: true, preview: true),
        const ui.Size(320, 320),
      );
      final hot = auraRasterSize(logical, form: false, quality: .3);
      expect(
        hot.width * hot.height,
        lessThan(background.width * background.height),
      );
      expect(auraRasterSize(ui.Size.zero, form: true), ui.Size.zero);
    },
  );

  void draw(ui.Canvas canvas, ui.Size logical) => canvas.drawRect(
    ui.Offset.zero & logical,
    ui.Paint()..color = const ui.Color(0xff56c8b2),
  );

  testWidgets('the actual cached image uses the capped dimensions', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final cache = AuraRasterCache();
      const logical = ui.Size(390, 844);
      final target = auraRasterSize(logical, form: false);
      expect(cache.render(logical, target, draw), isTrue);
      expect(cache.inFlight, 1);
      await cache.settled;
      expect(cache.image, isNotNull);
      expect(cache.image!.width, target.width.toInt());
      expect(cache.image!.height, target.height.toInt());
      expect(cache.inFlight, 0);
      expect(cache.completedFrames, 1);
      cache.dispose();
      expect(cache.image, isNull);
    });
  });

  testWidgets('slow GPU keeps one frame in flight and no queued stale work', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final gate = Completer<void>();
      var nativeCalls = 0;
      final cache = AuraRasterCache(
        rasterize: (picture, w, h) async {
          ++nativeCalls;
          await gate.future;
          return picture.toImage(w, h);
        },
      );
      expect(
        cache.render(const ui.Size(100, 100), const ui.Size(16, 16), draw),
        isTrue,
      );
      for (var i = 0; i < 10000; i++) {
        expect(
          cache.render(const ui.Size(100, 100), const ui.Size(16, 16), draw),
          isFalse,
        );
        expect(cache.inFlight, 1);
      }
      expect(nativeCalls, 1);
      expect(cache.startedFrames, 1);
      expect(cache.busyDrops, 10000);
      gate.complete();
      await cache.settled;
      expect(cache.completedFrames, 1);
      expect(nativeCalls, 1);
      cache.dispose();
    });
  });

  testWidgets(
    'superseded or disposed frames cannot restore a released texture',
    (tester) async {
      await tester.runAsync(() async {
        final gate = Completer<void>();
        final cache = AuraRasterCache(
          rasterize: (picture, w, h) async {
            await gate.future;
            return picture.toImage(w, h);
          },
        );
        cache.render(const ui.Size(100, 100), const ui.Size(16, 16), draw);
        cache.invalidate();
        gate.complete();
        await cache.settled;
        expect(cache.image, isNull);
        expect(cache.discardedFrames, 1);
        var updates = 0;
        cache.addListener(() => updates++);
        cache.render(const ui.Size(100, 100), const ui.Size(16, 16), draw);
        cache.dispose();
        await cache.settled;
        expect(updates, 0);
        expect(cache.image, isNull);
        expect(cache.discardedFrames, 2);
        expect(
          cache.render(const ui.Size(100, 100), const ui.Size(16, 16), draw),
          isFalse,
        );
      });
    },
  );

  testWidgets(
    'static native previews stop scheduling and refresh changed parameters',
    (tester) async {
      final interaction = AuraInteractionController();
      Widget app({
        String form = 'livingMatter',
        String environment = 'aurora',
        double progress = 0,
      }) => MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: 260,
            child: RepaintBoundary(
              key: const ValueKey('static-preview'),
              child: AuraScene(
                background: environment,
                form: form,
                phase: AuraPhase.answerAnimation,
                progress: progress,
                interaction: interaction,
                active: false,
                preview: true,
                showBackground: false,
                formAlignment: Alignment.center,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
      AuraPainter painter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((widget) => widget.painter)
          .whereType<AuraPainter>()
          .single;
      Future<List<int>> pixels() async {
        await settleAuraRaster(tester);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('static-preview')),
        );
        return (await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          try {
            return (await image.toByteData())!.buffer.asUint8List().toList();
          } finally {
            image.dispose();
          }
        }))!;
      }

      await tester.pumpWidget(app());
      final first = await pixels();
      expect(painter().raster, isNull);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(seconds: 30));
        await tester.pumpWidget(app());
      }
      expect(painter().raster, isNull);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(app(form: 'liquidMetal'));
      final metal = await pixels();
      expect(metal, isNot(orderedEquals(first)));
      await tester.pumpWidget(app(form: 'liquidMetal', progress: .65));
      expect(await pixels(), isNot(orderedEquals(metal)));
      await tester.pumpWidget(app(form: 'liquidMetal', environment: 'gravity'));
      expect(await pixels(), isNot(orderedEquals(metal)));
      await tester.pumpWidget(const SizedBox());
      interaction.dispose();
    },
  );
}
