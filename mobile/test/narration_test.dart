import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universe_lab/narration.dart';

class TestNarrationBackend implements NarrationBackend {
  final plays = <({int id, String language})>[];
  final stops = <int>[];
  final polls = <int>[];
  final positions = <int, NarrationPosition>{};
  final positionGates = <int, Completer<NarrationPosition>>{};
  Completer<int>? playGate;
  Object? playError, positionError;
  int duration = 40000;
  int get id => plays.last.id;

  @override
  Future<int> play(int id, String language) async {
    plays.add((id: id, language: language));
    if (playError != null) throw playError!;
    final gate = playGate;
    if (gate != null) return gate.future;
    return duration;
  }

  @override
  Future<NarrationPosition> position(int id) async {
    polls.add(id);
    if (positionError != null) throw positionError!;
    final gate = positionGates[id];
    if (gate != null) return gate.future;
    return positions[id] ?? NarrationPosition(0, duration, true);
  }

  @override
  Future<void> stop(int id) async => stops.add(id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('text follows player position, not elapsed wall time', (
    tester,
  ) async {
    final backend = TestNarrationBackend();
    final controller = NarrationController(backend);
    const track = NarrationTrack(2500, [
      NarrationSegment('A🌟BC', 0, 1000),
      NarrationSegment('DEFG', 1500, 2500),
    ]);
    await controller.play('ru');
    await tester.pump(const Duration(seconds: 8));
    expect(controller.positionMs, 0);
    expect(track.visibleText(controller.positionMs), '');
    backend.positions[backend.id] = const NarrationPosition(500, 2500, true);
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.positionMs, 500);
    expect(track.visibleText(controller.positionMs), 'A🌟');
    await tester.pump(const Duration(seconds: 9));
    expect(track.visibleText(controller.positionMs), 'A🌟');
    backend.positions[backend.id] = const NarrationPosition(1200, 2500, true);
    await tester.pump(const Duration(milliseconds: 100));
    expect(track.visibleText(controller.positionMs), 'A🌟BC');
    backend.positions[backend.id] = const NarrationPosition(2000, 2500, true);
    await tester.pump(const Duration(milliseconds: 100));
    expect(track.visibleText(controller.positionMs), 'A🌟BC\n\nDE');
    controller.dispose();
  });

  testWidgets('completion keeps final text and stops polling', (tester) async {
    final backend = TestNarrationBackend();
    final controller = NarrationController(backend);
    await controller.play('en');
    backend.positions[backend.id] = NarrationPosition(
      backend.duration,
      backend.duration,
      false,
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.playing, isFalse);
    expect(controller.positionMs, backend.duration);
    final polls = backend.polls.length;
    await tester.pump(const Duration(seconds: 5));
    expect(backend.polls, hasLength(polls));
    expect(controller.failed, isFalse);
    controller.dispose();
  });

  testWidgets(
    'cancelling delayed playback cleans up again when play replies late',
    (tester) async {
      final backend = TestNarrationBackend()..playGate = Completer<int>();
      final controller = NarrationController(backend);
      final playing = controller.play('ru');
      await tester.pump();
      final id = backend.id;
      expect(controller.starting, isTrue);
      controller.stop();
      expect(controller.starting, isFalse);
      expect(controller.playing, isFalse);
      expect(backend.stops, contains(id));
      backend.playGate!.complete(30000);
      await playing;
      await tester.pump();
      expect(backend.stops.where((item) => item == id), hasLength(2));
      expect(controller.durationMs, 0);
      expect(controller.playing, isFalse);
      expect(backend.polls, isEmpty);
      controller.dispose();
    },
  );

  testWidgets(
    'new language ignores a late old player position and stops by id',
    (tester) async {
      final backend = TestNarrationBackend();
      final controller = NarrationController(backend);
      await controller.play('ru');
      final old = backend.id;
      final stale = Completer<NarrationPosition>();
      backend.positionGates[old] = stale;
      await tester.pump(const Duration(milliseconds: 100));
      await controller.play('en');
      final next = backend.id;
      expect(next, greaterThan(old));
      expect(backend.stops, contains(old));
      stale.complete(const NarrationPosition(39000, 40000, false));
      await tester.pump();
      expect(controller.playing, isTrue);
      expect(controller.positionMs, 0);
      backend.positions[next] = const NarrationPosition(700, 40000, true);
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.positionMs, 700);
      expect(backend.plays.map((play) => play.language), ['ru', 'en']);
      expect(backend.stops, isNot(contains(next)));
      controller.dispose();
    },
  );

  testWidgets(
    'play timeout bounds busy state and late success cannot restart audio',
    (tester) async {
      final backend = TestNarrationBackend()..playGate = Completer<int>();
      final controller = NarrationController(
        backend,
        deadline: const Duration(milliseconds: 300),
      );
      final playing = controller.play('ru');
      await tester.pump(const Duration(milliseconds: 301));
      await playing;
      expect(controller.failed, isTrue);
      expect(controller.starting, isFalse);
      expect(controller.playing, isFalse);
      final id = backend.id;
      backend.playGate!.complete(20000);
      await tester.pump();
      expect(backend.stops.where((item) => item == id), hasLength(2));
      expect(controller.failed, isTrue);
      expect(controller.playing, isFalse);
      controller.dispose();
    },
  );

  testWidgets('stalled position fails closed and stops the player', (
    tester,
  ) async {
    final backend = TestNarrationBackend();
    final controller = NarrationController(
      backend,
      deadline: const Duration(milliseconds: 300),
    );
    await controller.play('ru');
    final id = backend.id;
    final position = Completer<NarrationPosition>();
    backend.positionGates[id] = position;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 301));
    expect(controller.failed, isTrue);
    expect(controller.playing, isFalse);
    expect(backend.stops, contains(id));
    position.complete(const NarrationPosition(1000, 40000, true));
    await tester.pump();
    expect(controller.positionMs, 0);
    expect(controller.playing, isFalse);
    controller.dispose();
  });

  testWidgets('missing audio plugin leaves no player or automatic retry', (
    tester,
  ) async {
    final backend = TestNarrationBackend()
      ..playError = MissingPluginException();
    final controller = NarrationController(backend);
    await controller.play('ru');
    expect(controller.failed, isTrue);
    expect(controller.starting, isFalse);
    expect(controller.playing, isFalse);
    await tester.pump(const Duration(seconds: 10));
    expect(backend.plays, hasLength(1));
    expect(backend.polls, isEmpty);
    controller.dispose();
  });

  testWidgets(
    'dispose and controller recreation never reuse a playback identity',
    (tester) async {
      final backend = TestNarrationBackend()..playGate = Completer<int>();
      final first = NarrationController(backend);
      var notices = 0;
      first.addListener(() => ++notices);
      final starting = first.play('ru');
      final old = backend.id;
      first.dispose();
      final atDispose = notices;
      final gate = backend.playGate!;
      backend.playGate = null;
      final second = NarrationController(backend);
      await second.play('en');
      final next = backend.id;
      expect(next, greaterThan(old));
      gate.complete(20000);
      await starting;
      await tester.pump();
      expect(notices, atDispose);
      expect(second.playing, isTrue);
      expect(backend.stops, isNot(contains(next)));
      expect(backend.stops.where((id) => id == old), hasLength(2));
      second.dispose();
    },
  );

  testWidgets('synchronous cancellation listener prevents native play', (
    tester,
  ) async {
    final backend = TestNarrationBackend();
    final controller = NarrationController(backend);
    controller.addListener(() {
      if (controller.starting) controller.stop();
    });
    await controller.play('ru');
    expect(backend.plays, isEmpty);
    expect(controller.playing, isFalse);
    controller.dispose();
  });

  test(
    'bundled tracks have monotonic segments and complete readable text',
    () async {
      for (final language in ['ru', 'en']) {
        final track = await NarrationTrack.load(language);
        expect(track.durationMs, inInclusiveRange(1, 120000));
        expect(track.segments, isNotEmpty);
        var previous = 0;
        for (final segment in track.segments) {
          expect(segment.startMs, greaterThanOrEqualTo(previous));
          expect(segment.endMs, greaterThan(segment.startMs));
          expect(segment.endMs, lessThanOrEqualTo(track.durationMs));
          expect(segment.text.trim(), isNotEmpty);
          previous = segment.endMs;
        }
        expect(track.visibleText(-1), isEmpty);
        expect(track.visibleText(track.durationMs), track.text);
        expect(track.text, contains(language == 'ru' ? 'случайны' : 'random'));
        expect(
          track.text,
          contains(language == 'ru' ? 'тридцать минут' : 'thirty minutes'),
        );
      }
      await expectLater(NarrationTrack.load('xx'), throwsFormatException);
    },
  );

  group('native narration reply validation', () {
    const channel = IosNarrationBackend.channel;
    late IosNarrationBackend backend;
    Object? reply;
    final calls = <MethodCall>[];
    setUp(() {
      backend = IosNarrationBackend();
      reply = null;
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return reply;
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('valid calls use exact methods, language and playback id', () async {
      reply = {'durationMs': 20000};
      expect(await backend.play(42, 'en'), 20000);
      expect(calls.last.method, 'playNarration');
      expect(calls.last.arguments, {'id': 42, 'language': 'en'});
      reply = {'positionMs': 300, 'durationMs': 20000, 'playing': true};
      final position = await backend.position(42);
      expect(position.positionMs, 300);
      expect(position.durationMs, 20000);
      expect(position.playing, isTrue);
      expect(calls.last.arguments, {'id': 42});
      reply = null;
      await backend.stop(42);
      expect(calls.last.method, 'stopNarration');
      expect(calls.last.arguments, {'id': 42});
    });

    test(
      'missing, mistyped, out-of-range or extra play fields are rejected',
      () async {
        for (final invalid in [
          null,
          <String, Object?>{},
          {'durationMs': 0},
          {'durationMs': -1},
          {'durationMs': 120001},
          {'durationMs': 20.0},
          {'durationMs': true},
          {'durationMs': '20000'},
          {'durationMs': 20000, 'unknown': 1},
        ]) {
          reply = invalid;
          await expectLater(backend.play(1, 'ru'), throwsFormatException);
        }
      },
    );

    test(
      'missing, mistyped, impossible or extra position fields are rejected',
      () async {
        for (final invalid in [
          null,
          {'positionMs': 0, 'durationMs': 20000},
          {'positionMs': -1, 'durationMs': 20000, 'playing': true},
          {'positionMs': 2, 'durationMs': 1, 'playing': true},
          {'positionMs': 0, 'durationMs': 120001, 'playing': true},
          {'positionMs': 0, 'durationMs': -1, 'playing': false},
          {'positionMs': 0.0, 'durationMs': 20000, 'playing': true},
          {'positionMs': 0, 'durationMs': 20000.0, 'playing': true},
          {'positionMs': 0, 'durationMs': 20000, 'playing': 1},
          {'positionMs': 0, 'durationMs': 20000, 'playing': true, 'unknown': 1},
        ]) {
          reply = invalid;
          await expectLater(backend.position(1), throwsFormatException);
        }
        reply = {'positionMs': 0, 'durationMs': 0, 'playing': false};
        expect((await backend.position(1)).playing, isFalse);
      },
    );
  });
}
