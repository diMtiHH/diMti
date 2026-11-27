import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:universe_lab/aura_renderer.dart';
import 'package:universe_lab/cosmic_theme.dart';
import 'package:universe_lab/narration.dart';
import 'package:universe_lab/onboarding_page.dart';
import 'package:universe_lab/personalization.dart';
import 'package:universe_lab/presentation_profile.dart';

import 'narration_test.dart' show TestNarrationBackend;
import 'presentation_profile_test.dart' show MemoryPresentationBackend;

class _Controls extends StatefulWidget {
  const _Controls({super.key});
  @override
  State<_Controls> createState() => _ControlsState();
}

class _ControlsState extends State<_Controls> {
  PresentationProfile profile = const PresentationProfile.defaults();
  String language = 'ru';
  bool active = true, busy = false, commit = true;
  final changes = <PresentationProfile>[];
  void update(VoidCallback action) => setState(action);
  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: cosmicTheme,
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: PersonalizationControls(
          profile: profile,
          language: language,
          active: active,
          busy: busy,
          onChanged: (next) => setState(() {
            changes.add(next);
            if (commit) {
              profile = next;
            } else {
              busy = true;
            }
          }),
        ),
      ),
    ),
  );
}

void main() {
  var shadersReady = false;
  setUp(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: false);
  });
  tearDown(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    binding.platformDispatcher.clearAccessibilityFeaturesTestValue();
  });

  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
  }

  Future<_ControlsState> controls(WidgetTester tester) async {
    tester.view.physicalSize = const Size(430, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    if (!shadersReady) {
      await tester.runAsync(() async {
        await warmUpAuraShaders();
      });
      shadersReady = true;
    }
    final key = GlobalKey<_ControlsState>();
    await tester.pumpWidget(_Controls(key: key));
    await flush(tester);
    return key.currentState!;
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await flush(tester);
  }

  List<AuraScene> scenes(WidgetTester tester) =>
      tester.widgetList<AuraScene>(find.byType(AuraScene)).toList();
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets('one static combined preview and labeled independent selectors', (
    tester,
  ) async {
    final state = await controls(tester);
    expect(
      tester.getSize(find.byKey(const ValueKey('appearance-preview'))).height,
      224,
    );
    expect(scenes(tester), hasLength(1));
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('Полярное сияние'), findsOneWidget);
    expect(find.text('Живая материя'), findsOneWidget);
    expect(scenes(tester).where((scene) => scene.active), isEmpty);
    for (final name in ['stars', 'galaxy', 'aurora', 'gravity']) {
      final size = tester.getSize(find.byKey(ValueKey('background-$name')));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    }
    state.update(() => state.language = 'en');
    await flush(tester);
    expect(find.text('Space'), findsOneWidget);
    expect(find.text('Answer form'), findsOneWidget);
    expect(find.text('Aurora'), findsOneWidget);
    expect(find.text('Living Matter'), findsOneWidget);
    expect(find.text('Preview animation'), findsOneWidget);
    expect(state.changes, isEmpty);
    await close(tester);
  });

  testWidgets(
    'arrows swipe and dots change only the intended independent preference',
    (tester) async {
      final state = await controls(tester);
      await tap(tester, 'background-next');
      expect(state.profile.background, PresentationBackground.gravity);
      expect(state.profile.answerStyle, PresentationAnswerStyle.livingMatter);
      await tap(tester, 'answer-style-next');
      expect(state.profile.answerStyle, PresentationAnswerStyle.liquidMetal);
      expect(state.profile.background, PresentationBackground.gravity);
      await tester.drag(
        find.byKey(const ValueKey('answer-style-carousel')),
        const Offset(-320, 0),
      );
      await flush(tester);
      expect(state.profile.answerStyle, PresentationAnswerStyle.infinity);
      final before = state.changes.length;
      await tap(tester, 'background-stars');
      expect(state.profile.background, PresentationBackground.stars);
      expect(state.profile.answerStyle, PresentationAnswerStyle.infinity);
      expect(state.changes.length, before + 1);
      expect(state.profile.completed, isFalse);
      expect(state.profile.termsVersion, 0);
      await close(tester);
    },
  );

  testWidgets('all16 combinations reach their independent preview scene', (
    tester,
  ) async {
    final state = await controls(tester);
    for (final background in PresentationBackground.values) {
      for (final form in PresentationAnswerStyle.values) {
        state.update(
          () => state.profile = state.profile.copyWith(
            background: background,
            answerStyle: form,
          ),
        );
        await flush(tester);
        final scene = scenes(tester).singleWhere((scene) => scene.showForm);
        expect(scene.background, background.name);
        expect(scene.form, form.name);
        expect(scene.preview, isTrue);
      }
    }
    expect(state.changes, isEmpty);
    await close(tester);
  });

  testWidgets(
    'preview runs4.5seconds without writing preferences or revealing an answer',
    (tester) async {
      final state = await controls(tester);
      final original = state.profile;
      await tester.tap(find.byKey(const ValueKey('preview-animation')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 2200));
      var scene = scenes(tester).singleWhere((scene) => scene.showForm);
      expect(scene.phase, AuraPhase.answerAnimation);
      expect(scene.progress, closeTo(2200 / 4500, .01));
      expect(scenes(tester).where((scene) => scene.active).length, 1);
      expect(state.changes, isEmpty);
      expect(state.profile, original);
      for (final key in [
        'answer',
        'cooldown',
        'question-input',
        'confirm-question',
      ]) {
        expect(find.byKey(ValueKey(key)), findsNothing);
      }
      await tester.pump(const Duration(milliseconds: 2200));
      expect(
        scenes(tester).singleWhere((scene) => scene.showForm).phase,
        AuraPhase.answerAnimation,
      );
      await tester.pump(const Duration(milliseconds: 110));
      scene = scenes(tester).singleWhere((scene) => scene.showForm);
      expect(scene.phase, AuraPhase.idle);
      expect(state.changes, isEmpty);
      await close(tester);
    },
  );

  for (final hidden in [false, true]) {
    testWidgets(
      '${hidden ? 'hidden parent' : 'background'} cancels preview without automatic replay',
      (tester) async {
        final state = await controls(tester);
        await tap(tester, 'preview-animation');
        if (hidden) {
          state.update(() => state.active = false);
        } else {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
        }
        await tester.pump();
        expect(scenes(tester).where((scene) => scene.active), isEmpty);
        if (hidden) {
          state.update(() => state.active = true);
        } else {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        }
        await flush(tester);
        final scene = scenes(tester).singleWhere((scene) => scene.showForm);
        expect(scene.phase, AuraPhase.idle);
        expect(scene.progress, 0);
        expect(state.changes, isEmpty);
        await close(tester);
      },
    );
  }

  testWidgets(
    'busy save blocks interaction and rejected save restores the confirmed page once',
    (tester) async {
      final state = await controls(tester);
      state.commit = false;
      await tap(tester, 'background-next');
      expect(state.busy, isTrue);
      expect(state.changes, hasLength(1));
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('preview-animation')),
            )
            .onPressed,
        isNull,
      );
      await tester.drag(
        find.byKey(const ValueKey('answer-style-carousel')),
        const Offset(-320, 0),
      );
      await flush(tester);
      expect(state.changes, hasLength(1));
      state.update(() => state.busy = false);
      await flush(tester);
      expect(find.text('Полярное сияние'), findsOneWidget);
      expect(state.changes, hasLength(1));
      await close(tester);
    },
  );

  testWidgets(
    'reduced motion completes a quiet preview without changing preferences',
    (tester) async {
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      final state = await controls(tester);
      await tester.tap(find.byKey(const ValueKey('preview-animation')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        scenes(tester).singleWhere((scene) => scene.showForm).phase,
        AuraPhase.idle,
      );
      expect(state.changes, isEmpty);
      await close(tester);
    },
  );

  testWidgets(
    'standalone onboarding observes persisted steps and consent without a shell',
    (tester) async {
      tester.view.physicalSize = const Size(430, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = MemoryPresentationBackend();
      final controller = PresentationController(backend);
      final narration = TestNarrationBackend();
      await controller.load();
      await tester.pumpWidget(
        MaterialApp(
          theme: cosmicTheme,
          home: OnboardingPage(
            controller: controller,
            language: 'ru',
            onLanguage: (_) async {},
            narrationBackend: narration,
          ),
        ),
      );
      await tester.runAsync(() => NarrationTrack.load('ru'));
      await flush(tester);
      expect(find.text('1 / 3'), findsOneWidget);
      await tester.tap(find.text('Пропустить'));
      await flush(tester);
      expect(find.text('2 / 3'), findsOneWidget);
      expect(narration.plays, isEmpty);
      await tester.ensureVisible(find.text('Продолжить'));
      await tester.tap(find.text('Продолжить'));
      await flush(tester);
      expect(find.text('3 / 3'), findsOneWidget);
      expect(narration.plays, hasLength(1));
      backend.writeGate = Completer<void>();
      await tester.ensureVisible(find.text('Я понимаю и принимаю'));
      await tester.tap(find.text('Я понимаю и принимаю'));
      await flush(tester);
      expect(controller.profile!.completed, isFalse);
      expect(controller.busy, isTrue);
      backend.writeGate!.complete();
      await flush(tester);
      expect(controller.profile!.completed, isTrue);
      expect(narration.stops, contains(narration.id));
      await close(tester);
      controller.dispose();
    },
  );
}
