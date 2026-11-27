import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:universe_lab/aura_renderer.dart';
import 'package:universe_lab/aura_power_budget.dart';

void main() {
  const boundaryKey = ValueKey('aura-render');
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await warmUpAuraShaders();
  });

  Widget app(
    AuraInteractionController controller, {
    String form = 'livingMatter',
    String environment = 'aurora',
    AuraPhase phase = AuraPhase.idle,
    double progress = 0,
    bool active = true,
    bool reduced = true,
    bool enabled = true,
    bool background = false,
    AuraPowerBudget? powerBudget,
    VoidCallback? tap,
    VoidCallback? feedback,
  }) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Center(
        child: RepaintBoundary(
          key: boundaryKey,
          child: SizedBox.square(
            dimension: 260,
            child: AuraTouchSurface(
              interaction: controller,
              label: 'Open question input',
              phase: phase,
              active: active,
              enabled: enabled,
              onShortTap: tap,
              onTouchFeedback: feedback,
              child: AuraScene(
                background: environment,
                form: form,
                phase: phase,
                progress: progress,
                interaction: controller,
                powerBudget: powerBudget,
                active: active,
                showBackground: background,
                formAlignment: Alignment.center,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Future<Uint8List> pixels(WidgetTester tester) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(boundaryKey),
    );
    return (await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        return Uint8List.fromList(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    }))!;
  }

  testWidgets(
    'down responds immediately; only a short stationary release opens input',
    (tester) async {
      final controller = AuraInteractionController();
      var opens = 0, feedback = 0;
      await tester.pumpWidget(
        app(controller, tap: () => opens++, feedback: () => feedback++),
      );
      final point = tester.getCenter(find.byType(AuraTouchSurface));
      final gesture = await tester.startGesture(point);
      expect(controller.pressed, isTrue);
      expect(controller.pressure, greaterThan(0));
      expect(opens, 0);
      expect(feedback, 1);
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      expect(opens, 1);
      expect(controller.pressed, isFalse);
      expect(controller.release, 1);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    'holding, dragging and pointer cancellation never open or confirm a question',
    (tester) async {
      final controller = AuraInteractionController();
      var opens = 0;
      await tester.pumpWidget(app(controller, tap: () => opens++));
      final point = tester.getCenter(find.byType(AuraTouchSurface));
      final hold = await tester.startGesture(point);
      await tester.pump(const Duration(milliseconds: 450));
      expect(controller.hold, greaterThan(0));
      await hold.up();
      expect(opens, 0);
      final drag = await tester.startGesture(point);
      await drag.moveTo(point + const Offset(55, -30));
      expect(controller.point.dx, greaterThan(0));
      await drag.moveTo(point);
      await drag.up();
      expect(opens, 0); // Returning to the origin does not erase drag history.
      final cancel = await tester.startGesture(point);
      await cancel.cancel();
      expect(controller.pressed, isFalse);
      expect(controller.pressure, 0);
      expect(opens, 0);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  for (final phase in [
    AuraPhase.questionInput,
    AuraPhase.questionConfirmation,
    AuraPhase.safetyValidation,
    AuraPhase.answerAnimation,
    AuraPhase.cooldown,
  ]) {
    testWidgets(
      '${phase.name} permits visual exploration without opening input',
      (tester) async {
        final controller = AuraInteractionController();
        var opens = 0;
        await tester.pumpWidget(
          app(controller, phase: phase, tap: () => opens++),
        );
        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(AuraTouchSurface)),
        );
        expect(controller.pressure, greaterThan(0));
        await gesture.up();
        expect(opens, 0);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
    );
  }

  testWidgets('replacing the interaction owner cancels the old gesture', (
    tester,
  ) async {
    final first = AuraInteractionController();
    final next = AuraInteractionController();
    var opens = 0;
    await tester.pumpWidget(app(first, tap: () => opens++));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(AuraTouchSurface)),
    );
    expect(first.pressed, isTrue);
    await tester.pumpWidget(app(next, tap: () => opens++));
    expect(first.pressed, isFalse);
    expect(first.pressure, 0);
    expect(next.pressed, isFalse);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(opens, 0);
    expect(next.hold, 0);
    await tester.pumpWidget(const SizedBox());
    first.dispose();
    next.dispose();
  });

  testWidgets('background and phase change cancel a gesture before release', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final controller = AuraInteractionController();
    var opens = 0;
    await tester.pumpWidget(app(controller, tap: () => opens++));
    final point = tester.getCenter(find.byType(AuraTouchSurface));
    final first = await tester.startGesture(point);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(controller.pressure, 0);
    await first.up();
    expect(opens, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    final second = await tester.startGesture(point);
    await tester.pumpWidget(
      app(controller, phase: AuraPhase.safetyValidation, tap: () => opens++),
    );
    await second.up();
    expect(opens, 0);
    expect(controller.pressed, isFalse);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets(
    'disabled hit surface exposes no action and invokes no feedback',
    (tester) async {
      final controller = AuraInteractionController();
      final semantics = tester.ensureSemantics();
      var opens = 0, feedback = 0;
      await tester.pumpWidget(
        app(
          controller,
          enabled: false,
          tap: () => opens++,
          feedback: () => feedback++,
        ),
      );
      expect(
        tester.semantics.find(find.bySemanticsLabel('Open question input')),
        isSemantics(isButton: false, hasTapAction: false),
      );
      await tester.tap(find.byType(AuraTouchSurface));
      expect(opens, 0);
      expect(feedback, 0);
      expect(controller.pressure, 0);
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
      controller.dispose();
    },
  );

  testWidgets(
    'shared layers advance one visual clock and retain it on rebuild',
    (tester) async {
      final controller = AuraInteractionController();
      Widget layers(bool visible) => MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: false),
          child: Stack(
            children: [
              AuraScene(
                background: 'stars',
                interaction: controller,
                showForm: false,
                active: visible,
                child: const SizedBox.expand(),
              ),
              Center(
                child: SizedBox.square(
                  dimension: 100,
                  child: AuraScene(
                    background: 'stars',
                    interaction: controller,
                    showBackground: false,
                    active: visible,
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(layers(true));
      await tester.pump(const Duration(milliseconds: 20));
      final first = controller.elapsed;
      await tester.pump(const Duration(milliseconds: 20));
      expect(controller.elapsed - first, closeTo(.020, .001));
      final before = controller.elapsed;
      await tester.pumpWidget(layers(true));
      expect(controller.elapsed, greaterThanOrEqualTo(before));
      await tester.pumpWidget(layers(false));
      final stopped = controller.elapsed;
      await tester.pump(const Duration(seconds: 30));
      expect(controller.elapsed, stopped);
      await tester.pumpWidget(layers(true));
      expect(controller.elapsed - stopped, lessThanOrEqualTo(.051));
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets('OS power budget caps actual painter quality and frame cadence', (
    tester,
  ) async {
    final controller = AuraInteractionController();
    const channel = MethodChannel('test/renderer-graphics-budget');
    final policy = AuraPowerBudget(channel: channel);
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      if (call.method == 'start') {
        return {'thermalState': 'critical', 'lowPowerMode': false};
      }
      return null;
    });
    try {
      await tester.pumpWidget(
        app(controller, reduced: false, powerBudget: policy),
      );
      await policy.settled;
      await tester.pump(const Duration(milliseconds: 60));
      final painter =
          tester
                  .widget<CustomPaint>(
                    find.byWidgetPredicate(
                      (widget) =>
                          widget is CustomPaint &&
                          widget.painter is AuraPainter,
                    ),
                  )
                  .painter!
              as AuraPainter;
      expect(painter.qualityCap, .3);
      final previous = controller.elapsed;
      await tester.pump(const Duration(milliseconds: 20));
      expect(controller.elapsed, previous);
      await tester.pump(const Duration(milliseconds: 20));
      expect(controller.elapsed, previous);
      await tester.pump(const Duration(milliseconds: 20));
      expect(controller.elapsed, greaterThan(previous));
      expect(calls.where((value) => value == 'start'), hasLength(1));
    } finally {
      await tester.pumpWidget(const SizedBox());
      await policy.settled;
      policy.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
      controller.dispose();
    }
    expect(calls, contains('stop'));
  });

  testWidgets('non-answer phases ignore stray transition progress', (
    tester,
  ) async {
    final controller = AuraInteractionController();
    await tester.pumpWidget(
      app(
        controller,
        form: 'liquidMetal',
        phase: AuraPhase.safetyValidation,
        progress: 0,
      ),
    );
    await tester.pumpAndSettle();
    final before = await pixels(tester);
    await tester.pumpWidget(
      app(
        controller,
        form: 'liquidMetal',
        phase: AuraPhase.safetyValidation,
        progress: .65,
      ),
    );
    await tester.pumpAndSettle();
    expect(await pixels(tester), orderedEquals(before));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets(
    'living forms occupy their allocated area without edge clipping',
    (tester) async {
      final controller = AuraInteractionController();
      for (final form in auraForms) {
        await tester.pumpWidget(app(controller, form: form));
        await tester.pumpAndSettle();
        final data = await pixels(tester);
        var left = 260, right = -1, top = 260, bottom = -1;
        for (var y = 0; y < 260; ++y) {
          for (var x = 0; x < 260; ++x) {
            if (data[(y * 260 + x) * 4 + 3] <= 16) continue;
            if (x < left) left = x;
            if (x > right) right = x;
            if (y < top) top = y;
            if (y > bottom) bottom = y;
          }
        }
        expect(
          (right - left + 1) / 260,
          inInclusiveRange(.60, .95),
          reason: '$form has visible width ${right - left + 1}/260',
        );
        expect(left, greaterThan(0));
        expect(right, lessThan(259));
        expect(top, greaterThan(0));
        expect(bottom, lessThan(259));
      }
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  for (final form in auraForms) {
    testWidgets(
      '$form has a distinct response to explicit animation progress',
      (tester) async {
        final controller = AuraInteractionController();
        await tester.pumpWidget(app(controller, form: form));
        await tester.pumpAndSettle();
        final idle = await pixels(tester);
        await tester.pumpWidget(
          app(
            controller,
            form: form,
            phase: AuraPhase.answerAnimation,
            progress: .6,
          ),
        );
        await tester.pumpAndSettle();
        expect(await pixels(tester), isNot(orderedEquals(idle)));
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
    );
  }

  testWidgets('render large living forms for visual material review', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controllers = List.generate(4, (_) => AuraInteractionController());
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: RepaintBoundary(
            key: boundaryKey,
            child: Row(
              children: [
                for (var i = 0; i < 4; ++i)
                  Expanded(
                    child: AuraScene(
                      background: auraEnvironments[i],
                      form: auraForms[i],
                      interaction: controllers[i],
                      formAlignment: Alignment.center,
                      child: const SizedBox.expand(),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(boundaryKey),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.5);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/stage6/living-forms.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
    await tester.pumpWidget(const SizedBox());
    for (final controller in controllers) {
      controller.dispose();
    }
  });
}
