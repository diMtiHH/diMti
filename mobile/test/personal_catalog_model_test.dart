import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:universe_lab/engine.dart';
import 'package:universe_lab/world_catalog.dart';

void main() {
  test('catalog is checked by the packaged model in both languages', () async {
    final model = await LocalEngine.open(Directory('assets/stage2').absolute);
    try {
      for (final topic in worldCatalog) {
        for (final language in ['ru', 'en']) {
          final result = model.inspect(topic.text(language), language);
          // Keep the diagnostic classifier unchanged; personal access is a
          // separate policy and still cannot override risk or model errors.
          expect(result.outcome, Outcome.held, reason: '${topic.id}/$language');
          expect(
            result.reason,
            'admission_disabled',
            reason: '${topic.id}/$language',
          );
        }
      }
    } finally {
      await model.close();
    }
  });
}
