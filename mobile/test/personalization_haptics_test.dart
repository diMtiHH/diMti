import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:universe_lab/aura_haptics.dart';
import 'package:universe_lab/personalization.dart';
import 'package:universe_lab/presentation_profile.dart';

class PreviewHaptics implements AuraHapticsBackend {
  final events = <String>[];
  @override
  Future<void> event(String event) async => events.add(event);
}

void main() {
  Future<void> show(
    WidgetTester tester,
    PreviewHaptics haptics,
    ValueNotifier<PresentationProfile> profile, {
    bool reduced = false,
  }) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: Scaffold(
            body: SingleChildScrollView(
              child: ValueListenableBuilder<PresentationProfile>(
                valueListenable: profile,
                builder: (_, value, _) => PersonalizationControls(
                  profile: value,
                  language: 'ru',
                  hapticsBackend: haptics,
                  onChanged: (value) => profile.value = value,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> start(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('preview-animation')));
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets('preview produces one animation pattern then one reveal', (
    tester,
  ) async {
    final haptics = PreviewHaptics();
    final profile = ValueNotifier(const PresentationProfile.defaults());
    addTearDown(profile.dispose);
    await show(tester, haptics, profile);
    expect(haptics.events.where((event) => event != 'cancel'), isEmpty);
    await start(tester);
    expect(haptics.events, ['animation']);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(haptics.events, ['animation', 'reveal']);
    await close(tester);
    expect(haptics.events.last, 'cancel');
  });

  testWidgets(
    'disabled preference suppresses preview and cancels an active pattern',
    (tester) async {
      final haptics = PreviewHaptics();
      final profile = ValueNotifier(PresentationProfile(hapticsEnabled: false));
      addTearDown(profile.dispose);
      await show(tester, haptics, profile);
      await start(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(haptics.events.where((event) => event != 'cancel'), isEmpty);
      profile.value = profile.value.copyWith(hapticsEnabled: true);
      await tester.pump();
      await start(tester);
      expect(haptics.events.where((event) => event != 'cancel'), ['animation']);
      profile.value = profile.value.copyWith(hapticsEnabled: false);
      await tester.pump();
      expect(haptics.events.last, 'cancel');
      await tester.pump(const Duration(seconds: 5));
      expect(haptics.events.where((event) => event != 'cancel'), ['animation']);
      await close(tester);
    },
  );

  testWidgets('background cancels preview and foreground never resumes it', (
    tester,
  ) async {
    final haptics = PreviewHaptics();
    final profile = ValueNotifier(const PresentationProfile.defaults());
    addTearDown(profile.dispose);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await show(tester, haptics, profile);
    await start(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(haptics.events.last, 'cancel');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 5));
    expect(haptics.events.where((event) => event != 'cancel'), ['animation']);
    await close(tester);
  });

  testWidgets('reduced motion uses a single short preview tap', (tester) async {
    final haptics = PreviewHaptics();
    final profile = ValueNotifier(const PresentationProfile.defaults());
    addTearDown(profile.dispose);
    await show(tester, haptics, profile, reduced: true);
    await start(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(haptics.events.where((event) => event != 'cancel'), ['tap']);
    await close(tester);
  });
}
