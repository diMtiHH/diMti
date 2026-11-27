import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:universe_lab/aura_answer_page.dart';
import 'package:universe_lab/aura_renderer.dart';
import 'package:universe_lab/cosmic_theme.dart';
import 'package:universe_lab/engine.dart';
import 'package:universe_lab/session_clock_scope.dart';
import 'package:universe_lab/session_page.dart';
import 'package:universe_lab/presentation_profile.dart';

import 'session_page_test.dart' show TestBackend, TestRandom;
import 'voice_page_test.dart' show PageVoiceBackend, pauseApp, resumeApp;

class FailingRevealBackend extends TestBackend {
  bool rejectReveal = false;
  @override
  Future<void> replace(String text) async {
    if (rejectReveal && jsonDecode(text)['phase'] == 'cooldown')
      throw StateError('fixture');
    await super.replace(text);
  }
}

void main() {
  setUp(() {
    resumeApp(TestWidgetsFlutterBinding.ensureInitialized());
  });
  Future<void> frames(WidgetTester tester, [int count = 5]) async {
    for (var i = 0; i < count; ++i) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<void> show(
    WidgetTester tester, {
    required TestBackend backend,
    required TestRandom random,
    bool diagnostic = false,
    PageVoiceBackend? voice,
    Future<Reading> Function(String, String)? inspect,
    Key? pageKey,
    PresentationProfile? appearance,
    ValueChanged<String>? onFeedback,
  }) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      SessionClockScope(
        child: MaterialApp(
          theme: cosmicTheme,
          home: SessionPage(
            key: pageKey,
            aura: true,
            appearance: appearance,
            onFeedback: onFeedback,
            diagnostic: diagnostic,
            backend: backend,
            random: random,
            voiceBackend: voice ?? PageVoiceBackend(),
            inspector:
                inspect ??
                (_, __) async => const Reading(Outcome.held, 'fixture'),
          ),
        ),
      ),
    );
    await frames(tester);
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await frames(tester);
  }

  Future<void> prepare(WidgetTester tester) async {
    await tap(tester, find.text('Подготовить тестовый ответ'));
    await tap(tester, find.byKey(const ValueKey('confirm-question')));
  }

  Future<void> reveal(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 4600));
    await frames(tester, 2);
    await tester.pump(const Duration(milliseconds: 600));
    await frames(tester);
  }

  Future<void> clean(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await frames(tester, 1);
  }

  testWidgets(
    'sequence haptics follow animation milestones and stop immediately in background',
    (tester) async {
      final events = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate')
            events.add(call.arguments as String);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final backend = TestBackend(), random = TestRandom();
      await show(tester, backend: backend, random: random, diagnostic: true);
      await prepare(tester);
      await tester.pump(const Duration(milliseconds: 2300));
      expect(
        events.where((event) => event.endsWith('lightImpact')),
        hasLength(1),
      );
      pauseApp(tester.binding);
      await frames(tester);
      final count = events.length;
      await tester.pump(const Duration(seconds: 5));
      expect(events, hasLength(count));
      expect(jsonDecode(backend.value!)['phase'], 'pending');
      await clean(tester);
    },
  );

  testWidgets(
    'disabled haptics silence the entire sequence while sound cues stay result-neutral',
    (tester) async {
      final vibrations = <String>[], cues = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate')
            vibrations.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final backend = TestBackend(), random = TestRandom();
      await show(
        tester,
        backend: backend,
        random: random,
        diagnostic: true,
        appearance: const PresentationProfile.defaults().copyWith(
          hapticsEnabled: false,
        ),
        onFeedback: cues.add,
      );
      await prepare(tester);
      await tester.pump(const Duration(milliseconds: 2300));
      await tester.pump(const Duration(milliseconds: 1600));
      await tester.pump(const Duration(milliseconds: 700));
      await frames(tester);
      await tester.pump(const Duration(milliseconds: 600));
      await frames(tester);
      expect(vibrations, isEmpty);
      expect(cues.where((event) => event == 'transform'), hasLength(1));
      expect(cues.where((event) => event == 'reveal'), hasLength(1));
      expect(
        cues.every((event) => ['touch', 'transform', 'reveal'].contains(event)),
        true,
      );
      await clean(tester);
    },
  );

  testWidgets(
    'short tap opens text, hold and drag never request microphone or submit',
    (tester) async {
      final backend = TestBackend(),
          random = TestRandom(),
          voice = PageVoiceBackend();
      await show(tester, backend: backend, random: random, voice: voice);
      final center = tester.getCenter(find.byType(AuraTouchSurface));
      final hold = await tester.startGesture(center);
      await tester.pump(const Duration(milliseconds: 700));
      await hold.up();
      await frames(tester);
      expect(find.byType(TextField), findsNothing);
      final drag = await tester.startGesture(center);
      await drag.moveBy(const Offset(55, -40));
      await drag.up();
      await frames(tester);
      expect(find.byType(TextField), findsNothing);
      await tester.tapAt(center);
      await frames(tester);
      expect(find.byKey(const ValueKey('question-input')), findsOneWidget);
      expect(voice.starts, isEmpty);
      expect(random.calls, 0);
      expect(backend.writes, 0);
      await tap(tester, find.byKey(const ValueKey('voice-input')));
      expect(voice.starts, hasLength(1));
      await clean(tester);
    },
  );

  testWidgets(
    'AURA confirmation preserves wording and every production outcome stays closed',
    (tester) async {
      for (final outcome in Outcome.values) {
        final backend = TestBackend(), random = TestRandom();
        var inspections = 0;
        await show(
          tester,
          backend: backend,
          random: random,
          pageKey: ValueKey(outcome),
          inspect: (text, language) async {
            ++inspections;
            return Reading(outcome, 'fixture');
          },
        );
        await tap(tester, find.byKey(const ValueKey('ask-question')));
        const question = 'Стоит ли мне сегодня почитать роман?';
        await tester.enterText(
          find.byKey(const ValueKey('question-input')),
          question,
        );
        await frames(tester);
        await tap(tester, find.text('Продолжить'));
        expect(find.text(question), findsOneWidget);
        expect(inspections, 0);
        await tap(tester, find.text('Изменить вопрос'));
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          question,
        );
        await tap(tester, find.text('Продолжить'));
        await tap(tester, find.byKey(const ValueKey('confirm-question')));
        await tester.pump(const Duration(seconds: 6));
        await frames(tester);
        expect(inspections, 1);
        expect(random.calls, 0);
        expect(backend.writes, 0);
        expect(find.byType(AuraAnswerPage), findsNothing);
        expect(find.byKey(const ValueKey('outcome')), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          question,
        );
        expect(tester.takeException(), isNull);
        await clean(tester);
      }
    },
  );

  testWidgets(
    'durable pending precedes animation; cooldown starts only after visible answer frame',
    (tester) async {
      final backend = TestBackend()..enabled = true, random = TestRandom();
      await show(tester, backend: backend, random: random, diagnostic: true);
      await prepare(tester);
      expect(jsonDecode(backend.value!)['phase'], 'pending');
      expect(backend.schedules, 0);
      expect(random.calls, 1);
      expect(find.byKey(const ValueKey('answer')), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      expect(jsonDecode(backend.value!)['phase'], 'pending');
      backend.utc += 4000;
      backend.continuous += 4000;
      await tester.pump(const Duration(milliseconds: 600));
      await tester
          .pump(); // Route's initially transparent answer is not a shown frame.
      expect(jsonDecode(backend.value!)['phase'], 'pending');
      await tester.pump(const Duration(milliseconds: 100));
      await frames(tester);
      expect(find.byType(AuraAnswerPage), findsOneWidget);
      final stored = jsonDecode(backend.value!) as Map;
      expect(stored['phase'], 'cooldown');
      expect(stored['utcDeadline'], backend.utc + 60000);
      expect(stored.containsKey('answer'), false);
      expect(backend.schedules, 1);
      expect(random.calls, 1);
      expect(tester.takeException(), isNull);
      await clean(tester);
    },
  );

  testWidgets(
    'background aborts animation and resumed pending reuses exactly the saved answer',
    (tester) async {
      final backend = TestBackend(), random = TestRandom();
      await show(tester, backend: backend, random: random, diagnostic: true);
      await prepare(tester);
      final pending = backend.value;
      await tester.pump(const Duration(seconds: 1));
      pauseApp(tester.binding);
      await frames(tester);
      await tester.pump(const Duration(seconds: 10));
      expect(backend.value, pending);
      expect(find.byKey(const ValueKey('answer')), findsNothing);
      resumeApp(tester.binding);
      await frames(tester);
      await reveal(tester);
      expect(jsonDecode(backend.value!)['phase'], 'cooldown');
      expect(random.calls, 1);
      expect(find.byType(AuraAnswerPage), findsOneWidget);
      await clean(tester);
    },
  );

  testWidgets(
    'foreground re-view keeps answer/deadline; background erases re-view without clearing pause',
    (tester) async {
      final backend = TestBackend(), random = TestRandom();
      await show(tester, backend: backend, random: random, diagnostic: true);
      await prepare(tester);
      await reveal(tester);
      final saved = backend.value,
          answer = tester
              .widget<Text>(find.byKey(const ValueKey('answer')))
              .data;
      await tap(tester, find.byKey(const ValueKey('close-answer')));
      backend.utc += 1000;
      backend.continuous += 1000;
      await tap(tester, find.byKey(const ValueKey('view-answer')));
      await tester.pump(const Duration(milliseconds: 600));
      await frames(tester);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('answer'))).data,
        answer,
      );
      expect(backend.value, saved);
      expect(random.calls, 1);
      pauseApp(tester.binding);
      await frames(tester);
      resumeApp(tester.binding);
      await frames(tester);
      expect(find.byKey(const ValueKey('answer')), findsNothing);
      expect(find.byKey(const ValueKey('view-answer')), findsNothing);
      expect(find.byKey(const ValueKey('cooldown')), findsOneWidget);
      expect(backend.value, saved);
      await clean(tester);
    },
  );

  testWidgets(
    'cold restart preserves pending but never recovers a shown answer or question',
    (tester) async {
      final backend = TestBackend(), random = TestRandom();
      await show(tester, backend: backend, random: random, diagnostic: true);
      await prepare(tester);
      await clean(tester);
      await show(tester, backend: backend, random: random, diagnostic: true);
      await reveal(tester);
      expect(random.calls, 1);
      expect(find.byKey(const ValueKey('answer-question')), findsNothing);
      final cooldown = backend.value;
      await clean(tester);
      await show(tester, backend: backend, random: random, diagnostic: true);
      expect(find.byType(AuraAnswerPage), findsNothing);
      expect(find.byKey(const ValueKey('view-answer')), findsNothing);
      expect(find.byKey(const ValueKey('cooldown')), findsOneWidget);
      expect(backend.value, cooldown);
      expect(random.calls, 1);
      await clean(tester);
    },
  );

  testWidgets(
    'late validation cannot resurrect private input after leaving foreground',
    (tester) async {
      final backend = TestBackend(),
          random = TestRandom(),
          result = Completer<Reading>();
      await show(
        tester,
        backend: backend,
        random: random,
        inspect: (_, __) => result.future,
      );
      await tap(tester, find.byKey(const ValueKey('ask-question')));
      await tester.enterText(
        find.byType(TextField),
        'private synthetic wording',
      );
      await frames(tester);
      await tap(tester, find.text('Продолжить'));
      await tap(tester, find.byKey(const ValueKey('confirm-question')));
      pauseApp(tester.binding);
      await frames(tester);
      resumeApp(tester.binding);
      await frames(tester);
      result.complete(const Reading(Outcome.held, 'fixture'));
      await frames(tester);
      expect(find.textContaining('private synthetic'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(backend.writes, 0);
      expect(random.calls, 0);
      await clean(tester);
    },
  );

  testWidgets(
    'failed reveal persistence blocks and closes the private route without another draw',
    (tester) async {
      final backend = FailingRevealBackend(), random = TestRandom();
      await show(tester, backend: backend, random: random, diagnostic: true);
      await prepare(tester);
      backend.rejectReveal = true;
      await reveal(tester);
      await frames(tester);
      expect(jsonDecode(backend.value!)['phase'], 'pending');
      expect(find.byType(AuraAnswerPage), findsNothing);
      expect(random.calls, 1);
      expect(
        find.textContaining('Новая попытка заблокирована'),
        findsOneWidget,
      );
      await clean(tester);
    },
  );
}
