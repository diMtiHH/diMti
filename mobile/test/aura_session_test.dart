import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:universe_lab/aura_answer_page.dart';
import 'package:universe_lab/aura_renderer.dart';
import 'package:universe_lab/cosmic_theme.dart';
import 'package:universe_lab/engine.dart';
import 'package:universe_lab/session_clock_scope.dart';
import 'package:universe_lab/session_page.dart';
import 'package:universe_lab/presentation_profile.dart';
import 'package:universe_lab/voice_input.dart';

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
    'one native animation pattern starts and is cancelled immediately in background',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final events = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('ask_universe/haptics'),
        (call) async {
          expect((call.arguments as Map)['owner'], isA<int>());
          events.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('ask_universe/haptics'),
          null,
        ),
      );
      final backend = TestBackend(), random = TestRandom();
      await show(tester, backend: backend, random: random, diagnostic: true);
      await prepare(tester);
      await tester.pump(const Duration(milliseconds: 2300));
      expect(events.where((event) => event == 'animation'), hasLength(1));
      pauseApp(tester.binding);
      await frames(tester);
      expect(events.last, 'cancel');
      final active = events.where((event) => event != 'cancel').toList();
      await tester.pump(const Duration(seconds: 5));
      expect(events.where((event) => event != 'cancel'), active);
      expect(events, isNot(contains('reveal')));
      expect(jsonDecode(backend.value!)['phase'], 'pending');
      await clean(tester);
    },
  );

  testWidgets(
    'disabled haptics silence the entire sequence while sound cues stay result-neutral',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final vibrations = <String>[], cues = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('ask_universe/haptics'),
        (call) async {
          if (call.method != 'cancel') vibrations.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('ask_universe/haptics'),
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
    'short tap opens text; drag and cancelled hold never request microphone',
    (tester) async {
      final backend = TestBackend(),
          random = TestRandom(),
          voice = PageVoiceBackend();
      await show(tester, backend: backend, random: random, voice: voice);
      final center = tester.getCenter(find.byType(AuraTouchSurface));
      final hold = await tester.startGesture(center);
      await tester.pump(const Duration(milliseconds: 400));
      await hold.cancel();
      await frames(tester);
      expect(find.byType(TextField), findsNothing);
      final drag = await tester.startGesture(center);
      await tester.pump(const Duration(milliseconds: 400));
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
    'stationary hold starts exactly one voice capture only on release',
    (tester) async {
      final backend = TestBackend(),
          random = TestRandom(),
          voice = PageVoiceBackend();
      await show(tester, backend: backend, random: random, voice: voice);
      final center = tester.getCenter(find.byType(AuraTouchSurface));
      final hold = await tester.startGesture(center);
      await tester.pump(const Duration(milliseconds: 400));
      expect(voice.starts, isEmpty);
      expect(find.byType(TextField), findsNothing);
      await hold.up();
      await frames(tester);
      expect(voice.starts, hasLength(1));
      expect(find.byKey(const ValueKey('question-input')), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.focusNode!.hasFocus, isFalse);
      voice.transcript('first phrase');
      await frames(tester);
      expect(field.controller!.text, 'first phrase');
      expect(random.calls, 0);
      expect(backend.writes, 0);
      await clean(tester);
    },
  );

  testWidgets(
    'form geometry survives input and keyboard; outside tap preserves text without extra button',
    (tester) async {
      final backend = TestBackend(), random = TestRandom();
      await show(tester, backend: backend, random: random);
      final bounds = find.byKey(const ValueKey('main-form-bounds'));
      final original = tester.getRect(bounds);
      await tap(tester, find.byType(AuraTouchSurface));
      expect(tester.getRect(bounds), original);
      await tester.enterText(find.byType(TextField), 'private draft');
      tester.view.viewInsets = const FakeViewPadding(bottom: 310);
      addTearDown(tester.view.resetViewInsets);
      await frames(tester);
      expect(tester.getRect(bounds), original);
      expect(find.byKey(const ValueKey('dismiss-keyboard')), findsNothing);
      expect(find.text('Скрыть клавиатуру'), findsNothing);
      await tester.tapAt(tester.getTopLeft(bounds) + const Offset(30, 30));
      await frames(tester);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isFalse,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'private draft',
      );
      tester.view.resetViewInsets();
      await frames(tester);
      expect(tester.getRect(bounds), original);
      expect(tester.takeException(), isNull);
      await clean(tester);
    },
  );

  for (final interruption in ['none', 'background', 'typing']) {
    testWidgets(
      'release finishes before capture; $interruption cannot revive a stale voice intent',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final released = Completer<void>();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('ask_universe/haptics'),
          (call) async {
            if (call.method == 'release') await released.future;
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel('ask_universe/haptics'),
            null,
          ),
        );
        final backend = TestBackend(),
            random = TestRandom(),
            voice = PageVoiceBackend();
        await show(tester, backend: backend, random: random, voice: voice);
        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(AuraTouchSurface)),
        );
        await tester.pump(const Duration(milliseconds: 400));
        await gesture.up();
        await frames(tester, 2);
        expect(voice.starts, isEmpty);
        if (interruption == 'background') {
          pauseApp(tester.binding);
        }
        if (interruption == 'typing') {
          await tester.enterText(find.byType(TextField), 'typed instead');
        }
        released.complete();
        await frames(tester);
        expect(voice.starts.length, interruption == 'none' ? 1 : 0);
        expect(random.calls, 0);
        expect(backend.writes, 0);
        await clean(tester);
      },
    );
  }

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
        await tap(tester, find.byType(AuraTouchSurface));
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
    'diagnostic AURA hold stays visual without voice or a new answer',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final haptics = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('ask_universe/haptics'),
        (call) async {
          haptics.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('ask_universe/haptics'),
          null,
        ),
      );
      final backend = TestBackend(), random = TestRandom();
      final voice = PageVoiceBackend();
      addTearDown(voice.dispose);
      await show(
        tester,
        backend: backend,
        random: random,
        voice: voice,
        diagnostic: true,
      );
      final interaction = tester
          .widget<AuraTouchSurface>(find.byType(AuraTouchSurface))
          .interaction;
      final hold = await tester.startGesture(
        tester.getCenter(find.byType(AuraTouchSurface)),
      );
      await tester.pump(const Duration(milliseconds: 350));
      expect(interaction.hold, greaterThan(0));
      await hold.up();
      await frames(tester);
      expect(tester.takeException(), isNull);
      expect(voice.starts, isEmpty);
      expect(haptics, isNot(contains('hold')));
      expect(haptics, isNot(contains('release')));
      expect(find.byKey(const ValueKey('question-input')), findsNothing);
      expect(find.text('Подготовить тестовый ответ'), findsOneWidget);
      expect(backend.writes, 0);
      expect(random.calls, 0);
      await clean(tester);
    },
  );

  testWidgets(
    'AURA permission alert restores visible voice editor and stop control',
    (tester) async {
      final backend = TestBackend(), random = TestRandom();
      final voice = PageVoiceBackend()
        ..autoListen = false
        ..startGate = Completer<void>();
      await show(tester, backend: backend, random: random, voice: voice);
      final hold = await tester.startGesture(
        tester.getCenter(find.byType(AuraTouchSurface)),
      );
      await tester.pump(const Duration(milliseconds: 350));
      await hold.up();
      await frames(tester);
      final capture = voice.id;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await frames(tester);
      expect(find.byKey(const ValueKey('question-input')), findsNothing);
      expect(voice.cancellations, isNot(contains(capture)));

      resumeApp(tester.binding);
      voice.startGate!.complete();
      voice.emit(VoiceEvent(id: capture, type: VoiceEventType.listening));
      voice.transcript('after explicit permission');
      await frames(tester);
      final editor = tester.widget<TextField>(
        find.byKey(const ValueKey('question-input')),
      );
      expect(editor.controller!.text, 'after explicit permission');
      final microphone = tester.widget<IconButton>(
        find.byKey(const ValueKey('voice-input')),
      );
      expect(microphone.tooltip, 'Остановить запись');
      expect(microphone.onPressed, isNotNull);
      expect(voice.starts, hasLength(1));
      expect(backend.writes, 0);
      expect(random.calls, 0);
      await clean(tester);
    },
  );

  testWidgets(
    'AURA background during permission discards editor and late capture',
    (tester) async {
      final backend = TestBackend(), random = TestRandom();
      final voice = PageVoiceBackend()
        ..autoListen = false
        ..startGate = Completer<void>();
      await show(tester, backend: backend, random: random, voice: voice);
      final hold = await tester.startGesture(
        tester.getCenter(find.byType(AuraTouchSurface)),
      );
      await tester.pump(const Duration(milliseconds: 350));
      await hold.up();
      await frames(tester);
      final capture = voice.id;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      pauseApp(tester.binding);
      await frames(tester);
      voice.startGate!.complete();
      voice.emit(VoiceEvent(id: capture, type: VoiceEventType.listening));
      voice.transcript('must never return');
      resumeApp(tester.binding);
      await frames(tester);
      expect(voice.cancellations, contains(capture));
      expect(find.byKey(const ValueKey('question-input')), findsNothing);
      expect(find.textContaining('must never return'), findsNothing);
      expect(voice.starts, hasLength(1));
      expect(backend.writes, 0);
      expect(random.calls, 0);
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
      await tap(tester, find.byType(AuraTouchSurface));
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
