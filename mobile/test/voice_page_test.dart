import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:universe_lab/engine.dart';
import 'package:universe_lab/session_clock_scope.dart';
import 'package:universe_lab/session_core.dart';
import 'package:universe_lab/session_page.dart';
import 'package:universe_lab/voice_input.dart';
import 'package:universe_lab/voice_star.dart';

import 'session_page_test.dart' show TestBackend, TestRandom;

class PageVoiceBackend implements VoiceBackend {
  final _events = StreamController<VoiceEvent>.broadcast(sync: true);
  final starts = <({int id, String language})>[];
  final stops = <int>[];
  final cancellations = <int>[];
  Completer<void>? startGate;
  Object? startFailure;
  bool autoListen = true, disposed = false;

  @override
  Stream<VoiceEvent> get events => _events.stream;

  int get id => starts.last.id;

  void emit(VoiceEvent event) {
    if (!disposed) _events.add(event);
  }

  void transcript(String text, {int? capture}) => emit(
    VoiceEvent(id: capture ?? id, type: VoiceEventType.transcript, text: text),
  );

  @override
  Future<void> start({required int id, required String language}) async {
    starts.add((id: id, language: language));
    if (startFailure != null) throw startFailure!;
    if (autoListen) emit(VoiceEvent(id: id, type: VoiceEventType.listening));
    final gate = startGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> stop({required int id}) async => stops.add(id);

  @override
  Future<void> cancel({required int id}) async => cancellations.add(id);

  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    unawaited(_events.close());
  }
}

class VoicePageFixture {
  final store = TestBackend();
  final voice = PageVoiceBackend();
  final random = TestRandom();
  final inspections = <({String text, String language})>[];

  SessionPage page({bool diagnostic = false}) => SessionPage(
    diagnostic: diagnostic,
    backend: store,
    voiceBackend: voice,
    random: random,
    inspector: (text, language) async {
      inspections.add((text: text, language: language));
      return const Reading(Outcome.held, 'synthetic voice fixture');
    },
  );
}

void resumeApp(TestWidgetsFlutterBinding binding) {
  if (binding.lifecycleState == AppLifecycleState.paused) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }
  if (binding.lifecycleState == AppLifecycleState.hidden) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  }
  binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void pauseApp(TestWidgetsFlutterBinding binding) {
  if (binding.lifecycleState != AppLifecycleState.inactive) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  }
  binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
}

void main() {
  setUp(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    resumeApp(binding);
  });
  tearDown(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    resumeApp(binding);
    binding.platformDispatcher.clearAccessibilityFeaturesTestValue();
  });

  Future<void> show(
    WidgetTester tester,
    VoicePageFixture f, {
    bool diagnostic = false,
  }) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(f.voice.dispose);
    await tester.pumpWidget(
      SessionClockScope(
        child: MaterialApp(home: f.page(diagnostic: diagnostic)),
      ),
    );
    await tester.pumpAndSettle();
  }

  String draft(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  FilledButton continueButton(WidgetTester tester, {bool english = false}) =>
      tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, english ? 'Continue' : 'Продолжить'),
      );

  Future<void> start(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('voice-star')));
    await tester.pumpAndSettle();
  }

  Future<void> disposePage(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  for (final language in ['ru', 'en']) {
    testWidgets(
      '$language voice needs stop and confirmation; admission stays closed',
      (tester) async {
        final f = VoicePageFixture()..store.language = language;
        final english = language == 'en';
        await show(tester, f);
        await start(tester);
        expect(f.voice.starts.single.language, language);
        f.voice.transcript('synthetic partial');
        f.voice.emit(
          VoiceEvent(id: f.voice.id, type: VoiceEventType.level, level: 0.7),
        );
        await tester.pumpAndSettle();
        expect(draft(tester), 'synthetic partial');
        expect(tester.widget<VoiceStar>(find.byType(VoiceStar)).level, 0.7);
        expect(continueButton(tester, english: english).onPressed, isNull);
        expect(f.inspections, isEmpty);

        await tester.tap(find.byKey(const ValueKey('voice-star')));
        await tester.pumpAndSettle();
        expect(f.voice.stops, [f.voice.id]);
        expect(continueButton(tester, english: english).onPressed, isNull);
        f.voice.transcript('synthetic final');
        f.voice.emit(VoiceEvent(id: f.voice.id, type: VoiceEventType.finished));
        await tester.pumpAndSettle();
        expect(draft(tester), 'synthetic final');
        expect(f.inspections, isEmpty);
        await tester.tap(find.text(english ? 'Continue' : 'Продолжить'));
        await tester.pumpAndSettle();
        expect(f.inspections, isEmpty);
        expect(find.text('synthetic final'), findsOneWidget);
        await tester.tap(find.text(english ? 'Confirm' : 'Подтверждаю'));
        await tester.pumpAndSettle();
        expect(f.inspections, [(text: 'synthetic final', language: language)]);
        expect(
          find.text(
            english
                ? 'Check complete. Admission is closed.'
                : 'Проверка завершена. Допуск закрыт.',
          ),
          findsOneWidget,
        );
        expect(f.random.calls, 0);
        expect(f.store.writes, 0);
        expect(find.byKey(const ValueKey('answer')), findsNothing);
        expect(find.byKey(const ValueKey('cooldown')), findsNothing);
        await disposePage(tester);
      },
    );
  }

  testWidgets(
    'explicit voice cancel restores the prior typed draft and ignores late events',
    (tester) async {
      final f = VoicePageFixture();
      await show(tester, f);
      await tester.enterText(find.byType(TextField), 'original typed draft');
      await start(tester);
      final capture = f.voice.id;
      f.voice.transcript('temporary recognition');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отменить запись'));
      await tester.pumpAndSettle();
      expect(f.voice.cancellations, contains(capture));
      expect(draft(tester), 'original typed draft');
      f.voice.transcript('late private text', capture: capture);
      f.voice.emit(VoiceEvent(id: capture, type: VoiceEventType.finished));
      await tester.pumpAndSettle();
      expect(draft(tester), 'original typed draft');
      expect(f.inspections, isEmpty);
      expect(f.random.calls, 0);
      expect(f.store.writes, 0);
      await disposePage(tester);
    },
  );

  testWidgets(
    'manual edit ends voice ownership and survives a late final result',
    (tester) async {
      final f = VoicePageFixture();
      await show(tester, f);
      await start(tester);
      final capture = f.voice.id;
      f.voice.transcript('speech draft');
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'edited by user');
      await tester.pumpAndSettle();
      f.voice.transcript('late result', capture: capture);
      f.voice.emit(VoiceEvent(id: capture, type: VoiceEventType.finished));
      await tester.pumpAndSettle();
      expect(f.voice.cancellations, contains(capture));
      expect(draft(tester), 'edited by user');
      expect(continueButton(tester).onPressed, isNotNull);
      expect(f.inspections, isEmpty);
      await disposePage(tester);
    },
  );

  testWidgets(
    'background clears voice text and resume never restarts the microphone',
    (tester) async {
      final f = VoicePageFixture();
      await show(tester, f);
      await start(tester);
      final capture = f.voice.id;
      f.voice.transcript('temporary private text');
      await tester.pumpAndSettle();
      pauseApp(tester.binding);
      await tester.pumpAndSettle();
      expect(f.voice.cancellations, contains(capture));
      expect(find.text('temporary private text'), findsNothing);
      f.voice.transcript('late private text', capture: capture);
      f.voice.emit(VoiceEvent(id: capture, type: VoiceEventType.listening));
      resumeApp(tester.binding);
      await tester.pumpAndSettle();
      expect(draft(tester), isEmpty);
      expect(f.voice.starts, hasLength(1));
      expect(continueButton(tester).onPressed, isNull);
      expect(f.inspections, isEmpty);
      expect(f.store.writes, 0);
      await disposePage(tester);
    },
  );

  testWidgets(
    'language change cancels the old capture and selects the next locale',
    (tester) async {
      final f = VoicePageFixture();
      await show(tester, f);
      await start(tester);
      final old = f.voice.id;
      f.voice.transcript('old language');
      await tester.pumpAndSettle();
      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();
      f.voice.transcript('late old language', capture: old);
      await tester.pumpAndSettle();
      expect(f.voice.cancellations, contains(old));
      expect(draft(tester), isEmpty);
      expect(f.voice.starts, hasLength(1));
      await start(tester);
      expect(f.voice.starts.last.language, 'en');
      expect(f.voice.id, isNot(old));
      expect(f.inspections, isEmpty);
      await disposePage(tester);
    },
  );

  for (final code in ['permissionDenied', 'unavailable']) {
    testWidgets('$code leaves manual input and closed confirmation available', (
      tester,
    ) async {
      final f = VoicePageFixture();
      f.voice.startFailure = PlatformException(
        code: code,
        message: 'private detail',
      );
      await show(tester, f);
      await start(tester);
      expect(find.textContaining('private detail'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      expect(
        find.textContaining('написать вопрос'),
        code == 'permissionDenied' ? findsOneWidget : findsNothing,
      );
      await tester.enterText(find.byType(TextField), 'manual fallback');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Продолжить'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Подтверждаю'));
      await tester.pumpAndSettle();
      expect(f.inspections.single.text, 'manual fallback');
      expect(f.random.calls, 0);
      expect(f.store.writes, 0);
      await disposePage(tester);
    });
  }

  testWidgets(
    'permission dialog inactivity can finish only after returning active',
    (tester) async {
      final f = VoicePageFixture();
      f.voice.autoListen = false;
      f.voice.startGate = Completer<void>();
      await show(tester, f);
      await start(tester);
      final capture = f.voice.id;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(f.voice.cancellations, isNot(contains(capture)));
      resumeApp(tester.binding);
      f.voice.startGate!.complete();
      await tester.pumpAndSettle();
      f.voice.emit(VoiceEvent(id: capture, type: VoiceEventType.listening));
      f.voice.transcript('after explicit permission');
      await tester.pumpAndSettle();
      expect(draft(tester), 'after explicit permission');
      expect(f.voice.starts, hasLength(1));
      expect(f.inspections, isEmpty);
      await disposePage(tester);
    },
  );

  testWidgets(
    'background during permission request invalidates the late start',
    (tester) async {
      final f = VoicePageFixture();
      f.voice.autoListen = false;
      f.voice.startGate = Completer<void>();
      await show(tester, f);
      await start(tester);
      final capture = f.voice.id;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      pauseApp(tester.binding);
      await tester.pumpAndSettle();
      f.voice.startGate!.complete();
      f.voice.emit(VoiceEvent(id: capture, type: VoiceEventType.listening));
      f.voice.transcript('must not return');
      resumeApp(tester.binding);
      await tester.pumpAndSettle();
      expect(f.voice.cancellations, contains(capture));
      expect(draft(tester), isEmpty);
      expect(f.voice.starts, hasLength(1));
      expect(continueButton(tester).onPressed, isNull);
      expect(f.inspections, isEmpty);
      await disposePage(tester);
    },
  );

  testWidgets('diagnostic fixture never creates microphone controls', (
    tester,
  ) async {
    final f = VoicePageFixture();
    await show(tester, f, diagnostic: true);
    expect(find.byType(VoiceStar), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Подготовить тестовый ответ'), findsOneWidget);
    expect(f.voice.starts, isEmpty);
    await disposePage(tester);
  });

  testWidgets(
    'persisted cooldown disables microphone without altering its deadline',
    (tester) async {
      final f = VoicePageFixture();
      f.store.value = jsonEncode({
        'version': 1,
        'phase': 'cooldown',
        'utcDeadline': f.store.utc + cooldownMs,
        'continuousDeadline': f.store.continuous + cooldownMs,
        'bootToken': f.store.boot,
      });
      final saved = f.store.value;
      await show(tester, f);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('30:00'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('voice-star')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('voice-star')));
      await tester.pumpAndSettle();
      expect(f.voice.starts, isEmpty);
      expect(f.store.value, saved);
      expect(f.store.writes, 0);
      expect(f.random.calls, 0);
      await disposePage(tester);
    },
  );
}
