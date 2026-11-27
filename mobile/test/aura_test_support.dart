import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universe_lab/aura_renderer.dart';

/// Capture actual bounded shader images, never a transient warm-up fallback.
Future<void> settleAuraRaster(WidgetTester tester) async {
  final caches = tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((widget) => widget.painter)
      .whereType<AuraPainter>()
      .map((painter) => painter.raster)
      .whereType<AuraRasterCache>()
      .toSet();
  // The renderer's Future chain was created in the widget FakeAsync zone.
  // Let the raster thread finish, then pump that zone instead of awaiting its
  // completion from runAsync (which would prevent those microtasks from running).
  for (var attempt = 0; attempt < 300; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (caches.every((cache) => cache.inFlight == 0 && cache.image != null))
      return;
  }
  for (final cache in caches) {
    expect(cache.inFlight, 0, reason: 'Raster completion must be bounded.');
    expect(
      cache.image,
      isNotNull,
      reason: 'Screenshot must include the actual rasterized shader.',
    );
  }
}
