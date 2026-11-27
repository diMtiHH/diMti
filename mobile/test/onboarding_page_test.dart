import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:universe_lab/app_shell.dart';
import 'package:universe_lab/aura_renderer.dart';
import 'package:universe_lab/cosmic_theme.dart';
import 'package:universe_lab/engine.dart';
import 'package:universe_lab/narration.dart';
import 'package:universe_lab/onboarding_page.dart';
import 'package:universe_lab/presentation_profile.dart';
import 'package:universe_lab/session_clock_scope.dart';
import 'package:universe_lab/universe_startup.dart';

import 'narration_test.dart' show TestNarrationBackend;
import 'presentation_profile_test.dart' show MemoryPresentationBackend;
import 'session_page_test.dart' show TestBackend, TestRandom;
import 'voice_page_test.dart' show PageVoiceBackend, pauseApp, resumeApp;

class OnboardingFixture {
  final profile = MemoryPresentationBackend();
  final session = TestBackend();
  final narration = TestNarrationBackend();
  final random = TestRandom();
  final voices = <PageVoiceBackend>[];
  int inspections = 0;

  PresentationProfile get stored =>
      PresentationProfile.fromJson(profile.value!);

  Future<Reading> inspect(String text, String language) async {
    ++inspections;
    return const Reading(Outcome.held, 'synthetic onboarding fixture');
  }

  PageVoiceBackend newVoice() {
    final voice = PageVoiceBackend();
    voices.add(voice);
    return voice;
  }

  Widget app() => UniverseApp(
    presentationBackend: profile,
    sessionBackend: session,
    narrationBackend: narration,
    voiceBackend: newVoice(),
    inspector: inspect,
    random: random,
  );

  UniverseShell shell() => UniverseShell(
    presentationBackend: profile,
    sessionBackend: session,
    narrationBackend: narration,
    voiceBackend: newVoice(),
    inspector: inspect,
    random: random,
  );

  void expectNoQuestionAction() {
    expect(inspections, 0);
    expect(random.calls, 0);
    expect(session.writes, 0);
    expect(session.resets, 0);
    expect(session.schedules, 0);
    expect(voices.expand((voice) => voice.starts), isEmpty);
  }
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

  Future<void> preload(WidgetTester tester) async {
    await tester.runAsync(() async {
      await NarrationTrack.load('ru');
      await NarrationTrack.load('en');
      await warmUpAuraShaders();
    });
  }

  Future<void> flushUi(WidgetTester tester) async {
    // Audio polls deliberately schedule frames every 100 ms, so playback does
    // not settle. Asset futures use real async even when their bytes are cached;
    // yield to them after the frame that mounts/reloads the onboarding page.
    await tester.pump();
    await preload(tester);
    await tester.pump(const Duration(milliseconds: 300));
    for (var i = 0; i < 10; ++i) {
      await tester.pump();
    }
    // The new startup cover also waits for the restored session. Complete its
    // short visual transition only when that cover actually exists.
    for (
      var i = 0;
      i < 20 && find.byType(UniverseStartup).evaluate().isNotEmpty;
      ++i
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> show(
    WidgetTester tester,
    OnboardingFixture fixture, {
    bool reduced = true,
  }) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await preload(tester);
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(disableAnimations: reduced);
    await tester.pumpWidget(fixture.app());
    await flushUi(tester);
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty &&
        find.byType(ListView).evaluate().isNotEmpty) {
      await tester.scrollUntilVisible(
        finder,
        280,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
    }
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await flushUi(tester);
  }

  Future<void> close(WidgetTester tester, OnboardingFixture fixture) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    for (final voice in fixture.voices) {
      voice.dispose();
    }
  }

  testWidgets(
    'three steps persist independent choices and enter home only after consent write',
    (tester) async {
      final fixture = OnboardingFixture();
      await show(tester, fixture);
      expect(find.text('1 / 3'), findsOneWidget);
      expect(fixture.narration.plays, isEmpty);
      await tester.enterText(find.byType(TextField), 'Астра');
      await tap(tester, find.text('Продолжить'));
      expect(find.text('2 / 3'), findsOneWidget);
      expect(fixture.stored.name, 'Астра');
      expect(fixture.stored.completed, isFalse);
      await tap(tester, find.byKey(const ValueKey('background-galaxy')));
      expect(fixture.stored.background, PresentationBackground.galaxy);
      expect(fixture.stored.answerStyle, PresentationAnswerStyle.livingMatter);
      await tap(tester, find.byKey(const ValueKey('answer-style-liquidMetal')));
      expect(fixture.stored.background, PresentationBackground.galaxy);
      expect(fixture.stored.answerStyle, PresentationAnswerStyle.liquidMetal);
      expect(fixture.narration.plays, isEmpty);
      await tap(tester, find.text('Продолжить'));
      expect(find.text('3 / 3'), findsOneWidget);
      expect(find.text('Принципы взаимодействия'), findsOneWidget);
      expect(fixture.narration.plays.single.language, 'ru');
      final narrationId = fixture.narration.id;
      final track = (await tester.runAsync(() => NarrationTrack.load('ru')))!;
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('principles-text'))).data,
        track.text,
      );
      fixture.profile.writeGate = Completer<void>();
      await tap(tester, find.text('Я понимаю и принимаю'));
      expect(fixture.stored.completed, isFalse);
      expect(find.byKey(const ValueKey('open-settings')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Я понимаю и принимаю'),
            )
            .onPressed,
        isNull,
      );
      expect(fixture.narration.stops, contains(narrationId));
      fixture.profile.writeGate!.complete();
      await flushUi(tester);
      expect(find.byType(OnboardingPage), findsNothing);
      expect(find.byKey(const ValueKey('open-settings')), findsOneWidget);
      expect(find.text('Привет, Астра'), findsOneWidget);
      expect(find.byType(AuraTouchSurface), findsOneWidget);
      expect(find.byKey(const ValueKey('answer')), findsNothing);
      expect(fixture.stored.completed, isTrue);
      expect(fixture.stored.termsVersion, currentTermsVersion);
      expect(fixture.stored.background, PresentationBackground.galaxy);
      expect(fixture.stored.answerStyle, PresentationAnswerStyle.liquidMetal);
      fixture.expectNoQuestionAction();
      await close(tester, fixture);
    },
  );

  testWidgets('skip makes the name optional and does not imply consent', (
    tester,
  ) async {
    final fixture = OnboardingFixture();
    await show(tester, fixture);
    await tester.enterText(find.byType(TextField), 'Не сохранять');
    await tap(tester, find.text('Пропустить'));
    expect(find.text('2 / 3'), findsOneWidget);
    expect(fixture.stored.name, isEmpty);
    expect(fixture.stored.completed, isFalse);
    expect(fixture.stored.termsVersion, 0);
    expect(fixture.narration.plays, isEmpty);
    fixture.expectNoQuestionAction();
    await close(tester, fixture);
  });

  for (final step in [1, 2]) {
    testWidgets(
      'restart resumes persisted step $step without replaying earlier slides',
      (tester) async {
        final fixture = OnboardingFixture();
        final saved = PresentationProfile(
          name: 'Сохранено',
          background: PresentationBackground.galaxy,
          answerStyle: PresentationAnswerStyle.constellation,
          onboardingStep: step,
          audioEnabled: false,
        );
        fixture.profile.value = saved.toJson();
        await show(tester, fixture);
        expect(find.text('${step + 1} / 3'), findsOneWidget);
        expect(find.text('1 / 3'), findsNothing);
        expect(find.byType(TextField), findsNothing);
        expect(fixture.stored, saved);
        expect(fixture.profile.writes, isEmpty);
        expect(fixture.narration.plays, isEmpty);
        await close(tester, fixture);
        await show(tester, fixture);
        expect(find.text('${step + 1} / 3'), findsOneWidget);
        expect(fixture.profile.writes, isEmpty);
        expect(fixture.narration.plays, isEmpty);
        fixture.expectNoQuestionAction();
        await close(tester, fixture);
      },
    );
  }

  testWidgets(
    'completed onboarding never replays intro or narration after restart',
    (tester) async {
      final fixture = OnboardingFixture();
      fixture.profile.value = PresentationProfile(
        name: 'Орион',
        completed: true,
        onboardingStep: 2,
        termsVersion: currentTermsVersion,
      ).toJson();
      for (var launch = 0; launch < 2; ++launch) {
        await show(tester, fixture);
        expect(find.byType(OnboardingPage), findsNothing);
        expect(find.byKey(const ValueKey('open-settings')), findsOneWidget);
        expect(find.text('Привет, Орион'), findsOneWidget);
        await tester.pump(const Duration(seconds: 10));
        expect(fixture.narration.plays, isEmpty);
        expect(fixture.profile.writes, isEmpty);
        await close(tester, fixture);
      }
      fixture.expectNoQuestionAction();
    },
  );

  testWidgets(
    'changed terms show only static consent without replaying onboarding audio',
    (tester) async {
      final fixture = OnboardingFixture();
      final old = PresentationProfile(
        name: 'Луна',
        background: PresentationBackground.gravity,
        answerStyle: PresentationAnswerStyle.livingMatter,
        completed: true,
        onboardingStep: 2,
        termsVersion: currentTermsVersion + 1,
      );
      fixture.profile.value = old.toJson();
      await show(tester, fixture);
      expect(find.text('Принципы взаимодействия'), findsOneWidget);
      expect(find.text('1 / 3'), findsNothing);
      expect(find.text('3 / 3'), findsNothing);
      expect(find.text('Назад'), findsNothing);
      expect(find.text('Озвучка'), findsNothing);
      expect(find.text('Прочитать весь текст'), findsNothing);
      final track = (await tester.runAsync(() => NarrationTrack.load('ru')))!;
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('principles-text'))).data,
        track.text,
      );
      expect(fixture.narration.plays, isEmpty);
      expect(fixture.profile.writes, isEmpty);
      await tap(tester, find.text('Я понимаю и принимаю'));
      expect(find.byType(OnboardingPage), findsNothing);
      expect(fixture.stored, old.copyWith(termsVersion: currentTermsVersion));
      expect(fixture.profile.writes, hasLength(1));
      fixture.expectNoQuestionAction();
      await close(tester, fixture);
    },
  );

  testWidgets('principles in settings are read-only and never play audio', (
    tester,
  ) async {
    final fixture = OnboardingFixture();
    final saved = PresentationProfile(
      completed: true,
      onboardingStep: 2,
      termsVersion: currentTermsVersion,
    );
    fixture.profile.value = saved.toJson();
    await show(tester, fixture);
    await tap(tester, find.byKey(const ValueKey('open-settings')));
    await tap(tester, find.text('Принципы взаимодействия'));
    expect(find.byType(PrinciplesPage), findsOneWidget);
    final track = (await tester.runAsync(() => NarrationTrack.load('ru')))!;
    expect(find.text(track.text), findsOneWidget);
    expect(find.text('Я понимаю и принимаю'), findsNothing);
    expect(find.text('Озвучка'), findsNothing);
    expect(fixture.narration.plays, isEmpty);
    expect(fixture.profile.writes, isEmpty);
    expect(fixture.stored, saved);
    fixture.expectNoQuestionAction();
    await close(tester, fixture);
  });

  testWidgets(
    'corrupt profile blocks entry and retry never resets stored data',
    (tester) async {
      final fixture = OnboardingFixture()..profile.value = '{broken';
      await show(tester, fixture);
      expect(
        find.text(
          'Не удалось прочитать или сохранить настройки. Данные не сброшены.',
        ),
        findsOneWidget,
      );
      expect(find.byType(OnboardingPage), findsNothing);
      expect(find.byKey(const ValueKey('open-settings')), findsNothing);
      await tap(tester, find.text('Повторить загрузку'));
      expect(fixture.profile.value, '{broken');
      expect(fixture.profile.writes, isEmpty);
      expect(fixture.narration.plays, isEmpty);
      fixture.profile.value = const PresentationProfile.defaults().toJson();
      await tap(tester, find.text('Повторить загрузку'));
      expect(find.text('1 / 3'), findsOneWidget);
      expect(fixture.profile.writes, isEmpty);
      fixture.expectNoQuestionAction();
      await close(tester, fixture);
    },
  );

  testWidgets(
    'ambiguous consent write blocks home until explicit readback recovers it',
    (tester) async {
      final fixture = OnboardingFixture();
      fixture.profile.value = PresentationProfile(
        onboardingStep: 2,
        audioEnabled: false,
      ).toJson();
      await show(tester, fixture);
      fixture.profile.commitBeforeWriteError = true;
      fixture.profile.writeError = PlatformException(code: 'storage');
      await tap(tester, find.text('Я понимаю и принимаю'));
      expect(fixture.stored.completed, isTrue);
      expect(find.byKey(const ValueKey('open-settings')), findsNothing);
      expect(
        find.text(
          'Не удалось прочитать или сохранить настройки. Данные не сброшены.',
        ),
        findsOneWidget,
      );
      expect(fixture.profile.writes, hasLength(1));
      fixture.profile.writeError = null;
      await tap(tester, find.text('Повторить загрузку'));
      expect(find.byKey(const ValueKey('open-settings')), findsOneWidget);
      expect(find.byType(OnboardingPage), findsNothing);
      expect(fixture.narration.plays, isEmpty);
      expect(fixture.profile.writes, hasLength(1));
      fixture.expectNoQuestionAction();
      await close(tester, fixture);
    },
  );

  testWidgets(
    'background cancels pending audio and resume needs an explicit play tap',
    (tester) async {
      final fixture = OnboardingFixture();
      fixture.profile.value = PresentationProfile(onboardingStep: 2).toJson();
      fixture.narration.playGate = Completer<int>();
      await show(tester, fixture);
      final old = fixture.narration.id;
      pauseApp(tester.binding);
      await flushUi(tester);
      expect(fixture.narration.stops, contains(old));
      resumeApp(tester.binding);
      fixture.narration.playGate!.complete(40000);
      fixture.narration.playGate = null;
      await flushUi(tester);
      expect(fixture.narration.plays, hasLength(1));
      expect(fixture.narration.stops.where((id) => id == old), hasLength(2));
      await tap(tester, find.text('Прослушать с начала'));
      final next = fixture.narration.id;
      expect(next, greaterThan(old));
      expect(fixture.narration.plays, hasLength(2));
      expect(fixture.narration.stops, isNot(contains(next)));
      expect(fixture.profile.writes, isEmpty);
      fixture.expectNoQuestionAction();
      await close(tester, fixture);
    },
  );

  testWidgets(
    'language change cancels narration and displays new text without automatic sound',
    (tester) async {
      final fixture = OnboardingFixture();
      fixture.profile.value = PresentationProfile(onboardingStep: 2).toJson();
      await show(tester, fixture);
      final old = fixture.narration.id;
      await tap(tester, find.text('EN'));
      expect(fixture.session.language, 'en');
      expect(fixture.narration.stops, contains(old));
      expect(fixture.narration.plays, hasLength(1));
      final english = (await tester.runAsync(() => NarrationTrack.load('en')))!;
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('principles-text'))).data,
        english.text,
      );
      await tap(tester, find.text('Listen from the beginning'));
      expect(fixture.narration.plays.last.language, 'en');
      expect(fixture.narration.id, greaterThan(old));
      expect(fixture.profile.writes, isEmpty);
      fixture.expectNoQuestionAction();
      await close(tester, fixture);
    },
  );

  testWidgets(
    'delayed slide persistence cannot start narration after background and resume',
    (tester) async {
      final fixture = OnboardingFixture();
      fixture.profile.value = PresentationProfile(onboardingStep: 1).toJson();
      await show(tester, fixture);
      fixture.profile.writeGate = Completer<void>();
      await tap(tester, find.text('Продолжить'));
      expect(fixture.stored.onboardingStep, 1);
      pauseApp(tester.binding);
      await flushUi(tester);
      resumeApp(tester.binding);
      fixture.profile.writeGate!.complete();
      await flushUi(tester);
      expect(find.text('3 / 3'), findsOneWidget);
      expect(fixture.stored.onboardingStep, 2);
      expect(fixture.narration.plays, isEmpty);
      expect(find.text('Прослушать с начала'), findsOneWidget);
      fixture.expectNoQuestionAction();
      await close(tester, fixture);
    },
  );

  testWidgets(
    'audio failure leaves complete readable principles and explicit consent available',
    (tester) async {
      final fixture = OnboardingFixture();
      fixture.profile.value = PresentationProfile(onboardingStep: 2).toJson();
      fixture.narration.playError = MissingPluginException();
      await show(tester, fixture, reduced: false);
      final track = (await tester.runAsync(() => NarrationTrack.load('ru')))!;
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('principles-text'))).data,
        track.text,
      );
      expect(
        find.text('Звук недоступен. Текст можно прочитать полностью.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Я понимаю и принимаю'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.pump(const Duration(seconds: 10));
      expect(fixture.narration.plays, hasLength(1));
      expect(fixture.stored.completed, isFalse);
      expect(fixture.profile.writes, isEmpty);
      fixture.expectNoQuestionAction();
      await close(tester, fixture);
    },
  );

  testWidgets(
    'mid-playback failure automatically reveals complete text with motion enabled',
    (tester) async {
      final fixture = OnboardingFixture();
      fixture.profile.value = PresentationProfile(onboardingStep: 2).toJson();
      await show(tester, fixture, reduced: false);
      final track = (await tester.runAsync(() => NarrationTrack.load('ru')))!;
      String text() => tester
          .widget<Text>(find.byKey(const ValueKey('principles-text')))
          .data!;
      final id = fixture.narration.id;
      final position = track.segments.first.endMs ~/ 2;
      fixture.narration.positions[id] = NarrationPosition(
        position,
        track.durationMs,
        true,
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(text(), track.visibleText(position));
      expect(text(), isNot(track.text));
      // Native decode/interruption retires its playback id. The next position
      // call fails; the UI must disclose the full text without a manual tap.
      fixture.narration.positionError = PlatformException(code: 'interrupted');
      await tester.pump(const Duration(milliseconds: 100));
      expect(text(), track.text);
      expect(fixture.narration.stops, contains(id));
      expect(
        find.text('Звук недоступен. Текст можно прочитать полностью.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Я понимаю и принимаю'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.pump(const Duration(seconds: 5));
      expect(fixture.narration.plays, hasLength(1));
      expect(fixture.stored.completed, isFalse);
      expect(fixture.profile.writes, isEmpty);
      fixture.expectNoQuestionAction();
      await close(tester, fixture);
    },
  );

  for (final destination in ['world tab', 'settings']) {
    testWidgets(
      '$destination clears a private review and requires a fresh question after returning',
      (tester) async {
        final fixture = OnboardingFixture();
        fixture.profile.value = PresentationProfile(
          completed: true,
          onboardingStep: 2,
          termsVersion: currentTermsVersion,
        ).toJson();
        await show(tester, fixture);
        await tap(tester, find.byType(AuraTouchSurface));
        await tester.enterText(
          find.byKey(const ValueKey('question-input')),
          'private review fixture',
        );
        await flushUi(tester);
        await tap(tester, find.text('Продолжить'));
        expect(find.byKey(const ValueKey('confirm-question')), findsOneWidget);
        if (destination == 'world tab') {
          await tap(tester, find.byKey(const ValueKey('tab-1')));
        } else {
          await tap(tester, find.byKey(const ValueKey('open-settings')));
        }
        expect(find.text('private review fixture'), findsNothing);
        expect(find.byKey(const ValueKey('confirm-question')), findsNothing);
        if (destination == 'world tab') {
          await tap(tester, find.byKey(const ValueKey('tab-0')));
        } else {
          await tap(tester, find.byTooltip('Назад'));
        }
        await tap(tester, find.byType(AuraTouchSurface));
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
        expect(find.byKey(const ValueKey('confirm-question')), findsNothing);
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Продолжить'),
              )
              .onPressed,
          isNull,
        );
        expect(fixture.profile.writes, isEmpty);
        fixture.expectNoQuestionAction();
        await close(tester, fixture);
      },
    );
  }

  testWidgets(
    'animated transcript uses actual player position and offers full text immediately',
    (tester) async {
      final fixture = OnboardingFixture();
      fixture.profile.value = PresentationProfile(onboardingStep: 2).toJson();
      await show(tester, fixture, reduced: false);
      final track = (await tester.runAsync(() => NarrationTrack.load('ru')))!;
      String text() => tester
          .widget<Text>(find.byKey(const ValueKey('principles-text')))
          .data!;
      expect(text(), '…');
      await tester.pump(const Duration(seconds: 5));
      expect(text(), '…');
      final position = track.segments.first.endMs ~/ 2;
      fixture.narration.positions[fixture.narration.id] = NarrationPosition(
        position,
        track.durationMs,
        true,
      );
      await tester.pump(const Duration(milliseconds: 100));
      final partial = track.visibleText(position);
      expect(text(), partial);
      expect(partial, isNot(track.text));
      await tester.pump(const Duration(seconds: 4));
      expect(text(), partial);
      await tester.ensureVisible(find.text('Прочитать весь текст'));
      await tester.tap(find.text('Прочитать весь текст'));
      await tester.pump();
      expect(text(), track.text);
      expect(fixture.stored.completed, isFalse);
      fixture.expectNoQuestionAction();
      await close(tester, fixture);
    },
  );

  testWidgets(
    'render three onboarding screens and home at iPhone width for review',
    (tester) async {
      final fixture = OnboardingFixture();
      await tester.runAsync(() async {
        final icons = FontLoader('MaterialIcons');
        icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
        for (final family in ['Cormorant Garamond', 'Literata']) {
          final loader = FontLoader(family);
          final prefix = family.replaceAll(' ', '');
          final weights = [
            if (family == 'Cormorant Garamond') 'Light',
            'Regular',
            'Medium',
            'SemiBold',
          ];
          for (final weight in weights) {
            loader.addFont(rootBundle.load('assets/fonts/$prefix-$weight.ttf'));
          }
          await loader.load();
        }
      });
      await preload(tester);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const boundaryKey = ValueKey('onboarding-preview');
      final theme = cosmicTheme;
      await tester.pumpWidget(
        SessionClockScope(
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            home: RepaintBoundary(key: boundaryKey, child: fixture.shell()),
          ),
        ),
      );
      await flushUi(tester);

      Future<void> capture(String name) async {
        expect(tester.takeException(), isNull);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(boundaryKey),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          try {
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            final output = File('build/stage6/screens/$name.png');
            await output.parent.create(recursive: true);
            await output.writeAsBytes(png!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }

      await capture('onboarding-1');
      await tester.enterText(find.byType(TextField), 'Астра');
      await tap(tester, find.text('Продолжить'));
      expect(
        find.text('Выбери, как Вселенная\nбудет тебе отвечать').hitTestable(),
        findsOneWidget,
      );
      await tap(tester, find.byKey(const ValueKey('background-aurora')));
      await tap(
        tester,
        find.byKey(const ValueKey('answer-style-constellation')),
      );
      await tester.drag(find.byType(ListView), const Offset(0, 1000));
      await flushUi(tester);
      await capture('onboarding-2');
      await tap(tester, find.text('Продолжить'));
      expect(
        find.text('Принципы взаимодействия').hitTestable(),
        findsOneWidget,
      );
      await capture('onboarding-3');
      await tap(tester, find.text('Я понимаю и принимаю'));
      expect(find.byKey(const ValueKey('open-settings')), findsOneWidget);
      expect(
        tester.widget<AuraScene>(find.byType(AuraScene).first).background,
        'aurora',
      );
      await capture('home');
      fixture.expectNoQuestionAction();
      await close(tester, fixture);
    },
  );
}
