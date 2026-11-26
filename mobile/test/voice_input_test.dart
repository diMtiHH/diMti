import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universe_lab/voice_input.dart';

class FakeVoiceBackend implements VoiceBackend {
  final stream = StreamController<VoiceEvent>.broadcast(sync: true);
  final starts = <(int, String)>[];
  final stops = <int>[];
  final cancels = <int>[];
  Future<void> Function(int, String)? onStart;
  Future<void> Function(int)? onStop;
  int disposals = 0;

  @override
  Stream<VoiceEvent> get events => stream.stream;
  @override
  Future<void> start({required int id, required String language}) {
    starts.add((id, language));
    return onStart?.call(id, language) ?? Future<void>.value();
  }

  @override
  Future<void> stop({required int id}) {
    stops.add(id);
    return onStop?.call(id) ?? Future<void>.value();
  }

  @override
  Future<void> cancel({required int id}) async => cancels.add(id);
  @override
  void dispose() => disposals++;

  int get id => starts.last.$1;
  void emit(VoiceEvent event) => stream.add(event);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  FakeVoiceBackend backend() {
    final value = FakeVoiceBackend();
    addTearDown(value.stream.close);
    return value;
  }

  VoiceInputController controller(
    FakeVoiceBackend backend, {
    Duration startTimeout = const Duration(seconds: 1),
    Duration stopTimeout = const Duration(seconds: 1),
  }) {
    final value = VoiceInputController(
      backend: backend,
      startTimeout: startTimeout,
      stopTimeout: stopTimeout,
    );
    addTearDown(value.dispose);
    return value;
  }

  test(
    'voice supplies editable text and level without automatic actions',
    () async {
      final b = backend(), c = controller(b);
      await c.start('ru', initialText: 'manual draft');
      expect(c.state, VoiceInputState.listening);
      expect(c.text, 'manual draft');
      expect(c.busy, isTrue);
      expect(c.recording, isTrue);
      b.emit(
        VoiceEvent(
          id: b.id,
          type: VoiceEventType.transcript,
          text: 'spoken draft',
        ),
      );
      b.emit(VoiceEvent(id: b.id, type: VoiceEventType.level, level: 0.6));
      expect(c.text, 'spoken draft');
      expect(c.level, 0.6);
      expect(b.stops, isEmpty);
      expect(b.cancels, isEmpty);
      b.emit(VoiceEvent(id: b.id, type: VoiceEventType.finished));
      expect(c.state, VoiceInputState.idle);
      expect(c.text, 'spoken draft');
      expect(c.level, 0);
      expect(c.busy, isFalse);
      expect(b.starts, hasLength(1));
      expect(b.stops, isEmpty);
      expect(b.cancels, isEmpty);
    },
  );

  test('stop acknowledgement waits for the final transcript event', () async {
    final b = backend(), c = controller(b);
    await c.start('en');
    var completed = false;
    final stopping = c.stop().then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(c.state, VoiceInputState.stopping);
    expect(c.busy, isTrue);
    expect(c.recording, isFalse);
    expect(completed, isFalse);
    b.emit(VoiceEvent(id: b.id, type: VoiceEventType.level, level: 1));
    expect(c.level, 0);
    b.emit(
      VoiceEvent(id: b.id, type: VoiceEventType.transcript, text: 'final text'),
    );
    b.emit(VoiceEvent(id: b.id, type: VoiceEventType.finished));
    await stopping;
    expect(c.text, 'final text');
    expect(c.state, VoiceInputState.idle);
    expect(b.stops, [b.id]);
  });

  test(
    'final event before stop reply survives its late platform error',
    () async {
      final b = backend(), c = controller(b);
      final reply = Completer<void>();
      b.onStop = (_) => reply.future;
      await c.start('ru');
      final stopping = c.stop();
      b.emit(
        VoiceEvent(id: b.id, type: VoiceEventType.finished, text: 'complete'),
      );
      await stopping;
      reply.completeError(PlatformException(code: 'failed'));
      await Future<void>.delayed(Duration.zero);
      expect(c.state, VoiceInputState.idle);
      expect(c.text, 'complete');
      expect(c.errorCode, isNull);
    },
  );

  test(
    'cancel invalidates delayed permission start before native reply',
    () async {
      final b = backend(), c = controller(b);
      final reply = Completer<void>();
      b.onStart = (_, _) => reply.future;
      final starting = c.start('ru', initialText: 'private draft');
      final old = b.id;
      expect(c.state, VoiceInputState.starting);
      final cancelled = c.cancel();
      expect(c.text, isEmpty);
      expect(c.busy, isFalse);
      b.emit(VoiceEvent(id: old, type: VoiceEventType.listening));
      b.emit(
        VoiceEvent(id: old, type: VoiceEventType.transcript, text: 'late text'),
      );
      b.emit(VoiceEvent(id: old, type: VoiceEventType.level, level: 1));
      await cancelled;
      reply.complete();
      await starting;
      await Future<void>.delayed(Duration.zero);
      expect(c.state, VoiceInputState.idle);
      expect(c.text, isEmpty);
      expect(c.level, 0);
      expect(b.cancels.where((id) => id == old).length, 2);
    },
  );

  test('restarting in a new language ignores every old event', () async {
    final b = backend(), c = controller(b);
    await c.start('ru');
    final old = b.id;
    await c.start('en', initialText: 'new draft');
    final current = b.id;
    expect(current, greaterThan(old));
    for (final event in [
      VoiceEvent(id: old, type: VoiceEventType.listening),
      VoiceEvent(id: old, type: VoiceEventType.transcript, text: 'old'),
      VoiceEvent(id: old, type: VoiceEventType.level, level: 1),
      VoiceEvent(id: old, type: VoiceEventType.finished),
      VoiceEvent(id: old, type: VoiceEventType.error, code: 'interrupted'),
    ]) {
      b.emit(event);
    }
    expect(c.state, VoiceInputState.listening);
    expect(c.text, 'new draft');
    expect(c.level, 0);
    expect(c.errorCode, isNull);
    expect(b.cancels, [old]);
    b.emit(
      VoiceEvent(id: current, type: VoiceEventType.transcript, text: 'new'),
    );
    expect(c.text, 'new');
  });

  test(
    'stalled start times out and cleans up a later successful reply',
    () async {
      final b = backend();
      final c = controller(b, startTimeout: const Duration(milliseconds: 5));
      final reply = Completer<void>();
      b.onStart = (_, _) => reply.future;
      await c.start('en', initialText: 'keep for manual editing');
      final old = b.id;
      expect(c.state, VoiceInputState.error);
      expect(c.errorCode, 'timeout');
      expect(c.busy, isFalse);
      reply.complete();
      await Future<void>.delayed(Duration.zero);
      b.emit(
        VoiceEvent(id: old, type: VoiceEventType.transcript, text: 'too late'),
      );
      expect(c.text, 'keep for manual editing');
      expect(b.cancels.where((id) => id == old).length, 2);
    },
  );

  for (final replyNeverArrives in [false, true]) {
    test(
      'missing final event bounds stop even when reply stalls=$replyNeverArrives',
      () async {
        final b = backend();
        final c = controller(b, stopTimeout: const Duration(milliseconds: 5));
        final reply = Completer<void>();
        if (replyNeverArrives) b.onStop = (_) => reply.future;
        await c.start('ru');
        b.emit(
          VoiceEvent(
            id: b.id,
            type: VoiceEventType.transcript,
            text: 'partial',
          ),
        );
        await c.stop();
        expect(c.state, VoiceInputState.error);
        expect(c.errorCode, 'timeout');
        expect(c.busy, isFalse);
        if (replyNeverArrives) reply.complete();
        b.emit(
          VoiceEvent(id: b.id, type: VoiceEventType.finished, text: 'late'),
        );
        expect(c.text, 'partial');
        expect(b.cancels, contains(b.id));
      },
    );
  }

  for (final code in [
    'permissionDenied',
    'unavailable',
    'interrupted',
    'failed',
  ]) {
    test(
      '$code leaves a manual draft without leaking platform details',
      () async {
        final b = backend(), c = controller(b);
        b.onStart = (_, _) => Future<void>.error(
          PlatformException(code: code, message: 'private platform details'),
        );
        await c.start('ru', initialText: 'manual draft');
        expect(c.state, VoiceInputState.error);
        expect(c.errorCode, code);
        expect(c.text, 'manual draft');
        expect(c.busy, isFalse);
        b.onStart = null;
        await c.start('en');
        b.emit(VoiceEvent(id: b.id, type: VoiceEventType.error, code: code));
        expect(c.state, VoiceInputState.error);
        expect(c.errorCode, code);
        expect(b.stops, isEmpty);
      },
    );
  }

  test(
    'missing plugin is unavailable and manual cancellation remains usable',
    () async {
      final b = backend(), c = controller(b);
      b.onStart = (_, _) => Future<void>.error(MissingPluginException());
      await c.start('en', initialText: 'manual draft');
      expect(c.errorCode, 'unavailable');
      expect(c.text, 'manual draft');
      await c.cancel();
      expect(c.state, VoiceInputState.idle);
      expect(c.text, isEmpty);
    },
  );

  test(
    'unknown failures use a fixed code and input bounds prevent native start',
    () async {
      final b = backend(), c = controller(b);
      await c.start('de');
      expect(c.errorCode, 'unavailable');
      await c.start('ru', initialText: 'x' * (maxVoiceTextLength + 1));
      expect(c.errorCode, 'failed');
      expect(c.text, isEmpty);
      expect(b.starts, isEmpty);
      b.onStart = (_, _) => Future<void>.error(StateError('private detail'));
      await c.start('ru');
      expect(c.errorCode, 'failed');
    },
  );

  test('malformed native events never become text or amplitude', () {
    for (final raw in <Object?>[
      null,
      [],
      {'id': 1},
      {'id': true, 'type': 'finished'},
      {'id': 1.0, 'type': 'finished'},
      {'id': 0, 'type': 'finished'},
      {'id': maxVoiceSessionId + 1, 'type': 'finished'},
      {'id': 1, 'type': 'unknown'},
      {'id': 1, 'type': 'transcript', 'text': 3},
      {'id': 1, 'type': 'transcript', 'text': 'x' * (maxVoiceTextLength + 1)},
      {'id': 1, 'type': 'level', 'level': double.nan},
      {'id': 1, 'type': 'level', 'level': double.infinity},
      {'id': 1, 'type': 'level', 'level': -0.1},
      {'id': 1, 'type': 'level', 'level': 1.1},
      {'id': 1, 'type': 'error', 'code': 'private detail'},
      {'id': 1, 'type': 'finished', 'question': 'unexpected'},
    ]) {
      expect(VoiceEvent.fromMap(raw), isNull, reason: '$raw');
    }
    expect(
      VoiceEvent.fromMap({'id': 1, 'type': 'level', 'level': 0})!.level,
      0,
    );
    expect(
      VoiceEvent.fromMap({'id': 1, 'type': 'level', 'level': 1})!.level,
      1,
    );
    expect(
      VoiceEvent.fromMap({'id': 1, 'type': 'transcript', 'text': ''})!.text,
      '',
    );
  });

  test('controller also rejects invalid typed events from a backend', () async {
    final b = backend(), c = controller(b);
    await c.start('en', initialText: 'unchanged');
    b.emit(VoiceEvent(id: b.id, type: VoiceEventType.transcript));
    b.emit(VoiceEvent(id: b.id, type: VoiceEventType.level, level: double.nan));
    b.emit(VoiceEvent(id: b.id, type: VoiceEventType.error, code: 'unknown'));
    expect(c.text, 'unchanged');
    expect(c.level, 0);
    expect(c.state, VoiceInputState.listening);
    b.stream.addError(StateError('private backend detail'));
    expect(c.state, VoiceInputState.error);
    expect(c.errorCode, 'failed');
  });

  test(
    'dispose invalidates pending start and IDs never repeat in a new owner',
    () async {
      final b = backend(), c = controller(b);
      final reply = Completer<void>();
      b.onStart = (_, _) => reply.future;
      final starting = c.start('ru', initialText: 'private');
      final old = b.id;
      var notifications = 0;
      c.addListener(() => notifications++);
      c.dispose();
      expect(c.text, isEmpty);
      expect(b.disposals, 1);
      reply.complete();
      await starting;
      b.emit(
        VoiceEvent(id: old, type: VoiceEventType.transcript, text: 'late'),
      );
      expect(notifications, 0);
      final newerBackend = backend(), newer = controller(newerBackend);
      await newer.start('en');
      expect(newerBackend.id, greaterThan(old));
      newerBackend.emit(VoiceEvent(id: old, type: VoiceEventType.finished));
      expect(newer.state, VoiceInputState.listening);
      expect(b.cancels, contains(old));
    },
  );

  test(
    'synchronous listener cancellation cannot launch a native start',
    () async {
      final b = backend(), c = controller(b);
      c.addListener(() {
        if (c.state == VoiceInputState.starting) unawaited(c.cancel());
      });
      await c.start('ru');
      expect(c.state, VoiceInputState.idle);
      expect(b.starts, isEmpty);
    },
  );

  test('iOS handler ownership preserves a replacement backend and validates events', () async {
    const channel = MethodChannel('ask_universe/voice/controller-test');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final first = VoiceInputController(
      backend: IosVoiceBackend(methodChannel: channel),
    );
    await first.start('ru');
    final oldId = (calls.last.arguments as Map)['id'] as int;
    final second = VoiceInputController(
      backend: IosVoiceBackend(methodChannel: channel),
    );
    addTearDown(() {
      first.dispose();
      second.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    });
    first.dispose();
    await second.start('en');
    final start = calls.lastWhere((call) => call.method == 'start');
    final id = (start.arguments as Map)['id'] as int;
    expect(id, greaterThan(oldId));
    expect(start.arguments, {'id': id, 'language': 'en'});
    Future<void> event(Object? raw) {
      final done = Completer<void>();
      ServicesBinding.instance.channelBuffers.push(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('voiceEvent', raw),
        ),
        (_) => done.complete(),
      );
      return done.future;
    }

    await event({'id': oldId, 'type': 'transcript', 'text': 'old'});
    await event({'id': id, 'type': 'level', 'level': double.nan});
    expect(second.text, isEmpty);
    expect(second.level, 0);
    await event({'id': id, 'type': 'transcript', 'text': 'current'});
    expect(second.text, 'current');
    final stopping = second.stop();
    expect(second.state, VoiceInputState.stopping);
    await event({'id': id, 'type': 'finished'});
    await stopping;
    expect(second.text, 'current');
    expect(second.state, VoiceInputState.idle);
    expect(calls.where((call) => call.method == 'stop').single.arguments, {
      'id': id,
    });
  });
}
