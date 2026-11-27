import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:universe_lab/engine.dart';
import 'package:universe_lab/ios_session.dart';
import 'package:universe_lab/session_clock_scope.dart';
import 'package:universe_lab/session_core.dart';
import 'package:universe_lab/session_page.dart';

class DelayedLanguageBackend implements SessionBackend {
  final firstClock = Completer<ClockSample>();
  String language = 'ru';
  int preferenceReads = 0, clockReads = 0, writes = 0;
  static const clock = ClockSample(1800000000000, 5000000, 'language-test');

  @override
  Future<SessionPreferences> preferences() async {
    ++preferenceReads;
    return SessionPreferences(language, false);
  }

  @override
  Future<ClockSample> readClock() async {
    if (++clockReads == 1) return firstClock.future;
    return clock;
  }

  @override
  Future<String?> read() async => null;
  @override
  Future<void> replace(String value) async { ++writes; }
  @override
  Future<void> setLanguage(String value) async { language = value; }
  @override
  Future<bool> setNotifications(bool enabled) async => false;
  @override
  Future<void> replaceNotification(PauseNotification request) async {}
  @override
  Future<void> cancel() async {}
  @override
  Future<void> reconcileNotifications() async {}
  @override
  Future<void> resetDiagnostic() async {}
}

class NoLanguageDraw implements AnswerSource {
  int calls = 0;
  @override
  int next100() { ++calls; return 49; }
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
      disableAnimations: true,
    );
  });
  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .clearAccessibilityFeaturesTestValue();
  });

  for (final oldClockFails in [false, true]) {
    testWidgets(
      'language revision during loading reloads latest preferences (stale error=$oldClockFails)',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final backend = DelayedLanguageBackend(), random = NoLanguageDraw();
        final inspectedLanguages = <String>[];
        Widget app(int revision) => SessionClockScope(
          child: MaterialApp(
            home: SessionPage(
              key: const ValueKey('same-session'),
              embedded: true,
              languageRevision: revision,
              backend: backend,
              random: random,
              inspector: (_, language) async {
                inspectedLanguages.add(language);
                return const Reading(Outcome.held, 'fixture');
              },
            ),
          ),
        );
        await tester.pumpWidget(app(0));
        await tester.pump();
        expect(backend.preferenceReads, 1);
        expect(backend.clockReads, 1);
        backend.language = 'en';
        await tester.pumpWidget(app(1));
        if (oldClockFails) {
          // Coalesce multiple shell updates while one old native call waits.
          backend.language = 'ru';
          await tester.pumpWidget(app(2));
          backend.language = 'en';
          await tester.pumpWidget(app(3));
          backend.firstClock.completeError(StateError('old clock request failed'));
        } else {
          backend.firstClock.complete(DelayedLanguageBackend.clock);
        }
        await tester.pumpAndSettle();
        expect(backend.preferenceReads, 2);
        expect(find.text('Your question'), findsOneWidget);
        expect(find.text('Твой вопрос'), findsNothing);
        expect(find.text('Retry loading'), findsNothing);

        await tester.enterText(find.byType(TextField), 'language fixture');
        await tester.pump();
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Confirm'));
        await tester.pumpAndSettle();
        expect(inspectedLanguages, ['en']);
        expect(find.text('Check complete. Admission is closed.'), findsOneWidget);
        expect(random.calls, 0);
        expect(backend.writes, 0);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
