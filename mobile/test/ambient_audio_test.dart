import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universe_lab/ambient_audio.dart';

class TestAmbientBackend implements AmbientBackend {
  final events = StreamController<void>.broadcast(sync: true);
  final plays = <String>[];
  final cues = <String>[];
  int stops = 0;
  bool disposed = false;
  Completer<void>? playGate;
  Completer<void>? cueGate;
  Object? playError, cueError;
  @override
  Stream<void> get interruptions => events.stream;
  @override
  Future<void> play(String environment) async {
    plays.add(environment);
    if (playError != null) throw playError!;
    final gate = playGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> cue(String event) async {
    cues.add(event);
    if (cueError != null) throw cueError!;
    if (cueGate != null) await cueGate!.future;
  }

  @override
  void dispose() {
    disposed = true;
    unawaited(events.close());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> sync(
    AmbientController controller, {
    bool enabled = true,
    String environment = 'aurora',
    bool active = true,
    bool capture = false,
    bool allowed = true,
    bool intent = false,
  }) => controller.sync(
    enabled: enabled,
    environment: environment,
    active: active,
    capturingSpeech: capture,
    allowPlayback: allowed,
    userIntent: intent,
  );

  test(
    'disabled is silent and stable enabled preferences do not restart loops',
    () async {
      final backend = TestAmbientBackend();
      final controller = AmbientController(backend: backend);
      await sync(controller, enabled: false);
      expect(backend.plays, isEmpty);
      expect(backend.stops, 0);
      await sync(controller);
      expect(backend.plays, ['aurora']);
      expect(controller.playing, isTrue);
      for (var i = 0; i < 8; i++) {
        await sync(controller);
      }
      expect(backend.plays, hasLength(1));
      await sync(controller, environment: 'galaxy', intent: true);
      expect(backend.plays, ['aurora', 'galaxy']);
      expect(backend.stops, 1);
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(backend.disposed, isTrue);
    },
  );

  test('background latches silence until a new explicit user intent', () async {
    final backend = TestAmbientBackend();
    final controller = AmbientController(backend: backend);
    await sync(controller);
    await sync(controller, active: false);
    expect(controller.playing, isFalse);
    expect(controller.interrupted, isTrue);
    await sync(controller);
    expect(backend.plays, hasLength(1));
    await sync(controller, intent: true);
    expect(controller.playing, isTrue);
    expect(controller.interrupted, isFalse);
    expect(backend.plays, hasLength(2));
    controller.dispose();
  });

  test(
    'microphone and onboarding playback take priority without auto restart',
    () async {
      final backend = TestAmbientBackend();
      final controller = AmbientController(backend: backend);
      await sync(controller);
      await sync(controller, capture: true, intent: true);
      expect(controller.playing, isFalse);
      await sync(controller);
      expect(backend.plays, hasLength(1));
      await sync(controller, intent: true);
      await sync(controller, allowed: false);
      expect(controller.playing, isFalse);
      await sync(controller);
      expect(backend.plays, hasLength(2));
      await sync(controller, intent: true);
      expect(backend.plays, hasLength(3));
      controller.dispose();
    },
  );

  test('native interruption cannot be undone by a routine rebuild', () async {
    final backend = TestAmbientBackend();
    final controller = AmbientController(backend: backend);
    await sync(controller);
    backend.events.add(null);
    await sync(controller);
    expect(controller.interrupted, isTrue);
    expect(controller.playing, isFalse);
    expect(backend.plays, hasLength(1));
    await sync(controller, intent: true);
    expect(backend.plays, hasLength(2));
    expect(controller.playing, isTrue);
    controller.dispose();
  });

  test(
    'disable while native start is pending stops after that command',
    () async {
      final backend = TestAmbientBackend()..playGate = Completer<void>();
      final controller = AmbientController(backend: backend);
      final first = sync(controller);
      await Future<void>.delayed(Duration.zero);
      expect(backend.plays, ['aurora']);
      final disabled = sync(controller, enabled: false);
      backend.playGate!.complete();
      await first;
      await disabled;
      expect(controller.playing, isFalse);
      expect(backend.stops, 1);
      controller.dispose();
    },
  );

  test(
    'play timeout stops the native command and requires explicit retry',
    () async {
      final backend = TestAmbientBackend()..playGate = Completer<void>();
      final controller = AmbientController(
        backend: backend,
        deadline: const Duration(milliseconds: 8),
      );
      await sync(controller);
      expect(controller.failed, isTrue);
      expect(controller.interrupted, isTrue);
      expect(controller.playing, isFalse);
      expect(backend.stops, 1);
      await sync(controller);
      expect(backend.plays, hasLength(1));
      backend.playGate!.complete();
      backend.playGate = null;
      await sync(controller, intent: true);
      expect(controller.failed, isFalse);
      expect(controller.playing, isTrue);
      controller.dispose();
    },
  );

  test(
    'malformed environment and failed native playback remain silent',
    () async {
      final backend = TestAmbientBackend();
      final controller = AmbientController(backend: backend);
      await sync(controller, environment: '../voice.wav');
      expect(backend.plays, isEmpty);
      expect(controller.failed, isTrue);
      backend.playError = StateError('synthetic');
      await sync(controller, intent: true);
      expect(controller.failed, isTrue);
      expect(controller.playing, isFalse);
      controller.dispose();
    },
  );

  test('dispose during pending playback releases native audio without notification', () async {
    final backend = TestAmbientBackend()..playGate = Completer<void>();
    final controller = AmbientController(backend: backend);
    var changes = 0;
    controller.addListener(() => changes++);
    final pending = sync(controller);
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
    backend.playGate!.complete();
    await pending;
    await Future<void>.delayed(Duration.zero);
    expect(backend.stops, 1);
    expect(backend.disposed, isTrue);
    expect(changes, 0);
  });

  test(
    'cues require active enabled playback and never restart interrupted audio',
    () async {
      final backend = TestAmbientBackend();
      final controller = AmbientController(backend: backend);
      await controller.cue('touch');
      expect(backend.cues, isEmpty);
      await sync(controller);
      for (final event in ambientCueEvents) {
        await controller.cue(event);
      }
      expect(backend.cues, ['touch', 'transform', 'reveal']);
      await controller.cue('yes');
      await controller.cue('../voice.wav');
      await sync(controller, capture: true);
      await controller.cue('reveal');
      await sync(controller);
      await controller.cue('touch');
      expect(backend.cues, hasLength(3));
      await sync(controller, intent: true);
      await controller.cue('touch');
      expect(backend.cues, hasLength(4));
      await sync(controller, enabled: false);
      await controller.cue('transform');
      expect(backend.cues, hasLength(4));
      controller.dispose();
    },
  );

  test('queued cues are discarded by a later lifecycle generation', () async {
    final backend = TestAmbientBackend();
    final controller = AmbientController(backend: backend);
    await sync(controller);
    backend.cueGate = Completer<void>();
    final first = controller.cue('touch');
    await Future<void>.delayed(Duration.zero);
    final stale = controller.cue('reveal');
    final paused = sync(controller, active: false);
    backend.cueGate!.complete();
    await Future.wait([first, stale, paused]);
    expect(backend.cues, ['touch']);
    expect(controller.playing, isFalse);
    expect(backend.stops, 1);
    controller.dispose();
  });

  test('a cue failure stops audio and requires an explicit retry', () async {
    final backend = TestAmbientBackend()..cueError = StateError('fixture');
    final controller = AmbientController(backend: backend);
    await sync(controller);
    await controller.cue('transform');
    expect(controller.playing, isFalse);
    expect(controller.failed, isTrue);
    expect(controller.interrupted, isTrue);
    expect(backend.stops, 1);
    await sync(controller);
    expect(backend.plays, hasLength(1));
    controller.dispose();
  });

  test(
    'platform channel sends only allowlisted environments cues and stop',
    () async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(IosAmbientBackend.channel, (
        call,
      ) async {
        calls.add(call);
        return null;
      });
      final backend = IosAmbientBackend();
      try {
        await backend.play('stars');
        await backend.cue('reveal');
        await backend.stop();
        await expectLater(
          backend.play('https://invalid.example/file.wav'),
          throwsFormatException,
        );
        await expectLater(backend.cue('yes'), throwsFormatException);
        await expectLater(
          backend.cue('https://invalid.example/file.wav'),
          throwsFormatException,
        );
        expect(calls.map((call) => call.method), ['play', 'cue', 'stop']);
        expect(calls.first.arguments, {'environment': 'stars'});
        expect(calls[1].arguments, {'event': 'reveal'});
        expect(calls.last.arguments, isNull);
      } finally {
        backend.dispose();
        messenger.setMockMethodCallHandler(IosAmbientBackend.channel, null);
      }
    },
  );
}
