import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract interface class AuraHapticsBackend {
  Future<void> event(String event);
}

class IosAuraHapticsBackend implements AuraHapticsBackend {
  static const channel = MethodChannel('ask_universe/haptics');
  static int _nextOwner = 0;
  final int _owner = ++_nextOwner;
  @override
  Future<void> event(String event) async {
    try {
      await channel.invokeMethod<void>(event, {'owner': _owner});
    } on MissingPluginException {
      if (event == 'release' || event == 'reveal') {
        await HapticFeedback.mediumImpact();
      } else if (event != 'cancel') {
        await HapticFeedback.selectionClick();
      }
    }
  }
}

/// One bounded native pattern per gesture, cancelled when its owner is hidden.
class AuraHapticsController {
  final AuraHapticsBackend backend;
  final bool _supported;
  final Duration releaseDeadline;
  bool _enabled = true, _active = false, _disposed = false;
  int _generation = 0;
  Future<void> _tail = Future<void>.value();
  Future<void> get settled => _tail;
  AuraHapticsController({
    AuraHapticsBackend? backend,
    this.releaseDeadline = const Duration(milliseconds: 350),
  }) : backend = backend ?? IosAuraHapticsBackend(),
       _supported =
           backend != null ||
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);
  void configure({required bool enabled, required bool active}) {
    if (_disposed) return;
    if ((_enabled && !enabled) || (_active && !active)) cancel();
    _enabled = enabled;
    _active = active;
  }

  Future<void> _event(String event) {
    if (_disposed || !_supported || !_enabled || !_active) {
      return Future<void>.value();
    }
    final generation = _generation;
    _tail = _tail
        .then((_) async {
          if (!_disposed && _enabled && _active && generation == _generation) {
            await backend.event(event).timeout(const Duration(seconds: 2));
          }
        })
        .catchError((Object _) {});
    return _tail;
  }

  void tap() => unawaited(_event('tap'));
  void holdStart() => unawaited(_event('hold'));

  /// The native acknowledgement follows the release envelope. An audio-capture
  /// owner can await this before changing AVAudioSession to its recording mode,
  /// which suppresses haptics by default. Cosmetic feedback cannot block voice
  /// input indefinitely when the platform is unavailable or unresponsive.
  Future<void> holdRelease() async {
    final generation = _generation;
    try {
      await _event('release').timeout(releaseDeadline);
    } on TimeoutException {
      if (!_disposed && generation == _generation) cancel();
    }
  }

  void animationStart() => unawaited(_event('animation'));
  void reveal() => unawaited(_event('reveal'));
  void cancel() {
    ++_generation;
    if (!_supported) return;
    // Stop immediately and again behind any command that was already in flight.
    unawaited(backend.event('cancel').catchError((Object _) {}));
    _tail = _tail
        .then(
          (_) => backend.event('cancel').timeout(const Duration(seconds: 2)),
        )
        .catchError((Object _) {});
  }

  void dispose() {
    if (_disposed) return;
    cancel();
    _disposed = true;
  }
}
