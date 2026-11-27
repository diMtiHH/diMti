import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universe_lab/aura_haptics.dart';
import 'package:universe_lab/aura_motion.dart';

class HapticsProbe implements AuraHapticsBackend {
  final calls = <String>[];
  Completer<void>? blocked;
  Completer<void>? releaseBlocked;
  @override
  Future<void> event(String name) async {
    calls.add(name);
    if (name == 'hold' && blocked != null) await blocked!.future;
    if (name == 'release' && releaseBlocked != null)
      await releaseBlocked!.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  test(
    'haptics off never plays; hide cancels and discards queued release',
    () async {
      final backend = HapticsProbe(),
          h = AuraHapticsController(backend: HapticsProbe());
      h.dispose();
      await h.settled;
      final c = AuraHapticsController(backend: backend);
      c.configure(enabled: false, active: true);
      c.holdStart();
      c.holdRelease();
      c.animationStart();
      await c.settled;
      expect(backend.calls.where((x) => x != 'cancel'), isEmpty);
      c.configure(enabled: true, active: true);
      backend.blocked = Completer<void>();
      c.holdStart();
      await Future<void>.delayed(Duration.zero);
      c.holdRelease();
      c.configure(enabled: true, active: false);
      backend.blocked!.complete();
      await c.settled;
      expect(backend.calls.where((x) => x == 'hold'), hasLength(1));
      expect(backend.calls, isNot(contains('release')));
      expect(backend.calls.last, 'cancel');
      c.dispose();
      await c.settled;
    },
  );
  test(
    'one command per phase and disposal cancels rather than restarts',
    () async {
      final b = HapticsProbe(),
          c = AuraHapticsController(backend: HapticsProbe());
      c.dispose();
      await c.settled;
      final h = AuraHapticsController(backend: b)
        ..configure(enabled: true, active: true);
      h.holdStart();
      h.holdRelease();
      h.animationStart();
      h.reveal();
      await h.settled;
      expect(b.calls, ['hold', 'release', 'animation', 'reveal']);
      h.dispose();
      await h.settled;
      final n = b.calls.length;
      h.tap();
      h.animationStart();
      await h.settled;
      expect(b.calls.length, n);
    },
  );
  test('native haptic owners remain distinct for late page cleanup', () async {
    const channel = IosAuraHapticsBackend.channel;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (c) async {
      calls.add(c);
      return null;
    });
    final a = IosAuraHapticsBackend(), b = IosAuraHapticsBackend();
    await a.event('hold');
    await b.event('animation');
    await a.event('cancel');
    expect(calls[0].arguments, calls[2].arguments);
    expect(calls[0].arguments, isNot(calls[1].arguments));
    messenger.setMockMethodCallHandler(channel, null);
  });
  test(
    'release awaits the native impulse acknowledgement before audio capture',
    () async {
      final backend = HapticsProbe()..releaseBlocked = Completer<void>();
      final h = AuraHapticsController(backend: backend)
        ..configure(enabled: true, active: true);
      var captureMayStart = false;
      final release = h.holdRelease().then((_) => captureMayStart = true);
      await Future<void>.delayed(Duration.zero);
      expect(backend.calls, ['release']);
      expect(captureMayStart, isFalse);
      backend.releaseBlocked!.complete();
      await release;
      expect(captureMayStart, isTrue);
      h.dispose();
      await h.settled;
    },
  );
  test('unresponsive release cannot indefinitely block voice input', () async {
    final backend = HapticsProbe()..releaseBlocked = Completer<void>();
    final h = AuraHapticsController(
      backend: backend,
      releaseDeadline: const Duration(milliseconds: 8),
    )..configure(enabled: true, active: true);
    await h.holdRelease();
    expect(backend.calls, ['release', 'cancel']);
    backend.releaseBlocked!.complete();
    await h.settled;
    expect(backend.calls.last, 'cancel');
    h.dispose();
    await h.settled;
  });
  test(
    'disabled feedback adds no platform work to the release handoff',
    () async {
      final backend = HapticsProbe();
      final h = AuraHapticsController(backend: backend)
        ..configure(enabled: false, active: true);
      await h.settled;
      backend.calls.clear();
      await h.holdRelease();
      expect(backend.calls, isEmpty);
      h.dispose();
      await h.settled;
    },
  );
  group('motion', () {
    const channel = MethodChannel('tests/tilt');
    late AuraMotionController m;
    late List<String> calls;
    Future<void> send(Object? value) => messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall('tilt', value)),
      null,
    );
    setUp(() {
      calls = [];
      m = AuraMotionController(channel: channel, available: true);
      messenger.setMockMethodCallHandler(channel, (c) async {
        calls.add(c.method);
        return null;
      });
    });
    tearDown(() async {
      m.dispose();
      await m.settled;
      messenger.setMockMethodCallHandler(channel, null);
    });
    test(
      'two visible scenes own one sampler and the final release stops it',
      () async {
        m.acquire();
        m.acquire();
        await m.settled;
        expect(calls, ['start']);
        m.release();
        await m.settled;
        expect(m.leases, 1);
        expect(calls, ['start']);
        m.release();
        await m.settled;
        expect(calls, ['start', 'stop']);
        expect(m.value, Offset.zero);
      },
    );
    test(
      'finite motion is smooth and bounded; malformed samples preserve state',
      () async {
        m.acquire();
        await m.settled;
        await send([20, -20]);
        expect(m.value, const Offset(.22, -.22));
        final last = m.value;
        for (final invalid in [
          null,
          {},
          [],
          [1],
          [1, 2, 3],
          ['1', 0],
          [true, 0],
          [double.nan, 0],
          [0, double.infinity],
        ]) {
          await send(invalid);
          expect(m.value, last);
        }
        for (var i = 0; i < 100; i++) await send([20, -20]);
        expect(m.value.dx, inInclusiveRange(0, 1));
        expect(m.value.dy, inInclusiveRange(-1, 0));
      },
    );
    test('360 view transitions do not accumulate sampler leases', () async {
      for (var i = 0; i < 360; i++) {
        m.acquire();
        m.acquire();
        await m.settled;
        await send([.1, .2]);
        m.release();
        m.release();
        await m.settled;
        expect(m.leases, 0);
      }
      expect(calls.where((v) => v == 'start').length, 360);
      expect(calls.where((v) => v == 'stop').length, 360);
      expect(m.value, Offset.zero);
    });
    test(
      'late platform sample after disposal cannot notify listeners',
      () async {
        var updates = 0;
        m.addListener(() => updates++);
        m.acquire();
        await m.settled;
        m.dispose();
        await m.settled;
        await send([1, 1]);
        expect(updates, 0);
        expect(m.leases, 0);
      },
    );
    test('unavailable host performs no sampling', () async {
      m.dispose();
      await m.settled;
      m = AuraMotionController(channel: channel, available: false);
      m.acquire();
      m.release();
      await m.settled;
      expect(calls, isEmpty);
      expect(m.value, Offset.zero);
    });
    test(
      'unresponsive native start cannot permanently block release',
      () async {
        m.dispose();
        await m.settled;
        final blocker = Completer<void>();
        messenger.setMockMethodCallHandler(channel, (c) async {
          calls.add(c.method);
          if (c.method == 'start') await blocker.future;
          return null;
        });
        m = AuraMotionController(
          channel: channel,
          available: true,
          deadline: const Duration(milliseconds: 8),
        );
        m.acquire();
        await m.settled;
        m.release();
        await m.settled;
        blocker.complete();
        expect(calls, ['start', 'stop']);
      },
    );
  });
}
