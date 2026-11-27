import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universe_lab/aura_power_budget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/aura-graphics-budget');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AuraPowerBudget policy;
  late List<MethodCall> calls;
  Object? initial;
  Completer<Object?>? response;
  bool failStart = false;

  Map<String, Object> state(String thermal, [bool lowPower = false]) => {
    'thermalState': thermal,
    'lowPowerMode': lowPower,
  };
  Future<void> send(Object? value, {String method = 'budgetChanged'}) async {
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall(method, value)),
      null,
    );
  }

  setUp(() {
    calls = [];
    initial = state('nominal');
    response = null;
    failStart = false;
    policy = AuraPowerBudget(channel: channel);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'start') {
        if (failStart) throw MissingPluginException();
        return response == null ? initial : await response!.future;
      }
      return null;
    });
  });
  tearDown(() async {
    if (response != null && !response!.isCompleted) response!.complete(initial);
    policy.dispose();
    await policy.settled;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'thermal and low-power policy clamps all eight allowed combinations',
    () async {
      void listener() {}
      policy.addListener(listener);
      await policy.settled;
      for (final entry in const [
        ('nominal', false, 1.0, 60),
        ('fair', false, .8, 45),
        ('serious', false, .5, 30),
        ('critical', false, .3, 20),
        ('nominal', true, .6, 30),
        ('fair', true, .6, 30),
        ('serious', true, .5, 30),
        ('critical', true, .3, 20),
      ]) {
        await send(state(entry.$1, entry.$2));
        expect(policy.qualityCap, entry.$3);
        expect(policy.maxFps, entry.$4);
      }
      expect(calls.map((call) => call.method), ['start']);
      expect(calls.single.arguments, isNull);
    },
  );

  test(
    'malformed or unrelated native updates cannot relax a valid restriction',
    () async {
      initial = state('critical');
      var notifications = 0;
      policy.addListener(() => notifications++);
      await policy.settled;
      expect(notifications, 1);
      for (final invalid in [
        null,
        '',
        [],
        {},
        {'thermalState': 'nominal'},
        {'thermalState': 'nominal', 'lowPowerMode': 0},
        {'thermalState': 0, 'lowPowerMode': false},
        state('unknown'),
        {...state('nominal'), 'temperature': 0},
      ]) {
        await send(invalid);
      }
      await send(state('nominal'), method: 'unrelated');
      expect(policy.qualityCap, .3);
      expect(policy.maxFps, 20);
      expect(notifications, 1);
    },
  );

  test(
    'shared listeners register once and unsubscribe when the last leaves',
    () async {
      void first() {}
      void second() {}
      policy.addListener(first);
      policy.addListener(second);
      await policy.settled;
      policy.removeListener(first);
      await policy.settled;
      expect(calls.map((call) => call.method), ['start']);
      policy.removeListener(second);
      await policy.settled;
      expect(calls.map((call) => call.method), ['start', 'stop']);
      await send(state('critical'));
      expect(policy.qualityCap, 1);
      initial = state('fair', true);
      policy.addListener(first);
      await policy.settled;
      expect(calls.map((call) => call.method), ['start', 'stop', 'start']);
      expect(policy.qualityCap, .6);
      expect(policy.maxFps, 30);
    },
  );

  test('a newer notification wins over a delayed initial response', () async {
    response = Completer<Object?>();
    policy.addListener(() {});
    await Future<void>.delayed(Duration.zero);
    await send(state('serious'));
    response!.complete(state('nominal'));
    await policy.settled;
    expect(policy.qualityCap, .5);
    expect(policy.maxFps, 30);
  });

  test(
    'dispose invalidates pending response and sends native unsubscribe',
    () async {
      response = Completer<Object?>();
      var notifications = 0;
      policy.addListener(() => notifications++);
      await Future<void>.delayed(Duration.zero);
      policy.dispose();
      response!.complete(state('critical'));
      await policy.settled;
      await send(state('fair'));
      expect(notifications, 0);
      expect(calls.map((call) => call.method), ['start', 'stop']);
    },
  );

  test(
    'unsupported host leaves the visual policy usable without fabricated state',
    () async {
      failStart = true;
      policy.addListener(() {});
      await policy.settled;
      expect(policy.qualityCap, 1);
      expect(policy.maxFps, 60);
      policy.dispose();
      await policy.settled;
      expect(calls.map((call) => call.method), ['start', 'stop']);
    },
  );

  test('bounded native response cannot block disposal indefinitely', () async {
    policy.dispose();
    policy = AuraPowerBudget(
      channel: channel,
      deadline: const Duration(milliseconds: 8),
    );
    response = Completer<Object?>();
    policy.addListener(() {});
    await policy.settled;
    policy.dispose();
    await policy.settled;
    expect(calls.map((call) => call.method), ['start', 'stop']);
    response!.complete(state('critical'));
    await Future<void>.delayed(Duration.zero);
    expect(policy.qualityCap, 1);
  });
}
