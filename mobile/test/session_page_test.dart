import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:universe_lab/engine.dart';
import 'package:universe_lab/ios_session.dart';
import 'package:universe_lab/session_core.dart';
import 'package:universe_lab/session_clock_scope.dart';
import 'package:universe_lab/session_page.dart';

class TestBackend implements SessionBackend {
  String? value;
  String language = 'ru';
  String boot = 'test-boot';
  bool enabled = false, denied = false, fails = false;
  bool preferencesFail = false;
  int utc = 1800000000000, continuous = 5000000;
  int writes = 0, resets = 0, schedules = 0;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> replace(String text) async {
    value = text;
    ++writes;
  }

  @override
  Future<ClockSample> readClock() async {
    if (fails) throw StateError('Test failure');
    return ClockSample(utc, continuous, boot);
  }

  @override
  Future<SessionPreferences> preferences() async {
    if (preferencesFail)
      throw StateError('Private error must not be displayed');
    return SessionPreferences(language, enabled);
  }

  @override
  Future<void> setLanguage(String next) async {
    language = next;
  }

  @override
  Future<bool> setNotifications(bool next) async => enabled = next && !denied;
  @override
  Future<void> replaceNotification(PauseNotification request) async {
    if (enabled) ++schedules;
  }

  @override
  Future<void> cancel() async {}
  @override
  Future<void> reconcileNotifications() async {}
  @override
  Future<void> resetDiagnostic() async {
    ++resets;
    value = null;
  }
}

class TestRandom implements AnswerSource {
  int calls = 0;
  @override
  int next100() {
    ++calls;
    return 99;
  }
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
      disableAnimations: true,
    );
  });
  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .clearAccessibilityFeaturesTestValue();
  });
  Widget app(Widget page) => SessionClockScope(child: MaterialApp(home: page));

  Future<void> show(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app(page));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'real input requires confirmation and every model result stays closed',
    (tester) async {
      for (final outcome in Outcome.values) {
        final backend = TestBackend(), random = TestRandom();
        var inspections = 0;
        await show(
          tester,
          SessionPage(
            key: ValueKey(outcome),
            backend: backend,
            random: random,
            inspector: (text, language) async {
              ++inspections;
              return Reading(outcome, 'fixture');
            },
          ),
        );
        await tester.enterText(find.byType(TextField), 'not a real question');
        await tester.pump();
        await tester.tap(find.text('Продолжить'));
        // A second tap before the next frame must not erase the review snapshot.
        await tester.tap(find.text('Продолжить'));
        await tester.pumpAndSettle();
        expect(inspections, 0);
        expect(find.text('Подтверди формулировку'), findsOneWidget);
        await tester.tap(find.text('Подтверждаю'));
        await tester.pumpAndSettle();
        expect(inspections, 1);
        expect(random.calls, 0);
        expect(backend.writes, 0);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
        expect(find.byKey(const ValueKey('answer')), findsNothing);
        expect(find.byKey(const ValueKey('outcome')), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'diagnostic stores before showing and restart never selects again',
    (tester) async {
      final backend = TestBackend(), random = TestRandom();
      Widget page() =>
          SessionPage(diagnostic: true, backend: backend, random: random);
      await show(tester, page());
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('Подготовить тестовый ответ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Подтверждаю'));
      await tester.pumpAndSettle();
      expect(find.text('Показать сохранённый ответ'), findsOneWidget);
      expect(find.byKey(const ValueKey('answer')), findsNothing);
      expect(backend.value, contains('pending'));
      expect(backend.value, isNot(contains(diagnosticFixture)));
      expect(random.calls, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app(page()));
      await tester.pumpAndSettle();
      expect(random.calls, 1);
      expect(find.text('Показать сохранённый ответ'), findsOneWidget);
      await tester.tap(find.text('Показать сохранённый ответ'));
      await tester.pumpAndSettle();
      expect(find.text('НЕТ'), findsOneWidget);
      expect(find.text('1:00'), findsOneWidget);
      expect(find.text('Тестовая пауза — одна минута'), findsOneWidget);
      expect(backend.value, contains('cooldown'));
      expect(backend.value, isNot(contains('answer')));
      backend.utc += 15000;
      backend.continuous += 15000;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app(page()));
      await tester.pumpAndSettle();
      expect(find.text('0:45'), findsOneWidget);
      expect(find.byKey(const ValueKey('answer')), findsNothing);
      expect(random.calls, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final diagnostic in [false, true]) {
    final mode = diagnostic ? 'diagnostic' : 'real';
    testWidgets('$mode reload cannot forget a clock regression', (
      tester,
    ) async {
      final backend = TestBackend(), random = TestRandom();
      final duration = diagnostic ? diagnosticCooldownMs : cooldownMs;
      backend.value = jsonEncode({
        'version': diagnostic ? 2 : 1,
        'phase': 'cooldown',
        'utcDeadline': backend.utc + duration,
        'continuousDeadline': backend.continuous + duration,
        'bootToken': 'test-boot',
        if (diagnostic) 'durationMs': duration,
      });
      await show(
        tester,
        SessionPage(
          diagnostic: diagnostic,
          backend: backend,
          random: random,
          inspector: (_, _) async => const Reading(Outcome.held, 'fixture'),
        ),
      );
      backend.utc += 10000;
      backend.continuous += 10000;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      final timer = diagnostic ? '0:50' : '29:50';
      expect(find.text(timer), findsOneWidget);
      final saved = backend.value, writes = backend.writes;
      final schedules = backend.schedules;

      backend.continuous -= 1;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Повторить загрузку'), findsOneWidget);
      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.tap(find.text('Повторить загрузку'));
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Не удалось получить системное время для таймера. Проверка заблокирована.',
          ),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('answer')), findsNothing);
        expect(find.text('Подготовить тестовый ответ'), findsNothing);
        expect(backend.value, saved);
        expect(backend.writes, writes);
        expect(backend.schedules, schedules);
        expect(random.calls, 0);
      }

      backend.continuous += 1;
      await tester.tap(find.text('Повторить загрузку'));
      await tester.pumpAndSettle();
      expect(find.text(timer), findsOneWidget);
      expect(find.text('Повторить загрузку'), findsNothing);
      expect(backend.value, saved);
      expect(backend.writes, writes);
      expect(random.calls, 0);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final diagnostic in [false, true]) {
    final mode = diagnostic ? 'diagnostic' : 'real';
    testWidgets('$mode recreated screen retains the observed clock', (
      tester,
    ) async {
      final backend = TestBackend(), random = TestRandom();
      final generation = ValueNotifier(0);
      addTearDown(generation.dispose);
      final duration = diagnostic ? diagnosticCooldownMs : cooldownMs;
      backend.value = jsonEncode({
        'version': diagnostic ? 2 : 1,
        'phase': 'cooldown',
        'utcDeadline': backend.utc + duration,
        'continuousDeadline': backend.continuous + duration,
        'bootToken': backend.boot,
        if (diagnostic) 'durationMs': duration,
      });
      await show(
        tester,
        ValueListenableBuilder<int>(
          valueListenable: generation,
          builder: (_, revision, _) => SessionPage(
            key: ValueKey(revision),
            diagnostic: diagnostic,
            backend: backend,
            random: random,
            inspector: (_, _) async => const Reading(Outcome.held, 'fixture'),
          ),
        ),
      );
      backend.utc += 10000;
      backend.continuous += 10000;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      final saved = backend.value, writes = backend.writes;
      final schedules = backend.schedules;
      backend.continuous -= 1;
      for (var attempt = 0; attempt < 2; attempt++) {
        generation.value++;
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Не удалось получить системное время для таймера. Проверка заблокирована.',
          ),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('answer')), findsNothing);
        expect(backend.value, saved);
        expect(backend.writes, writes);
        expect(backend.schedules, schedules);
        expect(random.calls, 0);
      }
      backend.continuous += 1;
      generation.value++;
      await tester.pumpAndSettle();
      expect(find.text(diagnostic ? '0:50' : '29:50'), findsOneWidget);
      expect(backend.value, saved);
      expect(backend.writes, writes);
      expect(random.calls, 0);
      // A genuine new comparison domain still uses bounded UTC recovery.
      backend.boot = 'next-boot';
      backend.utc += 1000;
      backend.continuous = 1000;
      generation.value++;
      await tester.pumpAndSettle();
      expect(find.text(diagnostic ? '0:49' : '29:49'), findsOneWidget);
      expect(random.calls, 0);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('returning to diagnostic route cannot reset clock protection', (
    tester,
  ) async {
    final clock = TestBackend();
    final diagnostic = TestBackend();
    diagnostic.value = jsonEncode({
      'version': 2,
      'phase': 'cooldown',
      'durationMs': diagnosticCooldownMs,
      'utcDeadline': clock.utc + diagnosticCooldownMs,
      'continuousDeadline': clock.continuous + diagnosticCooldownMs,
      'bootToken': clock.boot,
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(IosSessionBackend.channel, (call) async {
      final scope = (call.arguments as Map)['scope'];
      final backend = scope == 'diagnostic' ? diagnostic : clock;
      switch (call.method) {
        case 'preferences':
          return {
            'language': 'ru',
            'notifications': false,
            'englishNotifications': false,
          };
        case 'clock':
          return {
            'utcMs': clock.utc,
            'continuousMs': clock.continuous,
            'bootToken': clock.boot,
          };
        case 'readState':
          return backend.value;
        case 'writeState':
          await backend.replace((call.arguments as Map)['value'] as String);
          return null;
        case 'scheduleNotification':
        case 'cancelNotification':
          return null;
        default:
          throw StateError('Unexpected native call: ${call.method}');
      }
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(IosSessionBackend.channel, null),
    );
    await show(
      tester,
      SessionPage(
        inspector: (_, _) async => const Reading(Outcome.held, 'fixture'),
      ),
    );
    await tester.tap(find.text('Проверка ядра'));
    await tester.pumpAndSettle();
    expect(find.text('1:00'), findsOneWidget);
    clock.utc += 10000;
    clock.continuous += 10000;
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('0:50'), findsOneWidget);
    final saved = diagnostic.value;
    await tester.pageBack();
    await tester.pumpAndSettle();
    clock.continuous -= 1;
    await tester.tap(find.text('Проверка ядра'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Не удалось получить системное время для таймера. Проверка заблокирована.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('answer')), findsNothing);
    expect(diagnostic.value, saved);
    expect(diagnostic.writes, 0);
    expect(clock.value, isNull);
    expect(clock.writes, 0);
    clock.continuous += 1;
    await tester.tap(find.text('Повторить загрузку'));
    await tester.pumpAndSettle();
    expect(find.text('0:50'), findsOneWidget);
    expect(diagnostic.value, saved);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('replacing the Navigator preserves application clock history', (
    tester,
  ) async {
    final backend = TestBackend();
    final generation = ValueNotifier(0);
    addTearDown(generation.dispose);
    await show(
      tester,
      ValueListenableBuilder<int>(
        valueListenable: generation,
        builder: (_, revision, _) => MaterialApp(
          key: ValueKey(revision),
          home: SessionPage(diagnostic: true, backend: backend),
        ),
      ),
    );
    expect(find.text('Подготовить тестовый ответ'), findsOneWidget);
    backend.continuous -= 1;
    generation.value++;
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Не удалось получить системное время для таймера. Проверка заблокирована.',
      ),
      findsOneWidget,
    );
    expect(find.text('Подготовить тестовый ответ'), findsNothing);
    expect(backend.value, isNull);
    expect(backend.writes, 0);
    backend.continuous += 1;
    await tester.tap(find.text('Повторить загрузку'));
    await tester.pumpAndSettle();
    expect(find.text('Подготовить тестовый ответ'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('independent application clock owners do not share history', (
    tester,
  ) async {
    final first = TestBackend(), second = TestBackend();
    second.continuous = 100;
    await show(
      tester,
      Row(
        children: [
          Expanded(
            child: SessionClockScope(
              child: SessionPage(diagnostic: true, backend: first),
            ),
          ),
          Expanded(
            child: SessionClockScope(
              child: SessionPage(diagnostic: true, backend: second),
            ),
          ),
        ],
      ),
    );
    expect(find.text('Подготовить тестовый ответ'), findsNWidgets(2));
    expect(find.text('Повторить загрузку'), findsNothing);
    expect(first.writes, 0);
    expect(second.writes, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('background removes review and requires a new edit', (
    tester,
  ) async {
    final backend = TestBackend();
    await show(
      tester,
      SessionPage(
        backend: backend,
        inspector: (_, _) async => const Reading(Outcome.held, 'fixture'),
      ),
    );
    await tester.enterText(find.byType(TextField), 'private fixture');
    await tester.pump();
    await tester.tap(find.text('Продолжить'));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.text('private fixture'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Подтверждаю'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(backend.writes, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'legacy diagnostic pause stays intact until explicit test reset',
    (tester) async {
      final backend = TestBackend(), random = TestRandom();
      final old = QuestionSession(
        store: backend,
        clock: BackendClock(backend),
        random: random,
        validateQuestion: validateDiagnosticFixture,
      );
      await old.initialize();
      old.edit(diagnosticFixture);
      await old.confirm(old.review()!);
      await old.acknowledgeShown();
      await show(
        tester,
        SessionPage(diagnostic: true, backend: backend, random: random),
      );
      expect(find.text('30:00'), findsOneWidget);
      expect(find.textContaining('Продолжается прежний тест'), findsOneWidget);
      await tester.tap(find.text('Сбросить только тест'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Подготовить тестовый ответ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Подтверждаю'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Показать сохранённый ответ'));
      await tester.pumpAndSettle();
      expect(find.text('1:00'), findsOneWidget);
      expect(backend.resets, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'notification denial cannot start or reset a timer; locale preserves state',
    (tester) async {
      final backend = TestBackend()..denied = true;
      await show(tester, SessionPage(diagnostic: true, backend: backend));
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(find.textContaining('Уведомление недоступно.'), findsOneWidget);
      expect(backend.enabled, isFalse);
      expect(backend.writes, 0);
      await tester.tap(find.text('Подготовить тестовый ответ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Подтверждаю'));
      await tester.pumpAndSettle();
      final saved = backend.value;
      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();
      expect(find.text('Show saved answer'), findsOneWidget);
      expect(backend.value, saved);
      await tester.tap(find.text('Show saved answer'));
      await tester.pumpAndSettle();
      expect(find.text('1:00'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('unavailable clock blocks input with a visible retry', (
    tester,
  ) async {
    final backend = TestBackend()..fails = true;
    final random = TestRandom();
    await show(
      tester,
      SessionPage(diagnostic: true, backend: backend, random: random),
    );
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Повторить загрузку'), findsOneWidget);
    expect(find.textContaining('системное время для таймера'), findsOneWidget);
    expect(find.textContaining('модель'), findsNothing);
    expect(random.calls, 0);
    expect(backend.writes, 0);
    backend.fails = false;
    await tester.tap(find.text('Повторить загрузку'));
    await tester.pumpAndSettle();
    expect(find.text('Подготовить тестовый ответ'), findsOneWidget);
    expect(random.calls, 0);
    expect(backend.writes, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('settings failure is specific and reveals no exception details', (
    tester,
  ) async {
    await show(
      tester,
      SessionPage(
        diagnostic: true,
        backend: TestBackend()..preferencesFail = true,
      ),
    );
    expect(find.textContaining('прочитать настройки'), findsOneWidget);
    expect(find.textContaining('Private error'), findsNothing);
    expect(find.textContaining('модель'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('small screen and large text keep confirmation reachable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      SessionClockScope(
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: SessionPage(
            backend: TestBackend(),
            inspector: (_, _) async => const Reading(Outcome.held, 'fixture'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'Стоит ли мне сегодня почитать роман?',
    );
    await tester.pump();
    await tester.ensureVisible(find.text('Продолжить'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Продолжить'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Подтверждаю'));
    await tester.tap(find.text('Подтверждаю'));
    await tester.pumpAndSettle();
    expect(find.text('Проверка завершена. Допуск закрыт.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'diagnostic validator rejects arbitrary questions and unknown language',
    () async {
      expect(
        await validateDiagnosticFixture('personal question', 'ru'),
        Admission.held,
      );
      expect(
        await validateDiagnosticFixture(diagnosticFixture, 'de'),
        Admission.held,
      );
      expect(
        await validateDiagnosticFixture(diagnosticFixture, 'en'),
        Admission.allowed,
      );
    },
  );

  test(
    'native bridge scopes storage and rejects real reset before platform call',
    () async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(IosSessionBackend.channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'clock')
          return {'utcMs': 10, 'continuousMs': 20, 'bootToken': 'fixture'};
        return null;
      });
      addTearDown(
        () =>
            messenger.setMockMethodCallHandler(IosSessionBackend.channel, null),
      );
      const real = IosSessionBackend(),
          diagnostic = IosSessionBackend(diagnostic: true);
      await real.read();
      await diagnostic.read();
      expect(calls[0].arguments['scope'], 'real');
      expect(calls[1].arguments['scope'], 'diagnostic');
      await expectLater(real.resetDiagnostic(), throwsStateError);
      expect(calls, hasLength(2));
      final clock = await diagnostic.readClock();
      expect(clock.continuousMs, 20);
    },
  );
}
