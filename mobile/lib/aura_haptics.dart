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
  bool _enabled = true, _active = false, _disposed = false;
  int _generation = 0;
  Future<void> _tail = Future<void>.value();
  Future<void> get settled => _tail;
  AuraHapticsController({AuraHapticsBackend? backend})
    : backend = backend ?? IosAuraHapticsBackend(),
      _supported =
          backend != null ||
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);
  void configure({required bool enabled, required bool active}) {
    if (_disposed) return;
    if ((_enabled && !enabled) || (_active && !active)) cancel();
    _enabled = enabled;
    _active = active;
  }

  void _event(String event) {
    if (_disposed || !_supported || !_enabled || !_active) return;
    final generation = _generation;
    _tail = _tail
        .then((_) async {
          if (!_disposed && _enabled && _active && generation == _generation) {
            await backend.event(event).timeout(const Duration(seconds: 2));
          }
        })
        .catchError((Object _) {});
  }

  void tap() => _event('tap');
  void holdStart() => _event('hold');
  void holdRelease() => _event('release');
  void animationStart() => _event('animation');
  void reveal() => _event('reveal');
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
