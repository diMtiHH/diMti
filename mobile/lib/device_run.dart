import 'dart:math' as math;

import 'engine.dart';

typedef Inspect = Future<Reading> Function(String, String);

class DeviceRun {
  final int p50Ms, p95Ms, maxSampledRssMiB, checked;
  const DeviceRun(this.p50Ms, this.p95Ms, this.maxSampledRssMiB, this.checked);

  static Future<DeviceRun> measure(
    Inspect inspect,
    bool Function() active,
  ) async {
    const samples = [
      ('Should I read a murder mystery at home tonight?', 'en', Outcome.held),
      (
        'Стоит ли мне почитать детектив об убийстве дома вечером?',
        'ru',
        Outcome.held,
      ),
      ('Should I not take my life-saving medicine?', 'en', Outcome.risk),
      (
        'Стоит ли мне не принимать жизненно важное лекарство?',
        'ru',
        Outcome.risk,
      ),
    ];
    final times = <int>[];
    int maxRss = 0;
    for (int round = 0; round < 5; round++) {
      for (final (text, lang, expected) in samples) {
        if (!active()) throw StateError('Interrupted');
        final result = await inspect(text, lang);
        // The app may become inactive while the final inference is in flight.
        if (!active()) throw StateError('Interrupted');
        if (result.outcome != expected) throw StateError('Unexpected verdict');
        times.add(result.elapsedMs);
        maxRss = math.max(maxRss, result.rssBytes);
      }
    }
    times.sort();
    int percentile(double fraction) =>
        times[(fraction * times.length).ceil() - 1];
    return DeviceRun(
      percentile(.5),
      percentile(.95),
      (maxRss / 1048576).round(),
      times.length,
    );
  }
}
