import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'presentation_profile.dart';

class NarrationSegment {
  final String text;
  final int startMs, endMs;
  const NarrationSegment(this.text, this.startMs, this.endMs);
}

class NarrationTrack {
  final int durationMs;
  final List<NarrationSegment> segments;
  const NarrationTrack(this.durationMs, this.segments);
  String get text => segments.map((s) => s.text).join('\n\n');

  static Future<NarrationTrack> load(String language) async {
    if (!const ['ru', 'en'].contains(language)) {
      throw const FormatException('Unsupported narration');
    }
    final data = jsonDecode(
      await rootBundle.loadString('assets/onboarding/narration.json'),
    );
    if (data['termsVersion'] != currentTermsVersion) {
      throw const FormatException('Narration terms version mismatch');
    }
    final value = data['languages'][language];
    return NarrationTrack(value['durationMs'] as int, [
      for (final item in value['segments'])
        NarrationSegment(
          item['text'] as String,
          item['startMs'] as int,
          item['endMs'] as int,
        ),
    ]);
  }

  String visibleText(int positionMs) {
    final parts = <String>[];
    for (final segment in segments) {
      if (positionMs < segment.startMs) break;
      if (positionMs >= segment.endMs) {
        parts.add(segment.text);
      } else {
        final runes = segment.text.runes.toList();
        final count =
            ((positionMs - segment.startMs) /
                    (segment.endMs - segment.startMs) *
                    runes.length)
                .floor();
        parts.add(
          String.fromCharCodes(runes.take(count.clamp(0, runes.length))),
        );
        break;
      }
    }
    return parts.join('\n\n');
  }
}

class NarrationPosition {
  final int positionMs, durationMs;
  final bool playing;
  const NarrationPosition(this.positionMs, this.durationMs, this.playing);
}

abstract interface class NarrationBackend {
  Future<int> play(int id, String language);
  Future<NarrationPosition> position(int id);
  Future<void> stop(int id);
}

class IosNarrationBackend implements NarrationBackend {
  static const channel = MethodChannel('ask_universe/presentation');
  @override
  Future<int> play(int id, String language) async {
    final value = await channel.invokeMapMethod<String, Object?>(
      'playNarration',
      {'id': id, 'language': language},
    );
    final duration = value?['durationMs'];
    if (value?.length != 1 ||
        duration is! int ||
        duration <= 0 ||
        duration > 120000) {
      throw const FormatException('Invalid narration duration');
    }
    return duration;
  }

  @override
  Future<NarrationPosition> position(int id) async {
    final value = await channel.invokeMapMethod<String, Object?>(
      'narrationPosition',
      {'id': id},
    );
    final position = value?['positionMs'],
        duration = value?['durationMs'],
        playing = value?['playing'];
    if (value?.length != 3 ||
        position is! int ||
        duration is! int ||
        playing is! bool ||
        position < 0 ||
        duration < 0 ||
        duration > 120000 ||
        position > duration) {
      throw const FormatException('Invalid narration position');
    }
    return NarrationPosition(position, duration, playing);
  }

  @override
  Future<void> stop(int id) =>
      channel.invokeMethod<void>('stopNarration', {'id': id});
}

/// Playback of shipped audio only. The timer follows the native player clock.
class NarrationController extends ChangeNotifier {
  static int _nextId = 0;
  final NarrationBackend backend;
  final Duration deadline;
  int? _id;
  Timer? _timer;
  bool _disposed = false, _polling = false;
  bool playing = false, starting = false, failed = false;
  int positionMs = 0, durationMs = 0;
  NarrationController(
    this.backend, {
    this.deadline = const Duration(seconds: 3),
  });
  bool _current(int id) => !_disposed && _id == id;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _stopNative(int id) async {
    try {
      await backend.stop(id).timeout(deadline);
    } catch (_) {}
  }

  Future<void> play(String language) async {
    stop();
    if (_disposed) return;
    final id = _id = ++_nextId;
    starting = true;
    failed = false;
    positionMs = 0;
    durationMs = 0;
    _notify();
    if (!_current(id)) return;
    try {
      final pending = backend.play(id, language);
      // A delayed start after cancellation cannot keep playing in the background.
      unawaited(
        pending.then((_) {
          if (!_current(id)) unawaited(_stopNative(id));
        }, onError: (Object _) {}),
      );
      final duration = await pending.timeout(deadline);
      if (!_current(id)) return;
      durationMs = duration;
      playing = true;
      starting = false;
      _notify();
      if (!_current(id)) return;
      _timer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => _poll(id),
      );
    } catch (_) {
      if (!_current(id)) return;
      stop();
      failed = true;
      _notify();
    }
  }

  Future<void> _poll(int id) async {
    if (!_current(id) || _polling) return;
    _polling = true;
    try {
      final value = await backend.position(id).timeout(deadline);
      if (!_current(id)) return;
      positionMs = value.positionMs;
      durationMs = value.durationMs;
      playing = value.playing;
      if (!playing) {
        _timer?.cancel();
        _timer = null;
      }
      _notify();
    } catch (_) {
      if (_current(id)) {
        stop();
        failed = true;
        _notify();
      }
    } finally {
      _polling = false;
    }
  }

  void stop() {
    final id = _id;
    _id = null;
    _timer?.cancel();
    _timer = null;
    playing = false;
    starting = false;
    if (id != null) unawaited(_stopNative(id));
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
