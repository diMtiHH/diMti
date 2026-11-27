import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Read-only OS policy. No temperatures, personal data or telemetry are collected.
class AuraPowerBudget extends ChangeNotifier {
  static final instance = AuraPowerBudget();
  static const platformChannel = MethodChannel('ask_universe/graphicsBudget');
  final MethodChannel channel;
  final Duration deadline;
  final bool _supported;
  Future<void> _tail = Future<void>.value();
  bool _disposed = false, _observing = false, _lowPower = false;
  int _generation = 0, _eventRevision = 0;
  String _thermal = 'nominal';

  AuraPowerBudget({
    MethodChannel? channel,
    this.deadline = const Duration(seconds: 2),
  }) : channel = channel ?? platformChannel,
       _supported = channel != null || (!kIsWeb && Platform.isIOS);

  double get qualityCap {
    final thermal = switch (_thermal) {
      'fair' => .8,
      'serious' => .5,
      'critical' => .3,
      _ => 1.0,
    };
    return _lowPower ? math.min(thermal, .6) : thermal;
  }

  int get maxFps {
    final thermal = switch (_thermal) {
      'fair' => 45,
      'serious' => 30,
      'critical' => 20,
      _ => 60,
    };
    return _lowPower ? math.min(thermal, 30) : thermal;
  }

  @visibleForTesting
  Future<void> get settled => _tail;

  void _accept(Object? value) {
    if (value is! Map ||
        value.length != 2 ||
        !value.containsKey('thermalState') ||
        !value.containsKey('lowPowerMode'))
      return;
    final thermal = value['thermalState'], lowPower = value['lowPowerMode'];
    if (thermal is! String ||
        lowPower is! bool ||
        !const {'nominal', 'fair', 'serious', 'critical'}.contains(thermal))
      return;
    if (_thermal == thermal && _lowPower == lowPower) return;
    _thermal = thermal;
    _lowPower = lowPower;
    if (!_disposed) notifyListeners();
  }

  void _queue(Future<void> Function() action) {
    _tail = _tail.then((_) => action()).catchError((Object _) {});
  }

  void _start() {
    if (!_supported) return;
    _observing = true;
    final generation = ++_generation;
    channel.setMethodCallHandler((call) async {
      if (!_disposed &&
          _observing &&
          generation == _generation &&
          call.method == 'budgetChanged') {
        ++_eventRevision;
        _accept(call.arguments);
      }
    });
    _queue(() async {
      if (_disposed || !_observing || generation != _generation) return;
      final revision = _eventRevision;
      try {
        final value = await channel
            .invokeMethod<Object?>('start')
            .timeout(deadline);
        // A newer notification may arrive before the initial response.
        if (!_disposed &&
            _observing &&
            generation == _generation &&
            revision == _eventRevision)
          _accept(value);
      } catch (_) {
        // Desktop/widget harnesses have no iOS service. Keep the last valid
        // policy; never turn unavailable OS data into fake thermal measurements.
      }
    });
  }

  void _stop() {
    if (!_observing) return;
    _observing = false;
    ++_generation;
    channel.setMethodCallHandler(null);
    _queue(() async {
      try {
        await channel.invokeMethod<void>('stop').timeout(deadline);
      } catch (_) {
        /* Unsupported host or already-destroyed native engine. */
      }
    });
  }

  @override
  void addListener(VoidCallback listener) {
    if (_disposed) return;
    super.addListener(listener);
    if (!_observing) _start();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!_disposed && !hasListeners) _stop();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _stop();
    _disposed = true;
    super.dispose();
  }
}
