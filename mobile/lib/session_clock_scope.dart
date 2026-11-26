import 'package:flutter/widgets.dart';

import 'session_core.dart';

/// One clock observation history above the Navigator, shared by both scopes.
/// Routes can be destroyed without forgetting time already observed by the app.
/// A new application tree/process intentionally starts a new in-memory history.
class SessionClockScope extends StatefulWidget {
  final Widget child;
  const SessionClockScope({super.key, required this.child});

  static ClockContinuityGuard of(BuildContext context) {
    final owner = context.dependOnInheritedWidgetOfExactType<_ClockOwner>();
    if (owner == null) {
      throw StateError('SessionPage requires an application clock owner');
    }
    return owner.guard;
  }

  @override
  State<SessionClockScope> createState() => _SessionClockScopeState();
}

class _SessionClockScopeState extends State<SessionClockScope> {
  final _guard = ClockContinuityGuard();

  @override
  Widget build(BuildContext context) =>
      _ClockOwner(guard: _guard, child: widget.child);
}

class _ClockOwner extends InheritedWidget {
  final ClockContinuityGuard guard;
  const _ClockOwner({required this.guard, required super.child});

  @override
  bool updateShouldNotify(_ClockOwner oldWidget) =>
      !identical(guard, oldWidget.guard);
}
