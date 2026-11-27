import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'release_features.dart';

enum Answer { yes, no }

enum Admission { allowed, held, risk, unavailable }

enum SessionPhase {
  loading,
  ready,
  review,
  checking,
  pending,
  cooldown,
  interrupted,
  failed,
}

enum SubmitResult { pending, held, risk, unavailable, stale, busy, failed }

abstract interface class AnswerSource {
  int next100();
}

/// No question, model output, history or preferences enter this source.
class SystemAnswerSource implements AnswerSource {
  @override
  int next100() => Random.secure().nextInt(100);
}

Answer answerFor(int value) {
  if (value < 0 || value > 99)
    throw const FormatException('Invalid random value');
  return value < 50 ? Answer.yes : Answer.no;
}

class ClockSample {
  final int utcMs, continuousMs;
  final String bootToken;
  const ClockSample(this.utcMs, this.continuousMs, this.bootToken);

  void validate() {
    if (utcMs < 0 ||
        continuousMs < 0 ||
        utcMs > maxClockMs ||
        continuousMs > maxClockMs ||
        bootToken.isEmpty ||
        bootToken.length > 128) {
      throw const FormatException('Invalid clock');
    }
  }
}

const cooldownMs = 1800 * 1000;
const diagnosticCooldownMs = 60 * 1000;
const maxClockMs = 9007199254740991 - cooldownMs;

abstract interface class SessionClock {
  /// continuousMs must include device sleep and survive process restarts.
  /// bootToken identifies the comparison domain, never a device identity.
  /// A different token takes bounded UTC recovery. The iOS boot-time marker can
  /// also change after wall-clock edits between process launches; see STAGE_3.
  Future<ClockSample> read();
}

/// Retain this guard above navigation when replacing screens/session owners.
/// It observes only clock samples; no user input or persisted state is kept.
class ClockContinuityGuard {
  ClockSample? _last;

  void accept(ClockSample now) {
    now.validate();
    final previous = _last;
    if (previous != null &&
        now.bootToken == previous.bootToken &&
        now.continuousMs < previous.continuousMs) {
      throw const FormatException('Continuous clock moved backwards');
    }
    // A rejected sample never lowers the baseline, even after a retry.
    _last = now;
  }
}

abstract interface class SessionStore {
  Future<String?> read();

  /// Atomically replaces the one state record. Never writes question text.
  /// A thrown error may mean the replacement committed; callers fail closed.
  Future<void> replace(String value);
}

class PauseNotification {
  static const id = 'universe.cooldown.v1';
  final int remainingMs;
  final String language;
  const PauseNotification(this.remainingMs, this.language);
  String get body => language == 'ru'
      ? 'Вселенная снова готова тебя услышать'
      : 'The Universe is ready to hear you again';
}

abstract interface class PauseNotifications {
  /// Replace the same fixed ID, once, only when OS permission and user preference
  /// allow it. Reconciliation must not create repeated notifications.
  Future<void> replace(PauseNotification request);
  Future<void> cancel();
}

class NoPauseNotifications implements PauseNotifications {
  @override
  Future<void> replace(PauseNotification request) async {}
  @override
  Future<void> cancel() async {}
}

enum _RecordKind { idle, reserved, pending, cooldown }

// Call only after jsonDecode has checked syntax. Records are flat objects;
// reject duplicate keys (including escaped spellings) before interpreting them.
// Foundation and Dart must not select different states from ambiguous JSON.
void _rejectDuplicateKeys(String raw) {
  final keys = <String>{};
  var i = 0;
  while (i < raw.length) {
    if (raw.codeUnitAt(i) != 34) {
      i++;
      continue;
    }
    final start = i++;
    while (i < raw.length) {
      if (raw.codeUnitAt(i) == 92) {
        i += 2;
        continue;
      }
      if (raw.codeUnitAt(i) == 34) break;
      i++;
    }
    i++;
    var next = i;
    while (next < raw.length &&
        [9, 10, 13, 32].contains(raw.codeUnitAt(next))) {
      next++;
    }
    if (next < raw.length && raw.codeUnitAt(next) == 58) {
      final key = jsonDecode(raw.substring(start, i)) as String;
      if (!keys.add(key)) throw const FormatException('Duplicate state field');
    }
  }
}

class _Record {
  final _RecordKind kind;
  final Answer? answer;
  final int? utcDeadline, continuousDeadline;
  final String? bootToken;
  final int durationMs;
  const _Record(
    this.kind, {
    this.answer,
    this.utcDeadline,
    this.continuousDeadline,
    this.bootToken,
    this.durationMs = cooldownMs,
  });

  String encode() => jsonEncode({
    'version': durationMs == diagnosticCooldownMs ? 2 : 1,
    'phase': kind.name,
    if (answer != null) 'answer': answer!.name,
    if (utcDeadline != null) 'utcDeadline': utcDeadline,
    if (continuousDeadline != null) 'continuousDeadline': continuousDeadline,
    if (bootToken != null) 'bootToken': bootToken,
    if (durationMs == diagnosticCooldownMs) 'durationMs': durationMs,
  });

  static _Record decode(String? raw) {
    if (raw == null) return const _Record(_RecordKind.idle);
    if (raw.length > 1024) throw const FormatException('Invalid state');
    final decoded = jsonDecode(raw);
    _rejectDuplicateKeys(raw);
    if (decoded is! Map<String, dynamic> ||
        ![1, 2].contains(decoded['version']) ||
        decoded['version'] is! int) {
      throw const FormatException('Unsupported state');
    }
    final kind = _RecordKind.values.byName(decoded['phase'] as String);
    final shortPause = decoded['version'] == 2;
    if (shortPause &&
        (kind != _RecordKind.cooldown ||
            decoded['durationMs'] is! int ||
            decoded['durationMs'] != diagnosticCooldownMs)) {
      throw const FormatException('Invalid diagnostic timer');
    }
    final expected = {
      'version',
      'phase',
      if (kind == _RecordKind.pending) 'answer',
      if (kind == _RecordKind.cooldown) ...[
        'utcDeadline',
        'continuousDeadline',
        'bootToken',
        if (shortPause) 'durationMs',
      ],
    };
    if (decoded.keys.toSet().difference(expected).isNotEmpty ||
        expected.difference(decoded.keys.toSet()).isNotEmpty) {
      throw const FormatException('Unexpected state fields');
    }
    if (kind == _RecordKind.pending) {
      return _Record(
        kind,
        answer: Answer.values.byName(decoded['answer'] as String),
      );
    }
    if (kind == _RecordKind.cooldown) {
      final wall = decoded['utcDeadline'];
      final continuous = decoded['continuousDeadline'];
      final boot = decoded['bootToken'];
      if (wall is! int ||
          continuous is! int ||
          boot is! String ||
          wall < 0 ||
          continuous < 0 ||
          wall > maxClockMs + cooldownMs ||
          continuous > maxClockMs + cooldownMs ||
          boot.isEmpty ||
          boot.length > 128) {
        throw const FormatException('Invalid deadline');
      }
      return _Record(
        kind,
        utcDeadline: wall,
        continuousDeadline: continuous,
        bootToken: boot,
        durationMs: shortPause ? diagnosticCooldownMs : cooldownMs,
      );
    }
    return _Record(kind);
  }
}

class QuestionReview {
  final String text, language;
  final int _revision;
  const QuestionReview._(this.text, this.language, this._revision);
}

typedef QuestionValidator = Future<Admission> Function(
  String text,
  String language,
);

/// Platform-independent stage 3 state machine. Production must bind a validator
/// that keeps admission closed. Test validators cannot be selected by user input.
/// One owner per store: widgets share this session, never create competing ones.
class QuestionSession {
  final SessionStore store;
  final SessionClock clock;
  final AnswerSource random;
  final QuestionValidator validateQuestion;
  final PauseNotifications notifications;
  final Duration validationTimeout;
  final ClockContinuityGuard _clockGuard;
  // Fixed fixture + isolated backend only. Real sessions always use the default.
  final bool diagnostic;
  void Function()? onChanged;

  QuestionSession({
    required this.store,
    required this.clock,
    required this.random,
    required this.validateQuestion,
    ClockContinuityGuard? clockGuard,
    PauseNotifications? notifications,
    String initialLanguage = 'ru',
    this.validationTimeout = const Duration(seconds: 45),
    this.diagnostic = false,
  }) : _clockGuard = clockGuard ?? ClockContinuityGuard(),
       notifications = notifications ?? NoPauseNotifications(),
       _language = initialLanguage {
    if (initialLanguage != 'ru' && initialLanguage != 'en') {
      throw ArgumentError.value(initialLanguage, 'initialLanguage');
    }
  }

  _Record _record = const _Record(_RecordKind.idle);
  SessionPhase _phase = SessionPhase.loading;
  String _draft = '', _language;
  QuestionReview? _review;
  int _revision = 0;
  bool _busy = false, _active = true;
  bool _notificationFailed = false;
  int _remainingMs = 0;
  SessionPhase get phase => _phase;
  int get remainingMs => _remainingMs;
  int get currentPauseDurationMs => _record.durationMs;
  int get _newPauseDurationMs => diagnostic ? diagnosticCooldownMs : cooldownMs;
  bool get notificationFailed => _notificationFailed;
  String get draft => _draft;
  String get language => _language;
  bool get busy => _busy;
  bool get active => _active;
  Answer? get pendingAnswer =>
      _active && phase == SessionPhase.pending ? _record.answer : null;
  int get remainingSeconds => (remainingMs / 1000).ceil();

  void _changed() => onChanged?.call();
  void _clearInput() {
    _draft = '';
    _review = null;
    ++_revision;
  }

  void setActive(bool active) {
    _active = active;
    if (!active) {
      _clearInput();
      if (phase == SessionPhase.review) _phase = SessionPhase.ready;
    }
    _changed();
  }

  bool edit(String text, {String? language}) {
    if (!_active ||
        ![
          SessionPhase.ready,
          SessionPhase.review,
          SessionPhase.checking,
        ].contains(phase)) {
      return false;
    }
    if (language != null && language != 'ru' && language != 'en') return false;
    // During validation edits invalidate the in-flight decision. Once reservation
    // begins phase leaves checking, so input can no longer race the RNG.
    _draft = text;
    if (language != null) _language = language;
    _review = null;
    ++_revision;
    if (phase == SessionPhase.review) _phase = SessionPhase.ready;
    _changed();
    return true;
  }

  QuestionReview? review() {
    if (_busy ||
        !_active ||
        phase != SessionPhase.ready ||
        _draft.trim().isEmpty ||
        _draft.length > 8192)
      return null;
    _review = QuestionReview._(_draft, _language, _revision);
    _phase = SessionPhase.review;
    _changed();
    return _review;
  }

  void cancelReview() {
    if (phase == SessionPhase.review) {
      _review = null;
      _phase = SessionPhase.ready;
      ++_revision;
      _changed();
    }
  }

  void _fail() {
    _clearInput();
    _phase = SessionPhase.failed;
    _changed();
  }

  Future<void> _save(_Record record) async {
    await store.replace(record.encode());
    _record = record;
  }

  Future<ClockSample> _now() async {
    final now = await clock.read();
    _clockGuard.accept(now);
    return now;
  }

  Future<void> _reconcileNotification() async {
    try {
      if (_record.kind == _RecordKind.cooldown && remainingMs > 0) {
        await notifications
            .replace(PauseNotification(remainingMs, _language))
            .timeout(const Duration(seconds: 5));
      } else {
        await notifications.cancel().timeout(const Duration(seconds: 5));
      }
      _notificationFailed = false;
    } catch (_) {
      // Delivery is optional; it never changes the authoritative timer.
      _notificationFailed = true;
    }
  }

  Future<void> _refreshCooldown({bool reconcile = false}) async {
    if (_record.kind != _RecordKind.cooldown) return;
    final now = await _now();
    final sameBoot = now.bootToken == _record.bootToken;
    final left = sameBoot
        ? _record.continuousDeadline! - now.continuousMs
        : _record.utcDeadline! - now.utcMs;
    if (sameBoot && left > _record.durationMs) {
      throw const FormatException('Continuous clock moved backwards');
    }
    _remainingMs = left.clamp(0, _record.durationMs);
    if (remainingMs == 0) {
      // Availability changes only after the clear is durably acknowledged.
      await _save(const _Record(_RecordKind.idle));
      _phase = SessionPhase.ready;
      await _reconcileNotification();
    } else {
      final clockShift =
          (_record.utcDeadline! - now.utcMs - remainingMs).abs() > 2000;
      if (!sameBoot || clockShift) {
        await _save(
          _Record(
            _RecordKind.cooldown,
            utcDeadline: now.utcMs + remainingMs,
            continuousDeadline: now.continuousMs + remainingMs,
            bootToken: now.bootToken,
            durationMs: _record.durationMs,
          ),
        );
        reconcile = true;
      }
      _phase = SessionPhase.cooldown;
      if (reconcile) await _reconcileNotification();
    }
  }

  Future<void> initialize() async {
    if (_busy) return;
    _busy = true;
    _clearInput();
    _phase = SessionPhase.loading;
    try {
      _record = _Record.decode(await store.read());
      if (!diagnostic && _record.durationMs != cooldownMs) {
        throw const FormatException('Diagnostic timer in real session');
      }
      _remainingMs = 0;
      switch (_record.kind) {
        case _RecordKind.idle:
          _phase = SessionPhase.ready;
        case _RecordKind.reserved:
          // A crash before the result was saved. No automatic new random draw.
          _phase = SessionPhase.interrupted;
        case _RecordKind.pending:
          _phase = SessionPhase.pending;
        case _RecordKind.cooldown:
          await _refreshCooldown(reconcile: true);
      }
      if (_record.kind != _RecordKind.cooldown) await _reconcileNotification();
    } catch (_) {
      _fail();
    } finally {
      _busy = false;
      _changed();
    }
  }

  /// Temporary personal-build tool. It cannot interrupt checking/pending or
  /// generate a replacement answer. Public builds compile this path closed.
  Future<bool> resetPersonalPause() async {
    if (!personalTestBuild ||
        _busy ||
        !_active ||
        phase != SessionPhase.cooldown)
      return false;
    _busy = true;
    _clearInput();
    try {
      await notifications.cancel().timeout(const Duration(seconds: 5));
      await _save(const _Record(_RecordKind.idle));
      _remainingMs = 0;
      _phase = SessionPhase.ready;
      _notificationFailed = false;
      return true;
    } catch (_) {
      _fail();
      return false;
    } finally {
      _busy = false;
      _changed();
    }
  }

  Future<SubmitResult> confirm(QuestionReview review) async {
    if (_busy) return SubmitResult.busy;
    if (!_active ||
        phase != SessionPhase.review ||
        !identical(review, _review) ||
        review._revision != _revision ||
        review.text != _draft ||
        review.language != _language) {
      return SubmitResult.stale;
    }
    _busy = true;
    final revision = _revision;
    _draft = '';
    _review = null;
    _phase = SessionPhase.checking;
    _changed();
    try {
      Admission decision;
      try {
        decision = await validateQuestion(
          review.text,
          review.language,
        ).timeout(validationTimeout);
      } catch (_) {
        decision = Admission.unavailable;
      }
      if (!_active || revision != _revision) {
        _phase = SessionPhase.ready;
        return SubmitResult.stale;
      }
      if (decision != Admission.allowed) {
        _phase = SessionPhase.ready;
        return switch (decision) {
          Admission.risk => SubmitResult.risk,
          Admission.held => SubmitResult.held,
          _ => SubmitResult.unavailable,
        };
      }
      // No input editing once the transaction starts. Store an intent before
      // touching the RNG, so recovery can never silently draw a replacement.
      _phase = SessionPhase.loading;
      await _save(const _Record(_RecordKind.reserved));
      if (!_active || revision != _revision) {
        await _save(const _Record(_RecordKind.idle));
        _phase = SessionPhase.ready;
        return SubmitResult.stale;
      }
      Answer result;
      try {
        result = answerFor(random.next100());
      } catch (_) {
        await _save(const _Record(_RecordKind.idle));
        _phase = SessionPhase.ready;
        return SubmitResult.failed;
      }
      await _save(_Record(_RecordKind.pending, answer: result));
      _phase = SessionPhase.pending;
      return SubmitResult.pending;
    } catch (_) {
      _fail();
      return SubmitResult.failed;
    } finally {
      _busy = false;
      _changed();
    }
  }

  /// Call after a frame actually displayed the pending answer, while foreground.
  /// The UI must not call this for a preview, animation, or hidden widget.
  Future<bool> acknowledgeShown() async {
    if (_busy || !_active || phase != SessionPhase.pending) return false;
    _busy = true;
    try {
      final now = await _now();
      await _save(
        _Record(
          _RecordKind.cooldown,
          utcDeadline: now.utcMs + _newPauseDurationMs,
          continuousDeadline: now.continuousMs + _newPauseDurationMs,
          bootToken: now.bootToken,
          durationMs: _newPauseDurationMs,
        ),
      );
      _remainingMs = _newPauseDurationMs;
      _phase = SessionPhase.cooldown;
      await _reconcileNotification();
      return true;
    } catch (_) {
      _fail();
      return false;
    } finally {
      _busy = false;
      _changed();
    }
  }

  Future<void> refresh() async {
    if (_busy || phase != SessionPhase.cooldown) return;
    _busy = true;
    try {
      await _refreshCooldown();
    } catch (_) {
      _fail();
    } finally {
      _busy = false;
      _changed();
    }
  }

  /// Explicit acknowledgement of an interrupted intent; no saved/displayed
  /// answer exists. A new question always needs fresh confirmation and validation.
  Future<bool> dismissInterrupted() async {
    if (_busy || phase != SessionPhase.interrupted || !_active) return false;
    _busy = true;
    try {
      await _save(const _Record(_RecordKind.idle));
      _phase = SessionPhase.ready;
      return true;
    } catch (_) {
      _fail();
      return false;
    } finally {
      _busy = false;
      _changed();
    }
  }
}
