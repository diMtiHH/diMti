import 'package:flutter/services.dart';

import 'session_core.dart';

const diagnosticFixture = 'stage3-fixed-fixture-v1';

/// This validator has no editable question path. It is used only by the clearly
/// labelled diagnostic screen, with separate storage and notification identity.
Future<Admission> validateDiagnosticFixture(
  String text,
  String language,
) async => text == diagnosticFixture && (language == 'ru' || language == 'en')
    ? Admission.allowed
    : Admission.held;

class SessionPreferences {
  final String language;
  final bool notifications;
  final bool englishNotifications;
  const SessionPreferences(
    this.language,
    this.notifications, {
    this.englishNotifications = false,
  });
}

abstract interface class SessionBackend implements SessionStore {
  Future<ClockSample> readClock();
  Future<void> replaceNotification(PauseNotification request);
  Future<void> cancel();
  Future<SessionPreferences> preferences();
  Future<void> setLanguage(String language);
  Future<bool> setNotifications(bool enabled);
  Future<void> reconcileNotifications();
  Future<void> resetDiagnostic();
}

class IosSessionBackend implements SessionBackend {
  static const channel = MethodChannel('app.asktheuniverse/session.v1');
  final bool diagnostic;
  const IosSessionBackend({this.diagnostic = false});

  Future<T?> _call<T>(
    String method, [
    Map<String, Object?> values = const {},
  ]) => channel.invokeMethod<T>(method, {
    'scope': diagnostic ? 'diagnostic' : 'real',
    ...values,
  });

  @override
  Future<String?> read() => _call<String>('readState');
  @override
  Future<void> replace(String value) async =>
      _call<void>('writeState', {'value': value});

  @override
  Future<ClockSample> readClock() async {
    final values = await _call<Map>('clock');
    if (values == null) throw const FormatException('Clock unavailable');
    final sample = ClockSample(
      values['utcMs'] as int,
      values['continuousMs'] as int,
      values['bootToken'] as String,
    );
    sample.validate();
    return sample;
  }

  @override
  Future<SessionPreferences> preferences() async {
    final values = await _call<Map>('preferences');
    if (values == null ||
        !['ru', 'en'].contains(values['language']) ||
        values['notifications'] is! bool) {
      throw const FormatException('Preferences unavailable');
    }
    return SessionPreferences(
      values['language'] as String,
      values['notifications'] as bool,
      englishNotifications: values['englishNotifications'] == true,
    );
  }

  @override
  Future<void> setLanguage(String language) async =>
      _call<void>('setLanguage', {'language': language});
  @override
  Future<bool> setNotifications(bool enabled) async =>
      await _call<bool>('setNotifications', {'enabled': enabled}) ?? false;
  @override
  Future<void> reconcileNotifications() async =>
      _call<void>('scheduleNotification');
  @override
  Future<void> replaceNotification(PauseNotification request) async =>
      reconcileNotifications();
  @override
  Future<void> cancel() async => _call<void>('cancelNotification');
  @override
  Future<void> resetDiagnostic() async {
    if (!diagnostic) throw StateError('Real session cannot be reset');
    await _call<void>('resetDiagnostic');
  }
}

// Separate wrappers avoid overlapping interface names (read/replace) while
// retaining one native serial queue and one explicit scope per backend.
class BackendClock implements SessionClock {
  final SessionBackend backend;
  const BackendClock(this.backend);
  @override
  Future<ClockSample> read() => backend.readClock();
}

class BackendNotifications implements PauseNotifications {
  final SessionBackend backend;
  const BackendNotifications(this.backend);
  @override
  Future<void> replace(PauseNotification request) =>
      backend.replaceNotification(request);
  @override
  Future<void> cancel() => backend.cancel();
}
