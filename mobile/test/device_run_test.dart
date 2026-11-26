import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:universe_lab/device_run.dart';
import 'package:universe_lab/engine.dart';

void main() {
  test(
    'device measurement uses nearest-rank percentiles and checks both outcomes',
    () async {
      var count = 0;
      final result = await DeviceRun.measure((text, lang) async {
        final risk = text.contains('medicine') || text.contains('лекарство');
        count++;
        return Reading(
          risk ? Outcome.risk : Outcome.held,
          'fixture',
          21 - count,
          count * 1048576,
        );
      }, () => true);
      expect(result.checked, 20);
      expect(result.p50Ms, 10);
      expect(result.p95Ms, 19);
      expect(result.maxSampledRssMiB, 20);
    },
  );

  test('a failed check cannot yield a successful benchmark', () {
    expect(
      DeviceRun.measure(
        (_, _) async => const Reading(Outcome.error, 'failure'),
        () => true,
      ),
      throwsStateError,
    );
  });

  for (final interruptedCheck in [1, 20]) {
    test(
      'interruption during check $interruptedCheck discards the run',
      () async {
        var active = true;
        var count = 0;
        final started = Completer<void>();
        final finish = Completer<void>();
        final run = DeviceRun.measure((text, lang) async {
          count++;
          if (count == interruptedCheck) {
            started.complete();
            await finish.future;
          }
          final risk = text.contains('medicine') || text.contains('лекарство');
          return Reading(
            risk ? Outcome.risk : Outcome.held,
            'fixture',
            1,
            1048576,
          );
        }, () => active);
        final rejected = expectLater(run, throwsStateError);
        await started.future;
        active = false;
        finish.complete();
        await rejected;
        expect(count, interruptedCheck);
      },
    );
  }
}
