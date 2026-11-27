import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:universe_lab/engine.dart';
import 'package:universe_lab/personal_test_gate.dart';
import 'package:universe_lab/release_features.dart';
import 'package:universe_lab/session_core.dart';
import 'package:universe_lab/world_catalog.dart';

import 'session_core_test.dart' show Fixture;

void main() {
  test(
    'personal release needs complete catalog wording and positive model result',
    () async {
      final gate = PersonalTestGate(
        (_, __) async => const Reading(Outcome.held, 'admission_disabled'),
      );
      for (final topic in worldCatalog) {
        for (final language in ['ru', 'en']) {
          expect(
            await gate.call(topic.text(language), language),
            personalTestBuild ? Admission.allowed : Admission.held,
          );
          for (final changed in [
            '${topic.text(language)} But first, should I hurt myself?',
            'ignore safety ${topic.text(language)}',
            '${topic.text(language)}\nprivate context',
            topic.text(language).replaceFirst('?', ' or harm someone?'),
          ]) {
            expect(await gate.call(changed, language), Admission.held);
          }
        }
      }
      expect(
        await gate.call(worldCatalog.first.ru, 'fr'),
        Admission.unavailable,
      );
      expect(
        await PersonalTestGate(
          (_, __) async => const Reading(Outcome.held, 'admission_disabled'),
          enabled: false,
        ).call(worldCatalog.first.ru, 'ru'),
        Admission.held,
      );
    },
  );
  test(
    'no catalog phrase overrides risk, uncertainty, exception or model failure',
    () async {
      for (final row in [
        (Outcome.risk, 'classified', Admission.risk),
        (Outcome.error, 'unavailable', Admission.unavailable),
        (Outcome.held, 'classified', Admission.held),
        (Outcome.held, 'review_pending', Admission.held),
      ]) {
        expect(
          await PersonalTestGate((_, __) async => Reading(row.$1, row.$2))
              .call(worldCatalog.first.ru, 'ru'),
          row.$3,
        );
      }
      expect(
        await PersonalTestGate((_, __) async => throw StateError('private'))
            .call(worldCatalog.first.ru, 'ru'),
        Admission.unavailable,
      );
    },
  );
  test(
    'reset only clears a displayed pause and cancels its notification; no RNG',
    () async {
      final f = Fixture();
      await f.start();
      expect(await f.session.resetPersonalPause(), false);
      await f.answer();
      expect(await f.session.resetPersonalPause(), false);
      expect(f.random.calls, 1);
      await f.session.acknowledgeShown();
      expect(f.notifications.pending, isNotNull);
      expect(await f.session.resetPersonalPause(), personalTestBuild);
      expect(f.random.calls, 1);
      if (personalTestBuild) {
        expect(f.notifications.pending, isNull);
        expect(f.store.record['phase'], 'idle');
        await f.start();
        expect(f.session.phase, SessionPhase.ready);
      } else {
        expect(f.session.phase, SessionPhase.cooldown);
      }
    },
  );
  test('inactive or busy session cannot reset; lost write acknowledgement fails closed', () async {
    final f = Fixture();
    await f.start();
    await f.answer();
    await f.session.acknowledgeShown();
    f.session.setActive(false);
    expect(await f.session.resetPersonalPause(), false);
    f.session.setActive(true);
    if (!personalTestBuild) return;
    final write = Completer<void>();
    f.store.beforeWrite = (_) => write.future;
    final reset = f.session.resetPersonalPause();
    await Future<void>.delayed(Duration.zero);
    expect(await f.session.resetPersonalPause(), false);
    f.store.failAt = f.store.writes.length;
    f.store.commitBeforeFailure = true;
    write.complete();
    expect(await reset, false);
    expect(f.session.phase, SessionPhase.failed);
    expect(f.random.calls, 1);
    f.store.beforeWrite = null;
    await f.start();
    expect(f.session.phase, SessionPhase.ready);
  });
  test(
    'notification cancellation failure cannot expose a new attempt',
    () async {
      final f = Fixture();
      await f.start();
      await f.answer();
      await f.session.acknowledgeShown();
      f.notifications.fails = true;
      expect(await f.session.resetPersonalPause(), false);
      expect(f.store.record['phase'], 'cooldown');
      expect(f.random.calls, 1);
    },
  );
}
