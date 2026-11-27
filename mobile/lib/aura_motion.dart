import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Shared read-only device motion. A listener owns a lease; the last release
/// stops native sampling. Data is neither persisted nor sent to any service.
class AuraMotionController extends ChangeNotifier {
  static final instance = AuraMotionController();
  final MethodChannel channel;
  final bool available;
  final Duration deadline;
  bool _disposed = false;
  int _leases = 0, _generation = 0;
  Offset value = Offset.zero;
  Future<void> _tail = Future<void>.value();
  AuraMotionController({
    MethodChannel? channel,
    bool? available,
    this.deadline = const Duration(seconds: 2),
  }) : channel = channel ?? const MethodChannel('ask_universe/motion'),
       available =
           available ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);
  int get leases => _leases;
  Future<void> get settled => _tail;
  void acquire() {
    if (_disposed || !available || ++_leases != 1) return;
    channel.setMethodCallHandler((call) async {
      if (_leases == 0 || call.method != 'tilt') return;
      final a = call.arguments;
      if (a is! List || a.length != 2 || a.any((v) => v is! num || !v.isFinite))
        return;
      final target = Offset(
        (a[0] as num).toDouble().clamp(-1, 1),
        (a[1] as num).toDouble().clamp(-1, 1),
      );
      final next = Offset.lerp(value, target, .22)!;
      if ((next - value).distance < .001) return;
      value = next;
      notifyListeners();
    });
    final generation = ++_generation;
    _tail = _tail
        .then((_) async {
          if (_leases > 0 && generation == _generation) {
            await channel.invokeMethod<void>('start').timeout(deadline);
          }
        })
        .catchError((Object _) {});
  }

  void release() {
    if (!available || _leases == 0 || --_leases != 0) return;
    ++_generation;
    value = Offset.zero;
    channel.setMethodCallHandler(null);
    _tail = _tail
        .then((_) => channel.invokeMethod<void>('stop').timeout(deadline))
        .catchError((Object _) {});
  }

  @override
  void dispose() {
    if (_disposed) return;
    if (_leases > 0) {
      _leases = 1;
      release();
    }
    _disposed = true;
    super.dispose();
  }
}
