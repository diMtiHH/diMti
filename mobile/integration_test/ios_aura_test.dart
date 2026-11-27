import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:universe_lab/aura_renderer.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native AURA shaders render all sixteen environments and living forms',
    (tester) async {
      const budgetChannel = MethodChannel('ask_universe/graphicsBudget');
      try {
        final budget = await budgetChannel.invokeMapMethod<Object?, Object?>(
          'start',
        );
        expect(budget, isNotNull);
        expect(budget!.keys, unorderedEquals(['thermalState', 'lowPowerMode']));
        expect(
          budget['thermalState'],
          isIn(['nominal', 'fair', 'serious', 'critical']),
        );
        expect(budget['lowPowerMode'], isA<bool>());
      } finally {
        await budgetChannel.invokeMethod<void>('stop');
      }
      // Verify registration and fail-closed argument validation without starting
      // playback or requesting speech/microphone access in the native runner.
      const ambientChannel = MethodChannel('ask_universe/ambient');
      await ambientChannel.invokeMethod<void>('stop');
      const motionChannel = MethodChannel('ask_universe/motion');
      await motionChannel.invokeMethod<void>('start');
      await motionChannel.invokeMethod<void>('stop');
      await expectLater(
        motionChannel.invokeMethod<void>('start', {'invalid': true}),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'invalid',
          ),
        ),
      );
      const hapticsChannel = MethodChannel('ask_universe/haptics');
      await hapticsChannel.invokeMethod<void>('cancel', {'owner': 1});
      await expectLater(
        hapticsChannel.invokeMethod<void>('hold', {'owner': true}),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'invalid',
          ),
        ),
      );
      await expectLater(
        ambientChannel.invokeMethod<void>('cue', {'event': 'invalid'}),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'unavailable',
          ),
        ),
      );
      // This must throw on a missing/uncompilable runtime shader. Visual hashes
      // alone could otherwise accidentally validate the warm-up mesh fallback.
      await warmUpAuraShaders();
      final controller = AuraInteractionController();
      const boundaryKey = ValueKey('native-aura-frame');
      final combinations = <String>{};

      Future<String> draw(
        String environment,
        String form,
        double progress,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(
                disableAnimations: true,
                devicePixelRatio: 3,
              ),
              child: Center(
                child: RepaintBoundary(
                  key: boundaryKey,
                  child: SizedBox(
                    width: 192,
                    height: 256,
                    child: AuraScene(
                      background: environment,
                      form: form,
                      phase: progress == 0
                          ? AuraPhase.idle
                          : AuraPhase.answerAnimation,
                      progress: progress,
                      interaction: controller,
                      formAlignment: Alignment.center,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final painter =
            tester
                    .widget<CustomPaint>(
                      find.byWidgetPredicate(
                        (widget) =>
                            widget is CustomPaint &&
                            widget.painter is AuraPainter,
                      ),
                    )
                    .painter!
                as AuraPainter;
        expect(painter.environmentShader, isNotNull);
        if (form == 'livingMatter') expect(painter.matterShader, isNotNull);
        if (form == 'liquidMetal') expect(painter.metalShader, isNotNull);
        final cache = painter.raster!;
        final rasterClock = Stopwatch()..start();
        // A fresh simulator also compiles Metal pipelines for its first raster.
        // Keep servicing frames while it does so. This is a CI readiness bound,
        // not an application frame-time or physical-device performance target.
        await (() async {
          while (cache.inFlight > 0) {
            await tester.pump(const Duration(milliseconds: 20));
          }
        })().timeout(
          const Duration(seconds: 30),
          onTimeout: () => throw TestFailure(
            'Raster did not complete: $environment/$form/$progress; '
            'started=${cache.startedFrames}, completed=${cache.completedFrames}, '
            'discarded=${cache.discardedFrames}',
          ),
        );
        debugPrint(
          'AURA raster ready $environment/$form/$progress: '
          '${rasterClock.elapsedMilliseconds} ms',
        );
        expect(cache.inFlight, 0);
        expect(cache.image, isNotNull);
        expect(cache.pixelSize.width, lessThanOrEqualTo(768));
        expect(cache.pixelSize.height, lessThanOrEqualTo(1536));
        await tester.pump();
        expect(tester.takeException(), isNull);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(boundaryKey),
        );
        final image = await boundary.toImage(pixelRatio: 3);
        try {
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          expect(data, isNotNull);
          final bytes = data!.buffer.asUint8List();
          expect(bytes.length, 192 * 256 * 9 * 4);
          var lit = 0;
          for (var i = 0; i < bytes.length; i += 4) {
            if (bytes[i] + bytes[i + 1] + bytes[i + 2] > 80) ++lit;
          }
          expect(
            lit,
            greaterThan(30),
            reason: '$environment/$form must render actual light',
          );
          return sha256.convert(bytes).toString();
        } finally {
          image.dispose();
        }
      }

      try {
        for (final environment in auraEnvironments) {
          for (final form in auraForms) {
            final idle = await draw(environment, form, 0);
            expect(
              combinations.add(idle),
              isTrue,
              reason: 'Every environment/form pairing must have distinct rendered pixels',
            );
            final animated = await draw(environment, form, .58);
            expect(
              animated,
              isNot(idle),
              reason: '$environment/$form must transform',
            );
          }
        }
        expect(combinations, hasLength(16));
        // Exercise the live Metal/mesh path too: static screenshots alone
        // cannot detect an accidental return to snapshot-per-frame rendering.
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 192,
                height: 256,
                child: AuraScene(
                  background: 'aurora',
                  form: 'constellation',
                  interaction: controller,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final live = tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((widget) => widget.painter)
            .whereType<AuraPainter>()
            .single;
        final cache = live.raster!;
        await (() async {
          while (cache.inFlight > 0) {
            await tester.pump(const Duration(milliseconds: 20));
          }
        })().timeout(const Duration(seconds: 30));
        expect(cache.image, isNotNull);
        final image = cache.image, allocations = cache.startedFrames;
        final time = controller.elapsed;
        for (var frame = 0; frame < 120; ++frame) {
          await tester.pump(const Duration(microseconds: 16667));
        }
        expect(controller.elapsed, greaterThan(time));
        expect(cache.startedFrames, allocations);
        expect(identical(cache.image, image), isTrue);
        expect(cache.inFlight, 0);
        expect(tester.takeException(), isNull);
        debugPrint(
          'AURA live 120 frames: no new atmosphere images; native vectors active',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
