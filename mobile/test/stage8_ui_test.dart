import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:universe_lab/app_information.dart';
import 'package:universe_lab/app_shell.dart';
import 'package:universe_lab/cosmic_theme.dart';
import 'package:universe_lab/engine.dart';
import 'package:universe_lab/session_clock_scope.dart';
import 'package:universe_lab/world_catalog.dart';
import 'package:universe_lab/world_data.dart';
import 'package:universe_lab/world_page.dart';

import 'aura_shell_test.dart' show ShellFixture;
import 'world_data_test.dart' show MemoryWorldStore, TestWorldTransport;
import 'voice_page_test.dart' show resumeApp;

void main() {
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
  Future<void> frames(WidgetTester tester, [int n = 15]) async {
    for (var i = 0; i < n; i++)
      await tester.pump(const Duration(milliseconds: 25));
  }

  Future<void> click(WidgetTester tester, Finder f) async {
    if (f.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        f,
        250,
        scrollable: find.byType(Scrollable).first,
      );
    }
    await tester.ensureVisible(f);
    await frames(tester);
    await tester.tap(f);
    await frames(tester);
  }

  Future<void> sizing(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<WorldController> world() async {
    final value = WorldController(
      store: MemoryWorldStore(),
      transport: TestWorldTransport()..configured = false,
    );
    await value.load();
    addTearDown(value.dispose);
    return value;
  }

  for (final language in ['ru', 'en']) {
    testWidgets(
      'world $language scales to 200 percent without fake counts; tap only selects text',
      (tester) async {
        await sizing(tester);
        final data = await world();
        String? selected;
        await tester.pumpWidget(
          MaterialApp(
            theme: cosmicTheme,
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(390, 844),
                disableAnimations: true,
                textScaler: TextScaler.linear(2),
              ),
              child: Scaffold(
                body: WorldPage(
                  controller: data,
                  language: language,
                  background: 'aurora',
                  active: false,
                  onSelect: (topic) => selected = topic.id,
                ),
              ),
            ),
          ),
        );
        await frames(tester);
        expect(tester.takeException(), null);
        expect(find.textContaining('≈'), findsNothing);
        await click(tester, find.text(worldCatalog.first.text(language)));
        expect(selected, 'read_novel');
        expect(tester.takeException(), null);
        await tester.pumpWidget(const SizedBox());
        await frames(tester);
      },
    );
    testWidgets(
      'settings documents $language are offline readable at 200 percent',
      (tester) async {
        await sizing(tester);
        final data = await world();
        for (final section in InformationSection.values) {
          await tester.pumpWidget(
            MaterialApp(
              theme: cosmicTheme,
              home: MediaQuery(
                data: const MediaQueryData(
                  size: Size(390, 844),
                  disableAnimations: true,
                  textScaler: TextScaler.linear(2),
                ),
                child: AppInformationPage(
                  section: section,
                  language: language,
                  controller: data,
                ),
              ),
            ),
          );
          await frames(tester);
          expect(tester.takeException(), null, reason: section.name);
          expect(
            find.text(informationTitle(section, language)),
            findsOneWidget,
          );
          if (section == InformationSection.help) {
            await click(tester, find.byKey(const ValueKey('help-country')));
            await click(
              tester,
              find.text(language == 'ru' ? 'США' : 'USA').last,
            );
            expect(
              find.text(
                language == 'ru'
                    ? 'Экстренная помощь: 911'
                    : 'Emergency services: 911',
              ),
              findsOneWidget,
            );
            expect(tester.takeException(), null);
          }
          await tester.pumpWidget(const SizedBox());
          await frames(tester);
        }
      },
    );
  }
  testWidgets(
    'system material labels follow the saved language in the real app',
    (tester) async {
      await sizing(tester);
      for (final language in ['ru', 'en']) {
        final fixture = ShellFixture(language: language);
        await tester.pumpWidget(
          UniverseApp(
            presentationBackend: fixture.presentation,
            sessionBackend: fixture.session,
            voiceBackend: fixture.voice,
            ambientBackend: fixture.ambient,
            random: fixture.random,
            inspector: (_, __) async => const Reading(Outcome.held, 'fixture'),
          ),
        );
        await frames(tester, 30);
        expect(
          tester
              .widget<MaterialApp>(find.byType(MaterialApp))
              .locale!
              .languageCode,
          language,
        );
        final context = tester.element(find.byType(UniverseShell));
        expect(
          MaterialLocalizations.of(context).copyButtonLabel,
          language == 'ru' ? 'Копировать' : 'Copy',
        );
        await tester.pumpWidget(const SizedBox());
        await frames(tester);
      }
    },
  );
  testWidgets(
    'catalog to confirmation to answer to reset works; settings keep the pause',
    (tester) async {
      await sizing(tester);
      final data = await world();
      final fixture = ShellFixture();
      var inspections = 0;
      await tester.pumpWidget(
        SessionClockScope(
          child: MaterialApp(
            theme: cosmicTheme,
            home: UniverseShell(
              worldController: data,
              presentationBackend: fixture.presentation,
              sessionBackend: fixture.session,
              voiceBackend: fixture.voice,
              ambientBackend: fixture.ambient,
              random: fixture.random,
              inspector: (_, __) async {
                ++inspections;
                return const Reading(Outcome.held, 'admission_disabled');
              },
            ),
          ),
        ),
      );
      await frames(tester, 40);
      await tester.pump(const Duration(seconds: 4));
      await frames(tester, 40);
      await click(tester, find.byKey(const ValueKey('tab-1')));
      await click(tester, find.text(worldCatalog.first.ru));
      expect(inspections, 0);
      expect(fixture.random.calls, 0);
      expect(find.byType(TextField), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        worldCatalog.first.ru,
      );
      await click(tester, find.text('Продолжить'));
      expect(fixture.random.calls, 0);
      await click(tester, find.byKey(const ValueKey('confirm-question')));
      await tester.pump(const Duration(seconds: 6));
      await frames(tester, 40);
      expect(inspections, 1);
      expect(fixture.random.calls, 1);
      expect(jsonDecode(fixture.session.value!)['phase'], 'cooldown');
      expect(find.text('Нет'), findsWidgets);
      // Close the fullscreen answer using its labelled close control.
      final back = find.byTooltip('Закрыть');
      if (back.evaluate().isNotEmpty) {
        await click(tester, back);
      } else {
        await tester.pageBack();
        await frames(tester);
      }
      final cooldown = fixture.session.value;
      await click(tester, find.byKey(const ValueKey('open-settings')));
      await click(tester, find.byKey(const ValueKey('settings-personal')));
      await click(tester, find.byKey(const ValueKey('reset-appearance')));
      await click(tester, find.text('Сбросить оформление'));
      expect(fixture.session.value, cooldown);
      await click(tester, find.text('Готово'));
      await click(tester, find.byKey(const ValueKey('reset-personal-limit')));
      await click(tester, find.text('Отмена'));
      expect(jsonDecode(fixture.session.value!)['phase'], 'cooldown');
      await click(tester, find.byKey(const ValueKey('reset-personal-limit')));
      await click(tester, find.text('Сбросить'));
      expect(jsonDecode(fixture.session.value!)['phase'], 'idle');
      expect(fixture.random.calls, 1);
      expect(find.byKey(const ValueKey('reset-personal-limit')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
    },
  );
}
