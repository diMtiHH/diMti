import 'package:flutter_test/flutter_test.dart';
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
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final nextClock = await backend.readClock();
      expect(nextClock.bootToken, firstClock.bootToken);
      expect(nextClock.continuousMs, greaterThan(firstClock.continuousMs));
      final random = OneDraw();
      QuestionSession create() => QuestionSession(
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
      expect(session.remainingMs, inInclusiveRange(1700000, cooldownMs));
      await backend.setLanguage('en');
      expect((await backend.preferences()).language, 'en');
      await backend.setLanguage('ru');
      expect(await real.read(), originalReal);
      await expectLater(real.resetDiagnostic(), throwsStateError);
      await backend.resetDiagnostic();
      expect(await real.read(), originalReal);
    },
  );
}
