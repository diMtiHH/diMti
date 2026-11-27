import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const currentTermsVersion = 1;
const maxPresentationNameScalars = 40;
const maxPresentationProfileBytes = 2048;

enum PresentationBackground { stars, galaxy, nebula, blackHole }

enum PresentationAnswerStyle { coin, sphere, blackHole, constellation }

// Syntax is checked by jsonDecode first. This flat schema rejects duplicate
// field spellings, including escaped keys, before interpreting their values.
void _rejectDuplicateProfileKeys(String raw) {
  final keys = <String>{};
  var index = 0;
  while (index < raw.length) {
    if (raw.codeUnitAt(index) != 34) {
      ++index;
      continue;
    }
    final start = index++;
    while (index < raw.length) {
      if (raw.codeUnitAt(index) == 92) {
        index += 2;
        continue;
      }
      if (raw.codeUnitAt(index) == 34) break;
      ++index;
    }
    ++index;
    var next = index;
    while (next < raw.length &&
        const [9, 10, 13, 32].contains(raw.codeUnitAt(next))) {
      ++next;
    }
    if (next < raw.length && raw.codeUnitAt(next) == 58) {
      final key = jsonDecode(raw.substring(start, index)) as String;
      if (!keys.add(key)) {
        throw const FormatException('Duplicate presentation field');
      }
    }
  }
}

/// Presentation preferences only; no question, answer or session state.
@immutable
class PresentationProfile {
  final int version;
  final String name;
  final PresentationBackground background;
  final PresentationAnswerStyle answerStyle;
  final int onboardingStep;
  final bool completed;
  final int termsVersion;
  final bool audioEnabled;

  const PresentationProfile.defaults()
    : version = 1,
      name = '',
      background = PresentationBackground.stars,
      answerStyle = PresentationAnswerStyle.sphere,
      onboardingStep = 0,
      completed = false,
      termsVersion = 0,
      audioEnabled = true;

  const PresentationProfile._({
    required this.name,
    required this.background,
    required this.answerStyle,
    required this.onboardingStep,
    required this.completed,
    required this.termsVersion,
    required this.audioEnabled,
  }) : version = 1;

  factory PresentationProfile({
    String name = '',
    PresentationBackground background = PresentationBackground.stars,
    PresentationAnswerStyle answerStyle = PresentationAnswerStyle.sphere,
    int onboardingStep = 0,
    bool completed = false,
    int termsVersion = 0,
    bool audioEnabled = true,
  }) {
    if (!isValidName(name) ||
        onboardingStep < 0 ||
        onboardingStep > 2 ||
        termsVersion < 0 ||
        termsVersion > 100000 ||
        (!completed && termsVersion != 0) ||
        (completed && (onboardingStep != 2 || termsVersion < 1))) {
      throw const FormatException('Invalid presentation profile');
    }
    return PresentationProfile._(
      name: name,
      background: background,
      answerStyle: answerStyle,
      onboardingStep: onboardingStep,
      completed: completed,
      termsVersion: termsVersion,
      audioEnabled: audioEnabled,
    );
  }

  static bool isValidName(String value) {
    var count = 0;
    for (final scalar in value.runes) {
      if (++count > maxPresentationNameScalars ||
          scalar < 0x20 ||
          (scalar >= 0x7f && scalar <= 0x9f) ||
          (scalar >= 0xd800 && scalar <= 0xdfff)) {
        return false;
      }
    }
    return true;
  }

  bool get needsOnboarding => !completed;
  bool get needsConsent => termsVersion != currentTermsVersion;

  PresentationProfile copyWith({
    String? name,
    PresentationBackground? background,
    PresentationAnswerStyle? answerStyle,
    int? onboardingStep,
    bool? completed,
    int? termsVersion,
    bool? audioEnabled,
  }) => PresentationProfile(
    name: name ?? this.name,
    background: background ?? this.background,
    answerStyle: answerStyle ?? this.answerStyle,
    onboardingStep: onboardingStep ?? this.onboardingStep,
    completed: completed ?? this.completed,
    termsVersion: termsVersion ?? this.termsVersion,
    audioEnabled: audioEnabled ?? this.audioEnabled,
  );

  factory PresentationProfile.fromJson(String value) {
    if (utf8.encode(value).length > maxPresentationProfileBytes) {
      throw const FormatException('Presentation profile is too large');
    }
    final raw = jsonDecode(value);
    _rejectDuplicateProfileKeys(value);
    const fields = {
      'version',
      'name',
      'background',
      'answerStyle',
      'onboardingStep',
      'completed',
      'termsVersion',
      'audioEnabled',
    };
    if (raw is! Map<String, dynamic> ||
        raw.length != fields.length ||
        raw.keys.any((key) => !fields.contains(key)) ||
        raw['version'] is! int ||
        raw['version'] != 1 ||
        raw['name'] is! String ||
        raw['background'] is! String ||
        raw['answerStyle'] is! String ||
        raw['onboardingStep'] is! int ||
        raw['completed'] is! bool ||
        raw['termsVersion'] is! int ||
        raw['audioEnabled'] is! bool) {
      throw const FormatException('Invalid presentation profile schema');
    }
    final backgrounds = {
      for (final item in PresentationBackground.values) item.name: item,
    };
    final styles = {
      for (final item in PresentationAnswerStyle.values) item.name: item,
    };
    final background = backgrounds[raw['background']];
    final answerStyle = styles[raw['answerStyle']];
    if (background == null || answerStyle == null) {
      throw const FormatException('Unknown presentation option');
    }
    return PresentationProfile(
      name: raw['name'] as String,
      background: background,
      answerStyle: answerStyle,
      onboardingStep: raw['onboardingStep'] as int,
      completed: raw['completed'] as bool,
      termsVersion: raw['termsVersion'] as int,
      audioEnabled: raw['audioEnabled'] as bool,
    );
  }

  String toJson() => jsonEncode({
    'version': version,
    'name': name,
    'background': background.name,
    'answerStyle': answerStyle.name,
    'onboardingStep': onboardingStep,
    'completed': completed,
    'termsVersion': termsVersion,
    'audioEnabled': audioEnabled,
  });

  @override
  bool operator ==(Object other) =>
      other is PresentationProfile &&
      version == other.version &&
      name == other.name &&
      background == other.background &&
      answerStyle == other.answerStyle &&
      onboardingStep == other.onboardingStep &&
      completed == other.completed &&
      termsVersion == other.termsVersion &&
      audioEnabled == other.audioEnabled;

  @override
  int get hashCode => Object.hash(
    version,
    name,
    background,
    answerStyle,
    onboardingStep,
    completed,
    termsVersion,
    audioEnabled,
  );
}

abstract interface class PresentationBackend {
  Future<String?> readProfile();
  Future<void> writeProfile(String value);
}

class IosPresentationBackend implements PresentationBackend {
  static const channel = MethodChannel('ask_universe/presentation');
  const IosPresentationBackend();

  @override
  Future<String?> readProfile() => channel.invokeMethod<String>('readProfile');

  @override
  Future<void> writeProfile(String value) =>
      channel.invokeMethod<void>('writeProfile', {'value': value});
}

/// Serializes persistence. A failed write has an unknown commit status, so a
/// successful explicit load is required before any further mutation.
class PresentationController extends ChangeNotifier {
  final PresentationBackend _backend;
  Future<void> _tail = Future<void>.value();
  PresentationProfile? _profile;
  int _pending = 0;
  bool _loading = false, _failed = false, _disposed = false;

  PresentationController(PresentationBackend backend) : _backend = backend;

  PresentationProfile? get profile => _profile;
  bool get loading => _loading;
  bool get busy => _pending > 0;
  bool get failed => _failed;
  bool get needsOnboarding => _profile?.needsOnboarding ?? true;
  bool get needsConsent => _profile?.needsConsent ?? true;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<bool> _enqueue(Future<bool> Function() action) {
    if (_disposed) return Future<bool>.value(false);
    ++_pending;
    final operation = _tail.then((_) async {
      if (_disposed) return false;
      return action();
    });
    final settled = operation.whenComplete(() {
      --_pending;
      _changed();
    });
    _tail = settled.then<void>((_) {});
    _changed();
    return settled;
  }

  Future<bool> load() => _enqueue(() async {
    _loading = true;
    _changed();
    try {
      final raw = await _backend.readProfile();
      final value = raw == null
          ? const PresentationProfile.defaults()
          : PresentationProfile.fromJson(raw);
      if (_disposed) return false;
      _profile = value;
      _failed = false;
      return true;
    } catch (_) {
      if (!_disposed) _failed = true;
      return false;
    } finally {
      _loading = false;
      _changed();
    }
  });

  Future<bool> save(PresentationProfile value) =>
      _enqueue(() => _persist(value));

  Future<bool> acceptTerms() => _enqueue(() async {
    final value = _profile;
    if (value == null || _failed) return false;
    return _persist(
      value.copyWith(
        completed: true,
        onboardingStep: 2,
        termsVersion: currentTermsVersion,
      ),
    );
  });

  Future<bool> _persist(PresentationProfile value) async {
    if (_profile == null || _failed || _disposed) return false;
    try {
      await _backend.writeProfile(value.toJson());
      if (_disposed) return false;
      _profile = value;
      return true;
    } catch (_) {
      if (!_disposed) _failed = true;
      return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
