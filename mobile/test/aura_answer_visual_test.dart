import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:universe_lab/aura_answer_page.dart';
import 'package:universe_lab/aura_renderer.dart';
import 'package:universe_lab/cosmic_theme.dart';
import 'package:universe_lab/presentation_profile.dart';
import 'package:universe_lab/session_core.dart';

import 'session_core_test.dart' show Fixture;

// This isolated core fixture is the only source of an allowed question. The
// production gate is not changed, and the visual route never chooses a result.
class _AnswerFixture {
  final core = Fixture();
  final navigator = GlobalKey<NavigatorState>();
  final boundary = GlobalKey();
  final interaction = AuraInteractionController();
  int acknowledgements = 0;
  Answer answer = Answer.yes;
  String language = 'ru';
  String get question => language == 'ru'
      ? 'Стоит ли мне сегодня почитать роман?'
      : 'Should I read a novel today?';

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(430, 932),
    double scale = 1,
    bool reducedMotion = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await core.start();
    core.random.value = answer == Answer.yes ? 49 : 50;
    await core.answer();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          navigatorKey: navigator,
          debugShowCheckedModeBanner: false,
          theme: cosmicTheme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: reducedMotion,
            ),
            child: child!,
          ),
          home: const Scaffold(body: Text('Fixture home')),
        ),
      ),
    );
    await open(tester);
  }

  Future<void> open(WidgetTester tester) async {
    navigator.currentState!.push<void>(
      PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, __, ___) => AuraAnswerPage(
          answer: answer,
          question: question,
          language: language,
          profile: const PresentationProfile.defaults(),
          session: core.session,
          interaction: interaction,
          onVisible: () async {
            if (core.session.phase == SessionPhase.pending) {
              ++acknowledgements;
              await core.session.acknowledgeShown();
            }
          },
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> finishReveal(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    interaction.dispose();
  }
}

void main() {
  var assetsReady = false;
  setUp(
    () => TestWidgetsFlutterBinding.ensureInitialized()
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );
  tearDown(
    () => TestWidgetsFlutterBinding.ensureInitialized()
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );

  Future<void> assets(WidgetTester tester) async {
    if (assetsReady) return;
    await tester.runAsync(() async {
      await warmUpAuraShaders();
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
    assetsReady = true;
  }

  Finder getAnswer() => find.byKey(const ValueKey('answer'));
  double fraction(WidgetTester tester) {
    final dynamic painter = tester
        .widget<CustomPaint>(find.byKey(const ValueKey('answer-ring-paint')))
        .painter;
    return painter.fraction as double;
  }

  testWidgets(
    'localized neutral result is above its question and pause label',
    (tester) async {
      await assets(tester);
      final colors = <Color?>[];
      for (final language in ['ru', 'en']) {
        for (final answer in Answer.values) {
          final f = _AnswerFixture()
            ..language = language
            ..answer = answer;
          await f.mount(tester);
          await f.finishReveal(tester);
          final label = language == 'ru'
              ? (answer == Answer.yes ? 'Да' : 'Нет')
              : (answer == Answer.yes ? 'Yes' : 'No');
          final text = tester.widget<Text>(getAnswer());
          expect(text.data, label);
          colors.add(text.style!.color);
          expect(
            find.text(
              language == 'ru' ? 'Ответ Вселенной' : 'Answer from the Universe',
            ),
            findsOneWidget,
          );
          expect(
            find.text(
              language == 'ru'
                  ? 'До следующего вопроса'
                  : 'Until your next question',
            ),
            findsOneWidget,
          );
          expect(
            tester.getBottomLeft(getAnswer()).dy,
            lessThan(
              tester
                  .getTopLeft(find.byKey(const ValueKey('answer-question')))
                  .dy,
            ),
          );
          expect(f.core.random.calls, 1);
          expect(f.acknowledgements, 1);
          expect(tester.takeException(), isNull);
          await f.close(tester);
        }
      }
      expect(colors.toSet(), hasLength(1));
    },
  );

  testWidgets(
    'reveal changes fade blur spacing; reopen never acknowledges twice',
    (tester) async {
      await assets(tester);
      final f = _AnswerFixture();
      await f.mount(tester);
      final fade = find
          .ancestor(of: getAnswer(), matching: find.byType(Opacity))
          .first;
      final filter = find
          .ancestor(of: getAnswer(), matching: find.byType(ImageFiltered))
          .first;
      expect(tester.widget<Opacity>(fade).opacity, 0);
      expect(f.acknowledgements, 0);
      expect(f.core.session.phase, SessionPhase.pending);
      final initialFilter = tester.widget<ImageFiltered>(filter).imageFilter;
      final initialSpacing = tester
          .widget<Text>(getAnswer())
          .style!
          .letterSpacing!;
      await tester.pump(const Duration(milliseconds: 160));
      await tester.pump();
      expect(tester.widget<Opacity>(fade).opacity, inExclusiveRange(0, 1));
      expect(
        tester.widget<ImageFiltered>(filter).imageFilter,
        isNot(initialFilter),
      );
      expect(
        tester.widget<Text>(getAnswer()).style!.letterSpacing!,
        lessThan(initialSpacing),
      );
      expect(f.acknowledgements, 1);
      await f.finishReveal(tester);
      expect(tester.widget<Opacity>(fade).opacity, 1);
      expect(
        tester.widget<Text>(getAnswer()).style!.letterSpacing,
        closeTo(.3, .0001),
      );
      final durable = f.core.store.value;
      final writes = f.core.store.writes.length;
      await tester.tap(find.byKey(const ValueKey('close-answer')));
      await tester.pump();
      f.core.clock.advance(1200);
      await f.core.session.refresh();
      await f.open(tester);
      await f.finishReveal(tester);
      expect(f.acknowledgements, 1);
      expect(f.core.random.calls, 1);
      expect(f.core.store.value, durable);
      expect(f.core.store.writes, hasLength(writes));
      await f.close(tester);
    },
  );

  testWidgets(
    'ring interpolates the authoritative remaining time without a new deadline',
    (tester) async {
      await assets(tester);
      final f = _AnswerFixture();
      await f.mount(tester);
      await f.finishReveal(tester);
      final durable = f.core.store.value;
      final writes = f.core.store.writes.length;
      expect(fraction(tester), 1);
      f.core.clock.advance(180000);
      await f.core.session.refresh();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('27:00'), findsOneWidget);
      expect(fraction(tester), closeTo(1, .0001));
      await tester.pump(const Duration(milliseconds: 450));
      expect(fraction(tester), closeTo(.95, .005));
      await tester.pump(const Duration(milliseconds: 450));
      expect(fraction(tester), closeTo(.9, .0001));
      expect(f.core.session.remainingMs, 1620000);
      expect(f.core.store.value, durable);
      expect(f.core.store.writes, hasLength(writes));
      expect(f.acknowledgements, 1);
      await f.close(tester);
    },
  );

  testWidgets(
    'reduced motion presents immediately and updates ring without interpolation',
    (tester) async {
      await assets(tester);
      final f = _AnswerFixture();
      await f.mount(tester, reducedMotion: true);
      await tester.pump();
      expect(f.acknowledgements, 1);
      final fade = find
          .ancestor(of: getAnswer(), matching: find.byType(Opacity))
          .first;
      expect(tester.widget<Opacity>(fade).opacity, 1);
      f.core.clock.advance(180000);
      await f.core.session.refresh();
      await tester.pump(const Duration(seconds: 1));
      expect(fraction(tester), closeTo(.9, .0001));
      expect(
        tester
            .widget<TweenAnimationBuilder<double>>(
              find.byKey(const ValueKey('answer-ring')),
            )
            .duration,
        Duration.zero,
      );
      await f.close(tester);
    },
  );

  testWidgets(
    'inactive before visible frame removes private route and preserves pending',
    (tester) async {
      await assets(tester);
      final f = _AnswerFixture();
      await f.mount(tester);
      final durable = f.core.store.value;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(AuraAnswerPage), findsNothing);
      expect(find.text(f.question), findsNothing);
      expect(f.acknowledgements, 0);
      expect(f.core.session.phase, SessionPhase.pending);
      expect(f.core.store.value, durable);
      await f.close(tester);
    },
  );

  testWidgets(
    'capture answer at iPhone width and compact screen with large text',
    (tester) async {
      await assets(tester);
      for (final largeText in [false, true]) {
        final f = _AnswerFixture()..language = largeText ? 'en' : 'ru';
        await f.mount(
          tester,
          size: largeText ? const Size(320, 568) : const Size(430, 932),
          scale: largeText ? 2 : 1,
        );
        await f.finishReveal(tester);
        expect(tester.takeException(), isNull);
        expect(
          tester.getRect(find.byKey(const ValueKey('close-answer'))).right,
          lessThanOrEqualTo(tester.view.physicalSize.width),
        );
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(f.boundary),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          try {
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            final output = File(
              'build/stage6/screens/answer-${largeText ? 'compact-large-text' : 'iphone'}.png',
            );
            await output.parent.create(recursive: true);
            await output.writeAsBytes(png!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
        await tester.ensureVisible(
          find.text(
            largeText ? 'Return to the Universe' : 'Вернуться во Вселенную',
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        if (largeText) {
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            try {
              final png = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                'build/stage6/screens/answer-compact-large-text-timer.png',
              ).writeAsBytes(png!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
        expect(f.acknowledgements, 1);
        await f.close(tester);
      }
    },
  );
}
