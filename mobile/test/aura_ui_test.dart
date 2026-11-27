import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:universe_lab/aura_ui.dart';
import 'package:universe_lab/cosmic_theme.dart';

void main() {
  testWidgets(
    'original outline glyphs render without capturing control semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      var taps = 0;
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: cosmicTheme,
            home: Scaffold(
              body: Column(
                children: [
                  Wrap(
                    children: [
                      for (final kind in AuraIconKind.values)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: AuraIcon(kind: kind, size: 32),
                        ),
                    ],
                  ),
                  IconButton(
                    tooltip: 'Settings',
                    onPressed: () => taps++,
                    icon: const AuraIcon(kind: AuraIconKind.settings),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.semantics.find(find.byTooltip('Settings')),
          isSemantics(isButton: true, hasTapAction: true, tooltip: 'Settings'),
        );
        await tester.tap(find.byTooltip('Settings'));
        expect(taps, 1);
        expect(cosmicTheme.textTheme.bodyLarge!.fontFamily, 'Literata');
        expect(
          cosmicTheme.textTheme.displayLarge!.fontFamily,
          'Cormorant Garamond',
        );
        expect(cosmicTheme.textTheme.displayLarge!.fontWeight, FontWeight.w300);
        await tester.pumpWidget(const SizedBox());
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('render the vector identity candidate for visual review', (
    tester,
  ) async {
    const key = ValueKey('aura-brand-candidate');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: key,
              child: Container(
                width: 400,
                height: 400,
                decoration: const BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(-0.1, -0.15),
                    radius: 0.85,
                    colors: [
                      Color(0xff16212f),
                      Color(0xff090e20),
                      Color(0xff050507),
                    ],
                    stops: [0, 0.45, 1],
                  ),
                ),
                child: const Center(
                  child: AuraBrandMark(size: 214, color: CosmicPalette.stars),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(key),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2.56);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final path = File('build/stage6/aura-brand-candidate.png');
        await path.parent.create(recursive: true);
        await path.writeAsBytes(data!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
    await tester.pumpWidget(const SizedBox());
  });
}
