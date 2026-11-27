import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const ambientEnvironments = {'stars', 'galaxy', 'aurora', 'gravity'};
const ambientCueEvents = {'touch', 'transform', 'reveal'};

abstract interface class AmbientBackend {
  Stream<void> get interruptions;
  Future<void> play(String environment);
  Future<void> cue(String event);
  Future<void> stop();
  void dispose();
}

class IosAmbientBackend implements AmbientBackend {
  static const channel = MethodChannel('ask_universe/ambient');
  static IosAmbientBackend? _owner;
  final _interruptions = StreamController<void>.broadcast(sync: true);
  bool _disposed = false;
  IosAmbientBackend() {
    _owner = this;
    channel.setMethodCallHandler((call) async {
      if (!_disposed &&
          call.method == 'ambientEvent' &&
          call.arguments is Map &&
          call.arguments['type'] == 'interrupted') {
        _interruptions.add(null);
      }
    });
  }
  @override
  Stream<void> get interruptions => _interruptions.stream;
  @override
  Future<void> play(String environment) async {
    if (!ambientEnvironments.contains(environment)) {
      throw const FormatException('Unknown ambient environment');
    }
    await channel.invokeMethod<void>('play', {'environment': environment});
  }

  @override
  Future<void> stop() => channel.invokeMethod<void>('stop');
  @override
  Future<void> cue(String event) async {
    if (!ambientCueEvents.contains(event)) {
      throw const FormatException('Unknown ambient cue');
    }
    await channel.invokeMethod<void>('cue', {'event': event});
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (identical(_owner, this)) {
      _owner = null;
      channel.setMethodCallHandler(null);
    }
    unawaited(_interruptions.close());
  }
}

/// Shipped ambient playback is separate from voice input and onboarding speech.
/// A saved enabled preference may start on initial load. After interruption,
/// only a fresh explicit user intent can start another loop.
class AmbientController extends ChangeNotifier {
  final AmbientBackend backend;
  final Duration deadline;
  late final StreamSubscription<void> _subscription;
  Future<void> _tail = Future<void>.value();
  bool _disposed = false, _enabled = false, _active = false;
  bool _capturing = false, _allowed = true, _hasStarted = false;
  bool _nativeMayPlay = false;
  String _environment = 'aurora';
  String? _playingEnvironment;
  int _generation = 0;
  bool playing = false, failed = false, interrupted = false;
  (bool, bool, bool) _published = (false, false, false);

  AmbientController({
    AmbientBackend? backend,
    this.deadline = const Duration(seconds: 3),
  }) : backend = backend ?? IosAmbientBackend() {
    _subscription = this.backend.interruptions.listen((_) {
      if (_disposed) return;
      interrupted = true;
      ++_generation;
      playing = false;
      _nativeMayPlay = false;
      _playingEnvironment = null;
      _notify();
      unawaited(_enqueue());
    });
  }

  bool get _wantsPlay =>
      !_disposed &&
      _enabled &&
      _active &&
      !_capturing &&
      _allowed &&
      !interrupted &&
      ambientEnvironments.contains(_environment);

  void _notify() {
    final state = (playing, failed, interrupted);
    if (!_disposed && state != _published) {
      _published = state;
      notifyListeners();
    }
  }

  Future<void> sync({
    required bool enabled,
    required String environment,
    required bool active,
    required bool capturingSpeech,
    bool allowPlayback = true,
    bool userIntent = false,
  }) {
    if (_disposed) return Future<void>.value();
    final changed =
        _enabled != enabled ||
        _environment != environment ||
        _active != active ||
        _capturing != capturingSpeech ||
        _allowed != allowPlayback;
    if (userIntent && enabled && active && !capturingSpeech && allowPlayback) {
      interrupted = false;
      failed = false;
    }
    if (enabled &&
        (!active || capturingSpeech || !allowPlayback) &&
        (_hasStarted ||
            playing ||
            _nativeMayPlay ||
            (_enabled && (!active || capturingSpeech)))) {
      interrupted = true;
    }
    _enabled = enabled;
    _environment = environment;
    _active = active;
    _capturing = capturingSpeech;
    _allowed = allowPlayback;
    if (!ambientEnvironments.contains(environment)) {
      interrupted = true;
      failed = true;
    }
    if (changed || userIntent) {
      ++_generation;
      return _enqueue();
    }
    return _tail;
  }

  Future<void> _enqueue() {
    final next = _tail.then((_) => _reconcile());
    // Backend errors are handled by _reconcile. Keep disposal/timeout failures
    // from poisoning subsequent explicit user retries.
    _tail = next.catchError((Object _) {});
    return _tail;
  }

  /// Optional presentation feedback only. No answer/question enters this API.
  /// Queued feedback is discarded if settings, capture or lifecycle changes.
  Future<void> cue(String event) {
    if (!ambientCueEvents.contains(event) || !_wantsPlay || !playing) {
      return Future<void>.value();
    }
    final generation = _generation;
    final next = _tail.then((_) async {
      if (generation != _generation || !_wantsPlay || !playing) return;
      try {
        await backend.cue(event).timeout(deadline);
      } catch (_) {
        if (!_disposed) {
          failed = true;
          interrupted = true;
        }
        await _stop();
        _notify();
      }
    });
    _tail = next.catchError((Object _) {});
    return _tail;
  }

  Future<void> _stop() async {
    playing = false;
    _playingEnvironment = null;
    if (!_nativeMayPlay) return;
    try {
      await backend.stop().timeout(deadline);
      _nativeMayPlay = false;
    } catch (_) {
      if (!_disposed) {
        failed = true;
        interrupted = true;
      }
    }
  }

  Future<void> _reconcile() async {
    if (!_wantsPlay) {
      await _stop();
      _notify();
      return;
    }
    if (playing && _playingEnvironment == _environment) return;
    if (playing) await _stop();
    if (!_wantsPlay) {
      _notify();
      return;
    }
    final generation = _generation, environment = _environment;
    _hasStarted = true;
    _nativeMayPlay = true;
    try {
      // Native commands are serialized and play replies synchronously. Even
      // when its reply times out, stop is queued after play before any retry.
      await backend.play(environment).timeout(deadline);
      if (!_wantsPlay || generation != _generation) {
        await _stop();
      } else {
        playing = true;
        failed = false;
        _playingEnvironment = environment;
      }
    } catch (_) {
      if (!_disposed) {
        failed = true;
        interrupted = true;
      }
      await _stop();
    }
    _notify();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    unawaited(_subscription.cancel());
    unawaited(_enqueue().whenComplete(backend.dispose));
    super.dispose();
  }
}
