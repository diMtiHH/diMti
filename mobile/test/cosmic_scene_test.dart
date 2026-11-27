import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:universe_lab/cosmic_scene.dart';
import 'package:universe_lab/cosmic_theme.dart';

void main() {
  const boundaryKey = ValueKey('cosmic-preview');

  Widget app({
    String background = 'stars',
    String style = 'coin',
    bool active = true,
    bool animate = true,
    bool reduced = true,
    bool accessible = false,
    bool ticker = true,
    Widget? foreground,
  }) => MaterialApp(
    theme: cosmicTheme,
    home: MediaQuery(
      data: MediaQueryData(
        disableAnimations: reduced,
        accessibleNavigation: accessible,
      ),
      child: TickerMode(
        enabled: ticker,
        child: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: SizedBox(
                width: 320,
                height: 480,
                child: CosmicScene(
                  background: background,
                  active: active,
                  animate: animate,
                  child:
                      foreground ??
                      Center(
                        child: AnswerStylePreview(
                          style: style,
                          active: active,
                          animate: animate,
                          semanticLabel: 'Decorative style preview',
                        ),
                      ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  T painter<T extends CustomPainter>(WidgetTester tester) =>
      tester
              .widget<CustomPaint>(
                find.byWidgetPredicate(
                  (widget) => widget is CustomPaint && widget.painter is T,
                ),
              )
              .painter!
          as T;

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

  Future<void> expectFrozen(WidgetTester tester) async {
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    final before = await pixels(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(await pixels(tester), orderedEquals(before));
    expect(tester.binding.transientCallbackCount, 0);
  }

  test(
    'primary and secondary reading colors have sufficient dark contrast',
    () {
      double contrast(Color foreground, Color background) =>
          (foreground.computeLuminance() + 0.05) /
          (background.computeLuminance() + 0.05);
      for (final background in [CosmicPalette.deep, CosmicPalette.night]) {
        expect(
          contrast(CosmicPalette.white, background),
          greaterThanOrEqualTo(7),
        );
        expect(
          contrast(CosmicPalette.silver, background),
          greaterThanOrEqualTo(7),
        );
      }
      expect(
        cosmicTheme.textTheme.bodyLarge!.fontSize,
        greaterThanOrEqualTo(16),
      );
      expect(
        cosmicTheme.textTheme.bodyMedium!.height,
        greaterThanOrEqualTo(1.4),
      );
    },
  );

  testWidgets(
    'all sixteen background and style combinations remain independent',
    (tester) async {
      final rendered = <Uint8List>[];
      for (final background in cosmicBackgrounds) {
        for (final style in cosmicAnswerStyles) {
          await tester.pumpWidget(app(background: background, style: style));
          await tester.pumpAndSettle();
          expect(painter<CosmicScenePainter>(tester).background, background);
          expect(painter<AnswerStylePainter>(tester).style, style);
          final image = await pixels(tester);
          for (final previous in rendered) {
            expect(image, isNot(orderedEquals(previous)));
          }
          rendered.add(image);
          expect(tester.takeException(), isNull);
        }
      }
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'normal motion advances independently without changing selection',
    (tester) async {
      await tester.pumpWidget(
        app(reduced: false, background: 'galaxy', style: 'sphere'),
      );
      await tester.pump(const Duration(seconds: 2));
      final scene = painter<CosmicScenePainter>(tester);
      final preview = painter<AnswerStylePainter>(tester);
      expect(scene.phase, greaterThan(0));
      expect(preview.phase, greaterThan(scene.phase));
      expect(scene.background, 'galaxy');
      expect(preview.style, 'sphere');
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Reduce Motion freezes scene and preview while retaining their image',
    (tester) async {
      await tester.pumpWidget(app(reduced: false));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pumpWidget(app(reduced: true));
      await expectFrozen(tester);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('accessible navigation stops decorative animation', (
    tester,
  ) async {
    await tester.pumpWidget(app(reduced: false, accessible: true));
    await expectFrozen(tester);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('inactive, disabled animation and TickerMode suspend motion', (
    tester,
  ) async {
    await tester.pumpWidget(app(reduced: false));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(app(reduced: false, active: false));
    await expectFrozen(tester);
    await tester.pumpWidget(app(reduced: false, animate: false));
    await expectFrozen(tester);
    await tester.pumpWidget(app(reduced: false, ticker: false));
    await expectFrozen(tester);
    await tester.pumpWidget(app(reduced: false));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'background lifecycle suspends both clocks and resume obeys active',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      try {
        await tester.pumpWidget(app(reduced: false));
        await tester.pump(const Duration(seconds: 1));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await expectFrozen(tester);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        expect(tester.binding.transientCallbackCount, 0);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pumpWidget(app(reduced: false, active: false));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await expectFrozen(tester);
        await tester.pumpWidget(app(reduced: false));
        await tester.pump(const Duration(seconds: 1));
        expect(tester.binding.transientCallbackCount, greaterThan(0));
      } finally {
        await tester.pumpWidget(const SizedBox());
        final state = tester.binding.lifecycleState;
        if (state == AppLifecycleState.paused) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
        }
        if (tester.binding.lifecycleState == AppLifecycleState.hidden) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
        }
        if (tester.binding.lifecycleState != AppLifecycleState.resumed) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        }
      }
    },
  );

  testWidgets(
    'decorations preserve foreground taps and provide passive semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      var presses = 0;
      try {
        await tester.pumpWidget(
          app(
            foreground: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const AnswerStylePreview(
                  style: 'constellation',
                  animate: false,
                  semanticLabel: 'Constellation preview only',
                ),
                FilledButton(
                  onPressed: () => presses++,
                  child: const Text('Continue'),
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.semantics.find(
            find.bySemanticsLabel('Constellation preview only'),
          ),
          isSemantics(isImage: true, isButton: false, hasTapAction: false),
        );
        expect(find.text('ДА'), findsNothing);
        expect(find.text('НЕТ'), findsNothing);
        expect(find.text('YES'), findsNothing);
        expect(find.text('NO'), findsNothing);
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
        expect(presses, 1);
        await tester.pumpWidget(const SizedBox());
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'unknown persisted appearance falls back to valid passive visuals',
    (tester) async {
      await tester.pumpWidget(app(background: 'invalid', style: 'invalid'));
      await tester.pumpAndSettle();
      expect(painter<CosmicScenePainter>(tester).background, 'stars');
      expect(painter<AnswerStylePainter>(tester).style, 'coin');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'render a deterministic sixteen-combination contact sheet for review',
    (tester) async {
      // A local system font makes the review artifact readable outside the test
      // runner. The app still uses platform typography; no font asset is shipped.
      final family = await tester.runAsync(() async {
        for (final path in [
          r'C:\Windows\Fonts\segoeui.ttf',
          '/System/Library/Fonts/Supplemental/Arial.ttf',
          '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
        ]) {
          final file = File(path);
          if (!await file.exists()) continue;
          final loader = FontLoader('CosmicPreviewSans');
          loader.addFont(
            Future.value(ByteData.sublistView(await file.readAsBytes())),
          );
          await loader.load();
          return 'CosmicPreviewSans';
        }
        return null;
      });
      await tester.binding.setSurfaceSize(const Size(1000, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final theme = cosmicTheme;
      await tester.pumpWidget(
        MaterialApp(
          theme: family == null
              ? theme
              : theme.copyWith(
                  textTheme: theme.textTheme.apply(fontFamily: family),
                ),
          home: Scaffold(
            body: RepaintBoundary(
              key: boundaryKey,
              child: ColoredBox(
                color: CosmicPalette.deep,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'ASK THE UNIVERSE',
                        style: TextStyle(
                          fontSize: 24,
                          color: CosmicPalette.white,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Stage 5 · visual foundation · 16 independent combinations',
                        style: TextStyle(
                          fontSize: 14,
                          color: CosmicPalette.silver,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (
                              var i = 0;
                              i < cosmicBackgrounds.length;
                              i++
                            ) ...[
                              if (i > 0) const SizedBox(width: 12),
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(24),
                                  child: CosmicScene(
                                    background: cosmicBackgrounds[i],
                                    animate: false,
                                    child: Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: Column(
                                        children: [
                                          Text(
                                            [
                                              'Stars',
                                              'Galaxy',
                                              'Nebula',
                                              'Black hole',
                                            ][i],
                                            style: const TextStyle(
                                              fontSize: 20,
                                              color: CosmicPalette.white,
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          for (
                                            var s = 0;
                                            s < cosmicAnswerStyles.length;
                                            s++
                                          )
                                            Expanded(
                                              child: Column(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  AnswerStylePreview(
                                                    style:
                                                        cosmicAnswerStyles[s],
                                                    size: 112,
                                                    animate: false,
                                                  ),
                                                  Text(
                                                    [
                                                      'Coin',
                                                      'Sphere',
                                                      'Black hole',
                                                      'Constellation',
                                                    ][s],
                                                    style: const TextStyle(
                                                      fontSize: 12,
                                                      color:
                                                          CosmicPalette.silver,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.binding.transientCallbackCount, 0);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundaryKey),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1.5);
        try {
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = File('build/stage5/cosmic-preview.png');
          await output.parent.create(recursive: true);
          await output.writeAsBytes(png!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
      await tester.pumpWidget(const SizedBox());
    },
  );
}
