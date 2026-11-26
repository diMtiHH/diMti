import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:universe_lab/voice_star.dart';

void main() {
  const boundaryKey = ValueKey('star-preview');

  Widget app({
    double level = 0,
    bool listening = true,
    bool active = true,
    bool enabled = true,
    bool reduced = true,
    VoidCallback? onPressed,
  }) => MaterialApp(
    theme: ThemeData(brightness: Brightness.dark),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: boundaryKey,
            child: SizedBox(
              width: 400,
              height: 320,
              child: ColoredBox(
                color: const Color(0xff050507),
                child: VoiceStar(
                  level: level,
                  listening: listening,
                  active: active,
                  enabled: enabled,
                  label: 'Speak your question',
                  onPressed: onPressed,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  VoiceStarPainter painter(WidgetTester tester) =>
      tester
              .widget<CustomPaint>(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is CustomPaint &&
                      widget.painter is VoiceStarPainter,
                ),
              )
              .painter!
          as VoiceStarPainter;

  Future<Uint8List> pixels(WidgetTester tester) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(boundaryKey),
    );
    return (await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        return Uint8List.fromList(data!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    }))!;
  }

  testWidgets(
    'measured level changes rendered brightness and creates a preview',
    (tester) async {
      await tester.pumpWidget(app(level: 0));
      await tester.pumpAndSettle();
      final quiet = await pixels(tester);
      await tester.pumpWidget(app(level: 0.85));
      await tester.pumpAndSettle();
      final speaking = await pixels(tester);
      expect(speaking, isNot(orderedEquals(quiet)));
      expect(painter(tester).motion, isFalse);
      // A visual artifact for review, not a golden comparison or microphone test.
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundaryKey),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        try {
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = File('build/stage4/star-preview.png');
          await output.parent.create(recursive: true);
          await output.writeAsBytes(png!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'reduced motion stops the breathing ticker while retaining audio feedback',
    (tester) async {
      await tester.pumpWidget(app(reduced: false, level: 0.4));
      await tester.pump(const Duration(milliseconds: 400));
      expect(painter(tester).motion, isTrue);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pumpWidget(app(reduced: true, level: 0.4));
      await tester.pumpAndSettle();
      expect(painter(tester).motion, isFalse);
      expect(painter(tester).energy, 0.4);
      expect(tester.binding.transientCallbackCount, 0);
      final before = await pixels(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(await pixels(tester), orderedEquals(before));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'inactive star freezes animation and disabled star does not tick',
    (tester) async {
      await tester.pumpWidget(app(reduced: false));
      await tester.pump(const Duration(milliseconds: 600));
      expect(painter(tester).motion, isTrue);
      await tester.pumpWidget(app(active: false, reduced: false));
      await tester.pumpAndSettle();
      final before = await pixels(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(await pixels(tester), orderedEquals(before));
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(app(enabled: false, reduced: false));
      await tester.pumpAndSettle();
      expect(painter(tester).enabled, isFalse);
      expect(painter(tester).motion, isFalse);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('star has button semantics and cannot activate when disabled', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var presses = 0;
    try {
      await tester.pumpWidget(app(onPressed: () => presses++));
      await tester.pumpAndSettle();
      expect(
        tester.semantics.find(find.byKey(const ValueKey('voice-star'))),
        isSemantics(
          label: 'Speak your question',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('voice-star'))).shortestSide,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.byKey(const ValueKey('voice-star')));
      await tester.pumpAndSettle();
      expect(presses, 1);
      await tester.pumpWidget(app(enabled: false, onPressed: () => presses++));
      await tester.pumpAndSettle();
      expect(
        tester.semantics.find(find.byKey(const ValueKey('voice-star'))),
        isSemantics(isButton: true, isEnabled: false, hasTapAction: false),
      );
      await tester.tap(find.byKey(const ValueKey('voice-star')));
      await tester.pumpAndSettle();
      expect(presses, 1);
      await tester.pumpWidget(const SizedBox());
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'malformed audio levels render safely and inactive speech ignores stale energy',
    (tester) async {
      for (final value in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
        -1.0,
        2.0,
      ]) {
        await tester.pumpWidget(app(level: value));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(painter(tester).energy, value == 2.0 ? 1.0 : 0.0);
      }
      await tester.pumpWidget(app(level: 1, listening: false));
      await tester.pumpAndSettle();
      expect(painter(tester).energy, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
