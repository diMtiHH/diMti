import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:universe_lab/closed_model_gate.dart';
import 'package:universe_lab/engine.dart';
import 'package:universe_lab/session_core.dart';

// Faults model both outcomes of an ambiguous atomic write: no commit or a
// committed replacement whose acknowledgement was lost. No real user input.
class MemoryStore implements SessionStore {
  String? value;
  final writes = <String>[];
  int? failAt;
  bool commitBeforeFailure = false;
  bool failRead = false;
  Future<void> Function(int)? beforeWrite;

  @override
  Future<String?> read() async {
    if (failRead) throw StateError('Read failed');
    return value;
  }

  @override
  Future<void> replace(String next) async {
    writes.add(next);
    await beforeWrite?.call(writes.length);
    if (writes.length == failAt) {
      if (commitBeforeFailure) value = next;
      throw StateError('Write failed');
    }
    value = next;
  }

  Map<String, dynamic> get record => jsonDecode(value!) as Map<String, dynamic>;
}

class TestClock implements SessionClock {
  int utc = 1800000000000;
  int continuous = 5000000;
  String boot = 'test-boot-a';
  bool fails = false;

  void advance(int milliseconds) {
    utc += milliseconds;
    continuous += milliseconds;
  }

  @override
  Future<ClockSample> read() async {
    if (fails) throw StateError('Clock unavailable');
    return ClockSample(utc, continuous, boot);
  }
}

class CountingRandom implements AnswerSource {
  int calls = 0;
  int value = 49;
  bool fails = false;
  @override
  int next100() {
    ++calls;
    if (fails) throw StateError('Random unavailable');
    return value;
  }
}

class TestNotifications implements PauseNotifications {
  PauseNotification? pending;
  int schedules = 0;
  bool fails = false;
  @override
  Future<void> replace(PauseNotification request) async {
    if (fails) throw StateError('Notifications unavailable');
    ++schedules;
    pending = request;
  }

  @override
  Future<void> cancel() async {
    if (fails) throw StateError('Notifications unavailable');
    pending = null;
  }
}

class Fixture {
  final store = MemoryStore();
  final clock = TestClock();
  final random = CountingRandom();
  final notifications = TestNotifications();
  late QuestionSession session;

  Future<void> start({
    QuestionValidator? validator,
    String language = 'ru',
  }) async {
    session = QuestionSession(
      store: store,
      clock: clock,
      random: random,
      notifications: notifications,
      initialLanguage: language,
      // Artificial ALLOW is isolated to this test fixture; never a runtime flag.
      validateQuestion: validator ?? (_, _) async => Admission.allowed,
      validationTimeout: const Duration(milliseconds: 10),
    );
    await session.initialize();
  }

  QuestionReview prepare() {
    expect(session.edit('synthetic fixture'), isTrue);
    return session.review()!;
  }

  Future<void> answer() async {
    expect(await session.confirm(prepare()), SubmitResult.pending);
  }

  Future<void> pause() async {
    await answer();
    expect(await session.acknowledgeShown(), isTrue);
  }
}

void main() {
  test('all 100 values map to exactly 50 YES and 50 NO', () {
    final answers = List.generate(100, answerFor);
    expect(answers.where((a) => a == Answer.yes), hasLength(50));
    expect(answers.where((a) => a == Answer.no), hasLength(50));
    expect([0, 49, 50, 99].map(answerFor), [
      Answer.yes,
      Answer.yes,
      Answer.no,
      Answer.no,
    ]);
    expect(() => answerFor(-1), throwsFormatException);
    expect(() => answerFor(100), throwsFormatException);
  });

  test('system source returns only integers inside its contract', () {
    final source = SystemAnswerSource();
    // Range smoke check, not a statistical proof of randomness or fairness.
    for (var i = 0; i < 100; ++i) {
      expect(source.next100(), inInclusiveRange(0, 99));
    }
  });

  test(
    'production gate never reaches RNG for any model outcome or error',
    () async {
      for (final outcome in <Outcome?>[...Outcome.values, null]) {
        for (final language in ['ru', 'en']) {
          final f = Fixture();
          final gate = ClosedModelGate((_, _) async {
            if (outcome == null) throw StateError('Adapter unavailable');
            return Reading(outcome, 'test-only');
          });
          await f.start(validator: gate.call);
          f.session.edit('synthetic fixture', language: language);
          final result = await f.session.confirm(f.session.review()!);
          expect(
            result,
            outcome == Outcome.risk
                ? SubmitResult.risk
                : outcome == Outcome.held
                ? SubmitResult.held
                : SubmitResult.unavailable,
          );
          expect(f.random.calls, 0);
          expect(f.store.writes, isEmpty);
          expect(f.session.phase, SessionPhase.ready);
          expect(f.session.draft, isEmpty);
          expect(f.notifications.pending, isNull);
        }
      }
    },
  );

  test('unsupported language never invokes the model adapter', () async {
    var calls = 0;
    final gate = ClosedModelGate((_, _) async {
      ++calls;
      return const Reading(Outcome.held, 'test');
    });
    expect(await gate('synthetic fixture', 'de'), Admission.unavailable);
    expect(calls, 0);
  });

  test(
    'editing or cancelling a review requires a fresh explicit confirmation',
    () async {
      final f = Fixture();
      await f.start();
      expect(f.session.review(), isNull);
      f.session.edit(' ');
      expect(f.session.review(), isNull);
      f.session.edit('a' * 8193);
      expect(f.session.review(), isNull);
      final old = f.prepare();
      expect(f.random.calls, 0);
      expect(f.store.writes, isEmpty);
      f.session.edit('revised fixture');
      expect(await f.session.confirm(old), SubmitResult.stale);
      final changed = f.session.review()!;
      f.session.cancelReview();
      expect(await f.session.confirm(changed), SubmitResult.stale);
      final latest = f.session.review()!;
      expect(await f.session.confirm(latest), SubmitResult.pending);
      expect(f.random.calls, 1);
    },
  );

  test(
    'review from another session and changed language cannot authorize RNG',
    () async {
      final a = Fixture(), b = Fixture();
      await a.start();
      await b.start();
      final foreign = a.prepare();
      final local = b.prepare();
      expect(await b.session.confirm(foreign), SubmitResult.stale);
      b.session.edit('synthetic fixture', language: 'en');
      expect(await b.session.confirm(local), SubmitResult.stale);
      expect(b.session.edit('synthetic fixture', language: 'de'), isFalse);
      expect(b.random.calls, 0);
    },
  );

  test('confirmation sends the exact approved text and language', () async {
    final f = Fixture();
    String? seenText, seenLanguage;
    await f.start(
      validator: (text, language) async {
        seenText = text;
        seenLanguage = language;
        return Admission.held;
      },
    );
    const text = '  Not a real question.\nНе удалять отрицание.  ';
    f.session.edit(text, language: 'en');
    await f.session.confirm(f.session.review()!);
    expect(seenText, text);
    expect(seenLanguage, 'en');
    expect(f.session.draft, isEmpty);
    expect(f.random.calls, 0);
  });

  for (final interrupt in ['edit', 'language', 'background']) {
    test('$interrupt during validation discards the late ALLOW', () async {
      final f = Fixture();
      final decision = Completer<Admission>();
      await f.start(validator: (_, _) => decision.future);
      final pending = f.session.confirm(f.prepare());
      if (interrupt == 'background') {
        f.session.setActive(false);
        f.session.setActive(true);
      } else {
        f.session.edit(
          'replacement fixture',
          language: interrupt == 'language' ? 'en' : 'ru',
        );
      }
      decision.complete(Admission.allowed);
      expect(await pending, SubmitResult.stale);
      expect(f.random.calls, 0);
      expect(f.store.writes, isEmpty);
      expect(f.session.phase, SessionPhase.ready);
    });
  }

  test(
    'timeout and validator failure keep the attempt available without RNG',
    () async {
      for (final throws in [false, true]) {
        final f = Fixture();
        final decision = Completer<Admission>();
        await f.start(
          validator: (_, _) {
            if (throws) throw StateError('Validator failed');
            return decision.future;
          },
        );
        expect(await f.session.confirm(f.prepare()), SubmitResult.unavailable);
        decision.complete(Admission.allowed);
        await Future<void>.delayed(Duration.zero);
        expect(f.random.calls, 0);
        expect(f.store.writes, isEmpty);
        expect(f.session.phase, SessionPhase.ready);
      }
    },
  );

  test('double tap invokes one validation and one random draw', () async {
    final f = Fixture();
    final decision = Completer<Admission>();
    var validations = 0;
    await f.start(
      validator: (_, _) {
        ++validations;
        return decision.future;
      },
    );
    final review = f.prepare();
    final first = f.session.confirm(review);
    expect(await f.session.confirm(review), SubmitResult.busy);
    decision.complete(Admission.allowed);
    expect(await first, SubmitResult.pending);
    expect(await f.session.confirm(review), SubmitResult.stale);
    expect(validations, 1);
    expect(f.random.calls, 1);
  });

  test(
    'background clears review and disallows submission while inactive',
    () async {
      final f = Fixture();
      await f.start();
      final review = f.prepare();
      f.session.setActive(false);
      expect(f.session.draft, isEmpty);
      expect(f.session.edit('hidden input'), isFalse);
      expect(f.session.review(), isNull);
      expect(await f.session.confirm(review), SubmitResult.stale);
      f.session.setActive(true);
      expect(f.session.phase, SessionPhase.ready);
      expect(f.random.calls, 0);
    },
  );

  test('background during intent persistence cancels before RNG', () async {
    final f = Fixture();
    await f.start();
    f.store.beforeWrite = (n) async {
      if (n == 1) f.session.setActive(false);
    };
    expect(await f.session.confirm(f.prepare()), SubmitResult.stale);
    expect(f.random.calls, 0);
    expect(f.store.record['phase'], 'idle');
  });

  test('answer stays hidden until its persistence is acknowledged', () async {
    final f = Fixture();
    final entered = Completer<void>(), release = Completer<void>();
    await f.start();
    f.store.beforeWrite = (n) async {
      if (n == 2) {
        entered.complete();
        await release.future;
      }
    };
    final pending = f.session.confirm(f.prepare());
    await entered.future;
    expect(f.random.calls, 1);
    expect(f.session.pendingAnswer, isNull);
    expect(await f.session.acknowledgeShown(), isFalse);
    expect(f.session.edit('late input'), isFalse);
    f.session.setActive(false);
    release.complete();
    expect(await pending, SubmitResult.pending);
    expect(f.session.pendingAnswer, isNull);
    expect(await f.session.acknowledgeShown(), isFalse);
    f.session.setActive(true);
    expect(f.session.pendingAnswer, Answer.yes);
    expect(f.session.remainingMs, 0);
  });

  test(
    'restart restores the exact answer with no draw or premature timer',
    () async {
      for (final value in [0, 99]) {
        final f = Fixture();
        f.random.value = value;
        await f.start();
        await f.answer();
        final expected = answerFor(value);
        expect(f.session.pendingAnswer, expected);
        f.clock.advance(cooldownMs * 3);
        await f.start();
        expect(f.session.pendingAnswer, expected);
        expect(f.session.remainingMs, 0);
        expect(f.random.calls, 1);
        expect(f.notifications.pending, isNull);
        expect(await f.session.acknowledgeShown(), isTrue);
        expect(f.session.remainingMs, cooldownMs);
        expect(f.store.record.containsKey('answer'), isFalse);
        expect(
          f.store.writes.every((s) => !s.contains('synthetic fixture')),
          isTrue,
        );
        await f.start();
        expect(f.session.phase, SessionPhase.cooldown);
        expect(f.session.pendingAnswer, isNull);
        expect(f.random.calls, 1);
      }
    },
  );

  for (final commit in [false, true]) {
    test('failed intent write (committed=$commit) never calls RNG', () async {
      final f = Fixture();
      await f.start();
      f.store.failAt = 1;
      f.store.commitBeforeFailure = commit;
      expect(await f.session.confirm(f.prepare()), SubmitResult.failed);
      expect(f.session.phase, SessionPhase.failed);
      expect(f.random.calls, 0);
      await f.start();
      expect(
        f.session.phase,
        commit ? SessionPhase.interrupted : SessionPhase.ready,
      );
      if (commit) {
        expect(f.session.review(), isNull);
        expect(await f.session.dismissInterrupted(), isTrue);
        expect(f.session.phase, SessionPhase.ready);
      }
      expect(f.random.calls, 0);
    });

    test(
      'failed answer write (committed=$commit) cannot reroll on recovery',
      () async {
        final f = Fixture();
        await f.start();
        f.store.failAt = 2;
        f.store.commitBeforeFailure = commit;
        expect(await f.session.confirm(f.prepare()), SubmitResult.failed);
        expect(f.session.phase, SessionPhase.failed);
        expect(f.session.pendingAnswer, isNull);
        expect(f.random.calls, 1);
        await f.start();
        expect(
          f.session.phase,
          commit ? SessionPhase.pending : SessionPhase.interrupted,
        );
        expect(f.session.pendingAnswer, commit ? Answer.yes : null);
        expect(f.random.calls, 1);
        expect(f.session.remainingMs, 0);
      },
    );

    test(
      'failed cooldown write (committed=$commit) recovers conservatively',
      () async {
        final f = Fixture();
        await f.start();
        await f.answer();
        f.store.failAt = 3;
        f.store.commitBeforeFailure = commit;
        expect(await f.session.acknowledgeShown(), isFalse);
        expect(f.session.phase, SessionPhase.failed);
        f.clock.advance(1234);
        await f.start();
        expect(
          f.session.phase,
          commit ? SessionPhase.cooldown : SessionPhase.pending,
        );
        expect(f.random.calls, 1);
        if (commit) {
          expect(f.session.remainingMs, cooldownMs - 1234);
          expect(f.session.pendingAnswer, isNull);
        } else {
          expect(f.session.pendingAnswer, Answer.yes);
          expect(await f.session.acknowledgeShown(), isTrue);
          expect(f.session.remainingMs, cooldownMs);
        }
      },
    );
  }

  test('CSPRNG errors and invalid values do not fabricate an answer or spend attempt', () async {
    for (final value in [null, -1, 100]) {
      final f = Fixture();
      await f.start();
      f.random.fails = value == null;
      f.random.value = value ?? 0;
      expect(await f.session.confirm(f.prepare()), SubmitResult.failed);
      expect(f.session.phase, SessionPhase.ready);
      expect(f.session.pendingAnswer, isNull);
      expect(f.store.record['phase'], 'idle');
      expect(f.notifications.pending, isNull);
      expect(f.session.remainingMs, 0);
    }
  });

  test('failed cleanup after RNG error preserves interruption without automatic retry', () async {
    final f = Fixture();
    await f.start();
    f.random.fails = true;
    f.store.failAt = 2;
    expect(await f.session.confirm(f.prepare()), SubmitResult.failed);
    expect(f.session.phase, SessionPhase.failed);
    await f.start();
    expect(f.session.phase, SessionPhase.interrupted);
    expect(f.random.calls, 1);
    f.store.failAt = 3;
    expect(await f.session.dismissInterrupted(), isFalse);
    expect(f.session.phase, SessionPhase.failed);
    expect(f.store.record['phase'], 'reserved');
  });

  test('cooldown expires at exactly 1800000 ms and duplicate display cannot extend it', () async {
    final f = Fixture();
    await f.start();
    expect(await f.session.acknowledgeShown(), isFalse);
    await f.pause();
    expect(f.session.remainingSeconds, 1800);
    final saved = f.store.value;
    f.clock.advance(cooldownMs - 1);
    expect(await f.session.acknowledgeShown(), isFalse);
    await f.session.refresh();
    expect(f.session.remainingMs, 1);
    expect(f.session.remainingSeconds, 1);
    expect(f.session.edit('during cooldown'), isFalse);
    expect(f.session.review(), isNull);
    expect(f.store.value, saved);
    f.clock.advance(1);
    await f.session.refresh();
    expect(f.session.phase, SessionPhase.ready);
    expect(f.session.remainingMs, 0);
    expect(f.store.record, {'version': 1, 'phase': 'idle'});
    expect(f.notifications.pending, isNull);
    await f.answer();
    expect(f.random.calls, 2);
  });

  test('restart and background include elapsed device sleep', () async {
    final f = Fixture();
    await f.start();
    await f.pause();
    f.session.setActive(false);
    f.clock.advance(750000);
    await f.start();
    expect(f.session.remainingMs, 1050000);
    expect(f.notifications.pending!.remainingMs, 1050000);
    f.session.setActive(false);
    f.clock.advance(1050000);
    f.session.setActive(true);
    await f.session.refresh();
    expect(f.session.phase, SessionPhase.ready);
    expect(f.random.calls, 1);
  });

  test(
    'same-boot wall-clock jumps neither shorten nor lengthen pause',
    () async {
      for (final shift in [-86400000, 86400000]) {
        final f = Fixture();
        await f.start();
        await f.pause();
        f.clock.advance(60000);
        f.clock.utc += shift;
        await f.session.refresh();
        expect(f.session.remainingMs, 1740000);
        expect(f.store.record['utcDeadline'], f.clock.utc + 1740000);
        expect(f.notifications.pending!.remainingMs, 1740000);
        await f.start();
        expect(f.session.remainingMs, 1740000);
      }
    },
  );

  test('new boot uses UTC then rebases to the new continuous clock', () async {
    final f = Fixture();
    await f.start();
    await f.pause();
    f.clock.utc += 600000;
    f.clock.continuous = 10000;
    f.clock.boot = 'test-boot-b';
    await f.start();
    expect(f.session.remainingMs, 1200000);
    expect(f.store.record['bootToken'], 'test-boot-b');
    expect(f.store.record['continuousDeadline'], 1210000);
    // A rebased deadline may be less than 30 minutes since boot. Another
    // process restart must still decode and retain that valid record.
    await f.start();
    expect(f.session.phase, SessionPhase.cooldown);
    expect(f.session.remainingMs, 1200000);
    f.clock.advance(1200000);
    await f.session.refresh();
    expect(f.session.phase, SessionPhase.ready);
  });

  test('reboot fallback is bounded to 30 minutes and cannot prove offline wall time', () async {
    for (final shift in [-86400000, 86400000]) {
      final f = Fixture();
      await f.start();
      await f.pause();
      f.clock.utc += shift;
      f.clock.continuous = 10000;
      f.clock.boot = 'test-boot-b';
      await f.start();
      expect(f.session.remainingMs, shift < 0 ? cooldownMs : 0);
      expect(
        f.session.phase,
        shift < 0 ? SessionPhase.cooldown : SessionPhase.ready,
      );
    }
  });

  test(
    'clock failure or same-boot monotonic regression cannot unlock session',
    () async {
      for (final fault in ['unavailable', 'negative', 'boot', 'regression']) {
        final f = Fixture();
        await f.start();
        await f.pause();
        final saved = f.store.value;
        switch (fault) {
          case 'unavailable':
            f.clock.fails = true;
          case 'negative':
            f.clock.utc = -1;
          case 'boot':
            f.clock.boot = '';
          case 'regression':
            f.clock.continuous -= 1;
        }
        await f.session.refresh();
        expect(f.session.phase, SessionPhase.failed);
        expect(f.store.value, saved);
        expect(f.random.calls, 1);
      }
    },
  );

  test(
    'unavailable clock after display preserves the same pending answer',
    () async {
      final f = Fixture();
      await f.start();
      await f.answer();
      f.clock.fails = true;
      expect(await f.session.acknowledgeShown(), isFalse);
      expect(f.session.phase, SessionPhase.failed);
      await f.start();
      expect(f.session.pendingAnswer, Answer.yes);
      expect(f.random.calls, 1);
    },
  );

  test(
    'expiry persistence failure does not make another attempt available',
    () async {
      final f = Fixture();
      await f.start();
      await f.pause();
      f.store.failAt = 4;
      f.clock.advance(cooldownMs);
      await f.session.refresh();
      expect(f.session.phase, SessionPhase.failed);
      expect(f.session.review(), isNull);
      expect(f.store.record['phase'], 'cooldown');
      await f.start();
      expect(f.session.phase, SessionPhase.ready);
      expect(f.random.calls, 1);
    },
  );

  test(
    'unknown, truncated, extra-field and malformed records fail closed',
    () async {
      final corrupt = [
        '',
        '{',
        'null',
        '[]',
        '{"version":2,"phase":"idle"}',
        '{"version":1.0,"phase":"idle"}',
        '{"version":1,"phase":"unknown"}',
        '{"version":1,"phase":"pending"}',
        '{"version":1,"phase":"pending","answer":"maybe"}',
        '{"version":1,"phase":"idle","question":"forbidden"}',
        '{"version":1,"phase":"cooldown","utcDeadline":-1,"continuousDeadline":0,"bootToken":"a"}',
        '{"version":1,"phase":"cooldown","utcDeadline":1800000,"continuousDeadline":1800000,"bootToken":""}',
        'x' * 1025,
      ];
      for (final raw in corrupt) {
        final f = Fixture();
        f.store.value = raw;
        await f.start();
        expect(f.session.phase, SessionPhase.failed, reason: raw);
        expect(f.session.edit('synthetic fixture'), isFalse);
        expect(f.store.writes, isEmpty);
        expect(f.random.calls, 0);
      }
      final f = Fixture();
      f.store.failRead = true;
      await f.start();
      expect(f.session.phase, SessionPhase.failed);
      expect(f.store.writes, isEmpty);
    },
  );

  test('notification failure never changes the durable deadline', () async {
    final f = Fixture();
    await f.start();
    f.notifications.fails = true;
    await f.pause();
    final saved = f.store.value;
    expect(f.session.phase, SessionPhase.cooldown);
    expect(f.session.notificationFailed, isTrue);
    f.clock.advance(10000);
    await f.start();
    expect(f.session.remainingMs, cooldownMs - 10000);
    expect(f.store.value, saved);
    expect(f.session.notificationFailed, isTrue);
    f.clock.advance(cooldownMs);
    await f.session.refresh();
    expect(f.session.phase, SessionPhase.ready);
    expect(f.session.remainingMs, 0);
  });

  test(
    'restored locale is supplied by preferences, not question persistence',
    () async {
      final f = Fixture();
      await f.start(language: 'en');
      await f.pause();
      expect(f.notifications.pending!.language, 'en');
      await f.start(language: 'en');
      expect(f.notifications.pending!.language, 'en');
      expect(f.store.record.containsKey('language'), isFalse);
      expect(
        () => QuestionSession(
          store: f.store,
          clock: f.clock,
          random: f.random,
          validateQuestion: (_, _) async => Admission.held,
          initialLanguage: 'de',
        ),
        throwsArgumentError,
      );
    },
  );

  test('notification is one replaceable generic request and refresh does not reschedule', () async {
    final f = Fixture();
    await f.start();
    f.session.edit('synthetic fixture', language: 'ru');
    await f.session.confirm(f.session.review()!);
    await f.session.acknowledgeShown();
    expect(
      f.notifications.pending!.body,
      'Вселенная снова готова тебя услышать',
    );
    expect(f.notifications.pending!.remainingMs, cooldownMs);
    expect(f.notifications.schedules, 1);
    f.clock.advance(1000);
    await f.session.refresh();
    expect(f.notifications.schedules, 1);
    await f.start();
    expect(f.notifications.schedules, 2);
    expect(f.notifications.pending!.remainingMs, cooldownMs - 1000);
    expect(
      f.notifications.pending!.body.contains('synthetic fixture'),
      isFalse,
    );
  });
}
