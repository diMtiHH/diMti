import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'engine.dart';

/// Holds the model on one isolate; only fixed status codes and measurements
/// come back to the UI. Requests are serialized.
class ModelWorker {
  final _events = ReceivePort();
  final _ready = Completer<SendPort>();
  Isolate? _isolate;
  SendPort? _commands;
  Completer<Reading>? _pending;
  bool _closed = false;
  int loadMs = 0;
  bool get available => !_closed && _commands != null;

  ModelWorker() {
    _events.listen((event) {
      if (event is (SendPort, int) && !_ready.isCompleted) {
        loadMs = event.$2;
        _commands = event.$1;
        _ready.complete(event.$1);
      } else if (event is Reading && _pending != null) {
        _pending!.complete(event);
        _pending = null;
      } else {
        _fail();
      }
    });
  }

  Future<void> start(String directory) async {
    final ready = _ready.future.timeout(const Duration(minutes: 2));
    // Attach the future listener before spawning; startup errors can arrive early.
    await Future.wait<void>([
      ready.then<void>((_) {}),
      Isolate.spawn(
            _serve,
            (_events.sendPort, directory),
            onExit: _events.sendPort,
            onError: _events.sendPort,
          )
          .then<void>((isolate) {
            _isolate = isolate;
            if (_closed) isolate.kill();
          })
          .catchError((Object _) {
            _fail();
          }),
    ]);
  }

  Future<Reading> inspect(String text, String language) async {
    final port = _commands;
    if (_closed || port == null || _pending != null) {
      return const Reading(Outcome.error, 'unavailable');
    }
    final reply = _pending = Completer<Reading>();
    port.send((text, language));
    return reply.future.timeout(
      const Duration(seconds: 45),
      onTimeout: () {
        _fail();
        return const Reading(Outcome.error, 'timeout');
      },
    );
  }

  void _fail() {
    if (_closed) return;
    _closed = true;
    if (!_ready.isCompleted)
      _ready.completeError(StateError('Model unavailable'));
    _pending?.complete(const Reading(Outcome.error, 'unavailable'));
    _pending = null;
    _events.close();
    _isolate?.kill();
  }

  void close() {
    if (_closed) return;
    if (!_ready.isCompleted || _pending != null) {
      _fail();
      return;
    }
    _closed = true;
    _ready.future.then((port) => port.send(null), onError: (Object _) {});
    _events.close();
  }
}

Future<void> _serve((SendPort, String) init) async {
  final (reply, path) = init;
  final requests = ReceivePort();
  LocalEngine? engine;
  try {
    final watch = Stopwatch()..start();
    engine = await LocalEngine.open(Directory(path));
    reply.send((requests.sendPort, watch.elapsedMilliseconds));
    await for (final message in requests) {
      if (message == null) break;
      final (text, language) = message as (String, String);
      reply.send(engine.inspect(text, language));
    }
  } catch (_) {
    reply.send(false);
  } finally {
    requests.close();
    await engine?.close();
  }
}
