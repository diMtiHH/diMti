import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:universe_lab/app_shell.dart';
import 'package:universe_lab/aura_renderer.dart';
import 'package:universe_lab/cosmic_scene.dart';
import 'package:universe_lab/cosmic_theme.dart';
import 'package:universe_lab/presentation_profile.dart';

import 'presentation_profile_test.dart' show MemoryPresentationBackend;
import 'session_page_test.dart' show TestBackend;
import 'aura_test_support.dart' show settleAuraRaster;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await warmUpAuraShaders();
    final heading = FontLoader('Cormorant Garamond');
    for (final weight in ['Light', 'Regular', 'Medium', 'SemiBold']) {
      heading.addFont(
        rootBundle.load('assets/fonts/CormorantGaramond-$weight.ttf'),
      );
    }
    await heading.load();
    final body = FontLoader('Literata');
    for (final weight in ['Regular', 'Medium', 'SemiBold']) {
      body.addFont(rootBundle.load('assets/fonts/Literata-$weight.ttf'));
    }
    await body.load();
    final controls = FontLoader('Manrope');
    for (final weight in ['Regular', 'Medium']) {
      controls.addFont(rootBundle.load('assets/fonts/Manrope-$weight.ttf'));
    }
    await controls.load();
  });
  Future<PresentationController> show(
    WidgetTester tester, {
    String language = 'ru',
    double scale = 1,
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final store = MemoryPresentationBackend()
      ..value = PresentationProfile(
        name: 'Дмитрий',
        completed: true,
        onboardingStep: 2,
        termsVersion: currentTermsVersion,
      ).toJson();
    final profile = PresentationController(store);
    await profile.load();
    final session = TestBackend()..language = language;
    await tester.pumpWidget(
      MaterialApp(
        theme: cosmicTheme,
        builder: (context, child) => RepaintBoundary(
          key: const ValueKey('settings-capture'),
          child: MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
        home: PresentationSettings(
          controller: profile,
          backend: session,
          language: language,
          onLanguage: session.setLanguage,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    addTearDown(profile.dispose);
    return profile;
  }

  Future<void> reach(WidgetTester tester, Finder target) async {
    if (target.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        target,
        240,
        scrollable: find.descendant(
          of: find.byType(ListView),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          ),
        ),
      );
    }
    await tester.ensureVisible(target);
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  Future<void> openSection(WidgetTester tester, String name) async {
    final target = find.byKey(ValueKey('settings-$name'));
    await reach(tester, target);
    await tester.tap(target);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> back(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('settings-back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets(
    'settings have one still preview and accessible persisted custom toggles',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final profile = await show(tester);
        expect(find.byType(CosmicScene), findsNothing);
        expect(find.byType(AuraScene), findsNothing);
        await openSection(tester, 'appearance');
        final scenes = tester.widgetList<AuraScene>(find.byType(AuraScene));
        expect(scenes, hasLength(1));
        expect(scenes.single.active, isFalse);
        await back(tester);
        await openSection(tester, 'senses');
        final toggle = find.byKey(const ValueKey('haptics-enabled'));
        await reach(tester, toggle);
        final data = tester.getSemantics(toggle).getSemanticsData();
        expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
        expect(data.flagsCollection.isToggled, ui.Tristate.isTrue);
        await tester.tap(toggle);
        await tester.pump();
        expect(profile.profile!.hapticsEnabled, isFalse);
        await close(tester);
      } finally {
        semantics.dispose();
      }
    },
  );
  testWidgets('English reminders stay unavailable in redesigned settings', (
    tester,
  ) async {
    await show(tester, language: 'en');
    await openSection(tester, 'reminders');
    final label = find.text('Remind me after the pause');
    await reach(tester, label);
    expect(
      find.text('Reminders are currently available in Russian.'),
      findsOneWidget,
    );
    final button = find.ancestor(of: label, matching: find.byType(TextButton));
    expect(tester.widget<TextButton>(button).onPressed, isNull);
    await close(tester);
  });
  testWidgets(
    'small screen and large text keep all settings sections readable',
    (tester) async {
      for (final language in ['ru', 'en']) {
        await show(
          tester,
          language: language,
          scale: 1.8,
          size: const Size(320, 568),
        );
        expect(tester.takeException(), isNull);
        for (final section in [
          'appearance',
          'senses',
          'personal',
          'reminders',
        ]) {
          await openSection(tester, section);
          if (section == 'appearance') {
            await reach(
              tester,
              find.byKey(const ValueKey('answer-style-constellation')),
            );
          } else if (section == 'personal') {
            await reach(tester, find.byKey(const ValueKey('settings-name')));
          }
          expect(tester.takeException(), isNull);
          await back(tester);
        }
        await close(tester);
      }
    },
  );
  testWidgets(
    'render the settings observatory and controls with bundled typography',
    (tester) async {
      await show(tester);
      Future<void> capture(String name) async {
        await settleAuraRaster(tester);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('settings-capture')),
        );
        await tester.runAsync(() async {
          final picture = await boundary.toImage(pixelRatio: 1);
          try {
            final data = await picture.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File('build/stage6-2/screens/$name.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
          } finally {
            picture.dispose();
          }
        });
      }

      await capture('settings-constellation');
      await openSection(tester, 'appearance');
      await capture('settings-space');
      await back(tester);
      await openSection(tester, 'personal');
      await reach(tester, find.byKey(const ValueKey('settings-name')));
      await capture('settings-personal');
      await back(tester);
      await openSection(tester, 'senses');
      await reach(tester, find.byKey(const ValueKey('ambient-enabled')));
      await capture('settings-senses');
      await back(tester);
      await openSection(tester, 'reminders');
      await capture('settings-reminders');
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'back returns to constellation; confirmed name and language survive sections',
    (tester) async {
      final profile = await show(tester);
      await openSection(tester, 'personal');
      await tester.enterText(
        find.byKey(const ValueKey('settings-name')),
        'Новая Астра',
      );
      await tester.tap(find.text('Сохранить имя'));
      await tester.pump();
      expect(profile.profile!.name, 'Новая Астра');
      await tester.ensureVisible(find.text('English'));
      await tester.tap(find.text('English'));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('settings-overview')), findsOneWidget);
      expect(find.text('Новая Астра'), findsOneWidget);
      expect(find.text('Personal'), findsOneWidget);
      await openSection(tester, 'reminders');
      expect(
        find.text('Reminders are currently available in Russian.'),
        findsOneWidget,
      );
      await back(tester);
      await openSection(tester, 'personal');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Новая Астра',
      );
      await close(tester);
    },
  );

  testWidgets(
    'leaving appearance disposes active preview; overview has no repeating frames',
    (tester) async {
      await show(tester);
      await openSection(tester, 'appearance');
      final button = find.byKey(const ValueKey('preview-animation'));
      await reach(tester, button);
      await tester.tap(button);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.widget<AuraScene>(find.byType(AuraScene)).active, isTrue);
      await back(tester);
      expect(find.byType(AuraScene), findsNothing);
      await tester.pump(const Duration(seconds: 8));
      expect(tester.binding.hasScheduledFrame, isFalse);
      await close(tester);
    },
  );
}
