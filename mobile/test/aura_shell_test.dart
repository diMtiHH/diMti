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
import 'package:universe_lab/presentation_profile.dart';
import 'package:universe_lab/session_clock_scope.dart';
import 'package:universe_lab/universe_startup.dart';

import 'ambient_audio_test.dart' show TestAmbientBackend;
import 'presentation_profile_test.dart' show MemoryPresentationBackend;
import 'session_page_test.dart' show TestBackend, TestRandom;
import 'voice_page_test.dart' show PageVoiceBackend, pauseApp, resumeApp;
import 'aura_test_support.dart';

class ShellFixture {
  final presentation = MemoryPresentationBackend();
  final TestBackend session;
  final random = TestRandom();
  final voice = PageVoiceBackend();
  final ambient = TestAmbientBackend();
  int inspections = 0;
  ShellFixture({
    bool sound = false,
    bool haptics = true,
    String language = 'ru',
    String name = 'Астра',
    TestBackend? backend,
  }) : session = backend ?? TestBackend() {
    session.language = language;
    presentation.value = const PresentationProfile.defaults()
        .copyWith(
          name: name,
          onboardingStep: 2,
          completed: true,
          termsVersion: currentTermsVersion,
          ambientEnabled: sound,
          hapticsEnabled: haptics,
        )
        .toJson();
  }
  UniverseShell shell() => UniverseShell(
    presentationBackend: presentation,
    sessionBackend: session,
    voiceBackend: voice,
    random: random,
    ambientBackend: ambient,
    inspector: (_, __) async {
      ++inspections;
      return const Reading(Outcome.held, 'fixture');
    },
  );
}

class GatedShellBackend extends TestBackend {
  final gate = Completer<void>();
  @override
  Future<String?> read() async {
    await gate.future;
    return super.read();
  }
}

void main() {
  var shadersReady = false;
  setUp(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    resumeApp(binding);
    binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
  });
  tearDown(
    () => TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .clearAccessibilityFeaturesTestValue(),
  );
  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 12; ++i) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) {
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
    await frames(tester);
    await tester.tap(finder);
    await frames(tester);
  }

  Future<void> show(
    WidgetTester tester,
    ShellFixture fixture, {
    Size size = const Size(390, 844),
    double scale = 1,
  }) async {
    if (!shadersReady) {
      await tester.runAsync(warmUpAuraShaders);
      shadersReady = true;
    }
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      SessionClockScope(
        child: MaterialApp(
          theme: cosmicTheme,
          debugShowCheckedModeBanner: false,
          builder: (context, child) => RepaintBoundary(
            key: const ValueKey('aura-capture'),
            child: MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
          ),
          home: fixture.shell(),
        ),
      ),
    );
    await frames(tester);
  }

  Future<void> clean(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
  }

  testWidgets(
    'startup covers all input until real session restoration is ready',
    (tester) async {
      final backend = GatedShellBackend();
      final fixture = ShellFixture(sound: true, backend: backend);
      await show(tester, fixture);
      expect(find.byType(UniverseStartup), findsOneWidget);
      tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
      addTearDown(tester.view.resetPadding);
      await frames(tester);
      expect(
        tester.getRect(find.byKey(const ValueKey('startup-full-bleed'))),
        const Rect.fromLTWH(0, 0, 390, 844),
        reason: 'The startup backdrop must include the status/home-indicator areas.',
      );
      expect(find.byType(AuraTouchSurface), findsNothing);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('open-settings')))
            .onPressed,
        isNull,
      );
      await tester.tapAt(const Offset(195, 422));
      await tester.pump(const Duration(seconds: 20));
      expect(find.byType(UniverseStartup), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(fixture.voice.starts, isEmpty);
      expect(fixture.ambient.plays, isEmpty);
      expect(fixture.random.calls, 0);
      backend.gate.complete();
      await frames(tester);
      expect(find.byType(UniverseStartup), findsNothing);
      expect(find.byType(AuraTouchSurface), findsOneWidget);
      expect(fixture.ambient.plays, ['aurora']);
      await clean(tester);
    },
  );

  testWidgets(
    'a 40-character nickname stays centered and limited to two lines',
    (tester) async {
      final fixture = ShellFixture(name: 'Щ' * 40);
      await show(tester, fixture, size: const Size(320, 568), scale: 1.8);
      final finder = find.byKey(const ValueKey('main-greeting'));
      final text = tester.widget<Text>(finder);
      expect(text.textAlign, TextAlign.center);
      expect(text.maxLines, 2);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(tester.getRect(finder).center.dx, closeTo(160, .1));
      expect(tester.takeException(), isNull);
      await clean(tester);
    },
  );

  testWidgets(
    'settings control ambient and haptics; no production diagnostic entry or question side effects',
    (tester) async {
      final fixture = ShellFixture();
      await show(tester, fixture);
      expect(fixture.ambient.plays, isEmpty);
      await tap(tester, find.byKey(const ValueKey('open-settings')));
      expect(find.text('Проверка ядра'), findsNothing);
      await tap(tester, find.byKey(const ValueKey('settings-senses')));
      await tap(tester, find.byKey(const ValueKey('ambient-enabled')));
      expect(fixture.ambient.plays, ['aurora']);
      await tap(tester, find.byKey(const ValueKey('haptics-enabled')));
      expect(
        PresentationProfile.fromJson(fixture.presentation.value!)
            .hapticsEnabled,
        false,
      );
      await tap(tester, find.text('Готово'));
      pauseApp(tester.binding);
      await frames(tester);
      expect(fixture.ambient.stops, 1);
      resumeApp(tester.binding);
      await frames(tester);
      expect(fixture.ambient.plays, hasLength(1));
      await tap(tester, find.byKey(const ValueKey('open-settings')));
      await tap(tester, find.byKey(const ValueKey('settings-senses')));
      await tap(tester, find.text('Возобновить звук'));
      expect(fixture.ambient.plays, hasLength(2));
      expect(fixture.random.calls, 0);
      expect(fixture.session.writes, 0);
      expect(fixture.inspections, 0);
      await clean(tester);
    },
  );

  testWidgets(
    'main explicit microphone silences ambient; background clears draft and no automatic audio restart',
    (tester) async {
      final fixture = ShellFixture(sound: true);
      await show(tester, fixture);
      expect(fixture.ambient.plays, ['aurora']);
      await tap(tester, find.byType(AuraTouchSurface));
      await tester.enterText(find.byType(TextField), 'private synthetic draft');
      await frames(tester);
      await tap(tester, find.byKey(const ValueKey('voice-input')));
      expect(fixture.ambient.stops, 1);
      expect(fixture.voice.starts, hasLength(1));
      pauseApp(tester.binding);
      await frames(tester);
      resumeApp(tester.binding);
      await frames(tester);
      expect(find.textContaining('private synthetic draft'), findsNothing);
      expect(fixture.ambient.plays, hasLength(1));
      expect(fixture.voice.cancellations, isNotEmpty);
      expect(fixture.random.calls, 0);
      expect(fixture.session.writes, 0);
      await clean(tester);
    },
  );

  testWidgets(
    'disabled haptics apply to main touch, input confirmation and navigation',
    (tester) async {
      final methods = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('ask_universe/haptics'),
        (call) async {
          if (call.method != 'cancel') methods.add(call.method);
          return null;
        },
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') methods.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('ask_universe/haptics'),
          null,
        ),
      );
      final fixture = ShellFixture(haptics: false);
      await show(tester, fixture);
      await tap(tester, find.byType(AuraTouchSurface));
      await tester.enterText(find.byType(TextField), 'synthetic question');
      await frames(tester);
      await tap(tester, find.text('Продолжить'));
      await tap(tester, find.byKey(const ValueKey('confirm-question')));
      await tap(tester, find.byKey(const ValueKey('tab-1')));
      expect(methods, isEmpty);
      expect(fixture.random.calls, 0);
      expect(fixture.session.writes, 0);
      await clean(tester);
    },
  );

  testWidgets(
    'large text and small iPhone layout remain usable for input and world in both languages',
    (tester) async {
      for (final language in ['ru', 'en']) {
        final fixture = ShellFixture(language: language);
        await show(tester, fixture, size: const Size(320, 568), scale: 1.8);
        await tap(tester, find.byType(AuraTouchSurface));
        await tester.enterText(
          find.byType(TextField),
          'A sufficiently long synthetic question to wrap on a small screen',
        );
        await frames(tester);
        await tap(
          tester,
          find.text(language == 'ru' ? 'Продолжить' : 'Continue'),
        );
        expect(find.byKey(const ValueKey('review-question')), findsOneWidget);
        await tap(tester, find.byKey(const ValueKey('tab-1')));
        expect(
          find.textContaining(
            language == 'ru'
                ? 'данные не собираются'
                : 'no data is being collected',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        expect(fixture.session.writes, 0);
        await clean(tester);
      }
    },
  );

  testWidgets(
    'capture actual AURA home input confirmation and world with bundled fonts and shaders',
    (tester) async {
      await tester.runAsync(() async {
        for (final family in ['Cormorant Garamond', 'Literata']) {
          final font = FontLoader(family);
          final prefix = family.replaceAll(' ', '');
          final weights = [
            if (family == 'Cormorant Garamond') 'Light',
            'Regular',
            'Medium',
            'SemiBold',
          ];
          for (final weight in weights) {
            font.addFont(rootBundle.load('assets/fonts/$prefix-$weight.ttf'));
          }
          await font.load();
        }
        final body = FontLoader('Manrope');
        for (final weight in ['Regular', 'Medium']) {
          body.addFont(rootBundle.load('assets/fonts/Manrope-$weight.ttf'));
        }
        await body.load();
      });
      final fixture = ShellFixture();
      await show(tester, fixture);
      Future<void> capture(String name) async {
        await settleAuraRaster(tester);
        expect(tester.takeException(), isNull);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('aura-capture')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File('build/stage6/screens/$name.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }

      await capture('aura-home');
      await tap(tester, find.byType(AuraTouchSurface));
      await capture('aura-input');
      await tester.enterText(
        find.byType(TextField),
        'Стоит ли мне сегодня почитать роман?',
      );
      await frames(tester);
      await tap(tester, find.text('Продолжить'));
      await capture('aura-confirmation');
      await tap(tester, find.byKey(const ValueKey('tab-1')));
      await capture('aura-world');
      await tap(tester, find.byKey(const ValueKey('open-settings')));
      await tester.pump(const Duration(milliseconds: 200));
      await capture('aura-settings-constellation');
      await tap(tester, find.byKey(const ValueKey('settings-appearance')));
      await capture('aura-settings-space');
      await tap(tester, find.byKey(const ValueKey('preview-animation')));
      await tester.pump(const Duration(milliseconds: 500));
      await capture('aura-settings-controls');
      expect(fixture.random.calls, 0);
      expect(fixture.session.writes, 0);
      await clean(tester);
      final blocked = GatedShellBackend();
      final starting = ShellFixture(backend: blocked);
      tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
      addTearDown(tester.view.resetPadding);
      await show(tester, starting);
      await capture('aura-startup');
      blocked.gate.complete();
      await clean(tester);
    },
  );
}
