import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:integration_test/integration_test.dart';
import 'package:universe_lab/ios_session.dart';
import 'package:universe_lab/session_core.dart';

class OneDraw implements AnswerSource {
  int calls = 0;
  @override
  int next100() {
    ++calls;
    return 99;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native iOS storage, clock and notification cancellation preserve recovery',
    (tester) async {
      const real = IosSessionBackend();
      const backend = IosSessionBackend(diagnostic: true);
      final originalReal = await real.read();
      await backend.resetDiagnostic();
      expect(await backend.setNotifications(false), isFalse);
      final firstClock = await backend.readClock();
      expect(
        firstClock.bootToken,
        anyOf(startsWith('semaphore-v1:'), startsWith('boottime-v1:')),
      );
      expect((await real.readClock()).bootToken, firstClock.bootToken);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final nextClock = await backend.readClock();
      expect(nextClock.bootToken, firstClock.bootToken);
      expect(nextClock.continuousMs, greaterThan(firstClock.continuousMs));
      final random = OneDraw();
      QuestionSession create() => QuestionSession(
        diagnostic: true,
        store: backend,
        clock: const BackendClock(backend),
        random: random,
        validateQuestion: validateDiagnosticFixture,
        notifications: const BackendNotifications(backend),
      );
      var session = create();
      await session.initialize();
      expect(session.phase, SessionPhase.ready);
      session.edit(diagnosticFixture);
      expect(await session.confirm(session.review()!), SubmitResult.pending);
      session = create();
      await session.initialize();
      expect(session.pendingAnswer, Answer.no);
      expect(random.calls, 1);
      expect(await session.acknowledgeShown(), isTrue);
      final raw = await backend.read();
      expect(raw, isNot(contains('answer')));
      expect(raw, isNot(contains(diagnosticFixture)));
      session = create();
      await session.initialize();
      expect(session.phase, SessionPhase.cooldown);
      expect(
        session.remainingMs,
        inInclusiveRange(50000, diagnosticCooldownMs),
      );
      expect(session.currentPauseDurationMs, diagnosticCooldownMs);
      await expectLater(real.replace(raw!), throwsA(isA<PlatformException>()));
      expect(await real.read(), originalReal);
      await backend.setLanguage('en');
      expect((await backend.preferences()).language, 'en');
      await backend.setLanguage('ru');
      expect(await real.read(), originalReal);
      await expectLater(real.resetDiagnostic(), throwsStateError);
      await backend.resetDiagnostic();
      expect(await real.read(), originalReal);
    },
  );

  testWidgets(
    'native invalid records and malformed settings preserve saved state',
    (tester) async {
      const real = IosSessionBackend();
      const diagnostic = IosSessionBackend(diagnostic: true);
      final originalReal = await real.read();
      await diagnostic.resetDiagnostic();
      await diagnostic.setNotifications(false);
      final clock = await diagnostic.readClock();
      final savedPause = jsonEncode({
        'version': 2,
        'phase': 'cooldown',
        'durationMs': diagnosticCooldownMs,
        'utcDeadline': clock.utcMs + diagnosticCooldownMs,
        'continuousDeadline': clock.continuousMs + diagnosticCooldownMs,
        'bootToken': clock.bootToken,
      });
      await diagnostic.replace(savedPause);
      final before = await diagnostic.read();
      for (final bad in [
        '{"version":true,"phase":"idle"}',
        '{"version":1.0,"phase":"idle"}',
        '{"version":1e0,"phase":"idle"}',
        '{"version":1,"phase":"idle","phase":"reserved"}',
        r'{"version":1,"\u0076ersion":1,"phase":"idle"}',
        '{"version":1,"phase":"idle","question":"fixture-only"}',
        savedPause.replaceFirst('60000', '60000.0'),
        ' ' * 2049,
        '{',
      ]) {
        await expectLater(
          diagnostic.replace(bad),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'fixed error code',
              'invalid_state',
            ),
          ),
        );
        expect(await diagnostic.read(), before);
        expect(await real.read(), originalReal);
      }
      final prefs = await diagnostic.preferences();
      for (final arguments in [
        {'scope': 'diagnostic', 'enabled': 1},
        {'scope': 'diagnostic', 'enabled': 'true'},
        {'scope': '../real', 'enabled': false},
      ]) {
        await expectLater(
          IosSessionBackend.channel.invokeMethod<bool>(
            'setNotifications',
            arguments,
          ),
          throwsA(isA<PlatformException>()),
        );
      }
      expect(
        (await diagnostic.preferences()).notifications,
        prefs.notifications,
      );
      expect(await diagnostic.read(), before);
      await expectLater(
        IosSessionBackend.channel.invokeMethod<void>('resetDiagnostic', {
          'scope': 'real',
        }),
        throwsA(isA<PlatformException>()),
      );
      expect(await real.read(), originalReal);
      await diagnostic.resetDiagnostic();
      expect(await real.read(), originalReal);
    },
  );
}
