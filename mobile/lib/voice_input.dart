import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const maxVoiceTextLength = 8192;
const maxVoiceSessionId = 9007199254740991;

enum VoiceInputState { idle, starting, listening, stopping, error }

enum VoiceEventType { listening, transcript, level, finished, error }

const _nativeVoiceErrors = {
  'permissionDenied',
  'unavailable',
  'interrupted',
  'failed',
};

class VoiceEvent {
  final int id;
  final VoiceEventType type;
  final String? text;
  final double? level;
  final String? code;

  const VoiceEvent({
    required this.id,
    required this.type,
    this.text,
    this.level,
    this.code,
  });

  bool get isValid {
    if (id <= 0 || id > maxVoiceSessionId) return false;
    if (text != null && text!.length > maxVoiceTextLength) return false;
    return switch (type) {
      VoiceEventType.listening => text == null && level == null && code == null,
      VoiceEventType.transcript =>
        text != null && level == null && code == null,
      VoiceEventType.level =>
        text == null &&
            code == null &&
            level != null &&
            level!.isFinite &&
            level! >= 0 &&
            level! <= 1,
      VoiceEventType.finished => level == null && code == null,
      VoiceEventType.error =>
        text == null && level == null && _nativeVoiceErrors.contains(code),
    };
  }

  /// Invalid native payloads never become editable text or animation values.
  static VoiceEvent? fromMap(Object? raw) {
    if (raw is! Map ||
        raw.keys.any(
          (key) => !const {'id', 'type', 'text', 'level', 'code'}.contains(key),
        )) {
      return null;
    }
    final id = raw['id'];
    final name = raw['type'];
    final text = raw['text'];
    final level = raw['level'];
    final code = raw['code'];
    if (id is! int ||
        name is! String ||
        (text != null && text is! String) ||
        (level != null && level is! num) ||
        (code != null && code is! String)) {
      return null;
    }
    VoiceEventType? type;
    for (final candidate in VoiceEventType.values) {
      if (candidate.name == name) type = candidate;
    }
    if (type == null) return null;
    final event = VoiceEvent(
      id: id,
      type: type,
      text: text as String?,
      level: (level as num?)?.toDouble(),
      code: code as String?,
    );
    return event.isValid ? event : null;
  }
}

/// One backend belongs to one controller. Cancellation is id-scoped so cleanup
/// of a delayed old start cannot cancel a newer recording on the same channel.
abstract interface class VoiceBackend {
  Stream<VoiceEvent> get events;
  Future<void> start({required int id, required String language});
  Future<void> stop({required int id});
  Future<void> cancel({required int id});
  void dispose();
}

class IosVoiceBackend implements VoiceBackend {
  static const channel = MethodChannel('ask_universe/voice');
  static final _owners = <(BinaryMessenger, String), IosVoiceBackend>{};

  final MethodChannel _channel;
  final _events = StreamController<VoiceEvent>.broadcast(sync: true);
  late final (BinaryMessenger, String) _key;
  bool _disposed = false;

  IosVoiceBackend({MethodChannel? methodChannel})
    : _channel = methodChannel ?? channel {
    _key = (_channel.binaryMessenger, _channel.name);
    _owners[_key] = this;
    _channel.setMethodCallHandler((call) async {
      if (_disposed || !identical(_owners[_key], this)) return null;
      if (call.method != 'voiceEvent') return null;
      final event = VoiceEvent.fromMap(call.arguments);
      if (event != null) _events.add(event);
      return null;
    });
  }

  @override
  Stream<VoiceEvent> get events => _events.stream;

  void _requireOwner() {
    if (_disposed || !identical(_owners[_key], this)) {
      throw StateError('Voice backend is unavailable');
    }
  }

  @override
  Future<void> start({required int id, required String language}) async {
    _requireOwner();
    await _channel.invokeMethod<void>('start', {
      'id': id,
      'language': language,
    });
  }

  @override
  Future<void> stop({required int id}) async {
    _requireOwner();
    await _channel.invokeMethod<void>('stop', {'id': id});
  }

  @override
  Future<void> cancel({required int id}) async {
    // Also allowed after dispose: a previously pending start may complete late.
    await _channel.invokeMethod<void>('cancel', {'id': id});
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (identical(_owners[_key], this)) {
      _owners.remove(_key);
      _channel.setMethodCallHandler(null);
    }
    unawaited(_events.close());
  }
}

/// Ephemeral input only. This controller never persists, validates a question,
/// confirms it, or invokes a model/RNG. The editor owns explicit confirmation.
class VoiceInputController extends ChangeNotifier {
  // Session identities must not repeat when a screen/controller is recreated.
  static int _nextId = 0;
  final VoiceBackend _backend;
  final Duration startTimeout, stopTimeout;
  late final StreamSubscription<VoiceEvent> _subscription;
  VoiceInputState _state = VoiceInputState.idle;
  String _text = '';
  String? _errorCode;
  double _level = 0;
  int? _id;
  Timer? _stopTimer;
  Completer<void>? _stopCompletion;
  bool _disposed = false;

  VoiceInputController({
    required VoiceBackend backend,
    this.startTimeout = const Duration(seconds: 75),
    this.stopTimeout = const Duration(seconds: 3),
  }) : _backend = backend {
    if (startTimeout <= Duration.zero || stopTimeout <= Duration.zero) {
      throw ArgumentError('Voice deadlines must be positive');
    }
    _subscription = _backend.events.listen(
      _event,
      onError: (Object error, StackTrace stack) {
        final id = _id;
        if (id != null) _fail(id, _errorFor(error));
      },
      onDone: () {
        final id = _id;
        if (id != null) _fail(id, 'unavailable');
      },
    );
  }

  VoiceInputState get state => _state;
  String get text => _text;
  double get level => _level;
  String? get errorCode => _errorCode;
  bool get busy =>
      _state == VoiceInputState.starting ||
      _state == VoiceInputState.listening ||
      _state == VoiceInputState.stopping;
  bool get recording => _state == VoiceInputState.listening;

  bool _current(int id) => !_disposed && _id == id;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  int? _invalidate() {
    final id = _id;
    _id = null;
    _stopTimer?.cancel();
    _stopTimer = null;
    final completion = _stopCompletion;
    _stopCompletion = null;
    if (completion != null && !completion.isCompleted) completion.complete();
    _level = 0;
    return id;
  }

  Future<void> _cancelNative(int id) async {
    try {
      await _backend.cancel(id: id).timeout(const Duration(seconds: 2));
    } catch (_) {
      // Local invalidation is immediate even if platform cleanup cannot reply.
    }
  }

  static String _errorFor(Object error) {
    if (error is MissingPluginException) return 'unavailable';
    if (error is TimeoutException) return 'timeout';
    if (error is PlatformException && _nativeVoiceErrors.contains(error.code)) {
      return error.code;
    }
    return 'failed';
  }

  Future<void> start(String language, {String initialText = ''}) async {
    if (_disposed) return;
    final previous = _invalidate();
    if (previous != null) unawaited(_cancelNative(previous));
    _errorCode = null;
    _text = initialText.length <= maxVoiceTextLength ? initialText : '';
    if (!const {'ru', 'en'}.contains(language) ||
        initialText.length > maxVoiceTextLength ||
        _nextId >= maxVoiceSessionId) {
      _state = VoiceInputState.error;
      _errorCode = !const {'ru', 'en'}.contains(language)
          ? 'unavailable'
          : 'failed';
      _changed();
      return;
    }
    final id = _id = ++_nextId;
    _state = VoiceInputState.starting;
    _changed();
    if (!_current(id)) return;
    try {
      final starting = _backend.start(id: id, language: language);
      // timeout() cannot cancel a native permission request. Clean it up again
      // if its original Future completes after cancellation or a deadline.
      unawaited(
        starting.then<void>(
          (_) => _cancelIfStale(id),
          onError: (Object _, StackTrace _) => _cancelIfStale(id),
        ),
      );
      await starting.timeout(startTimeout);
      if (!_current(id)) return;
      if (_state == VoiceInputState.starting) {
        _state = VoiceInputState.listening;
        _changed();
      }
    } catch (error) {
      if (_current(id)) _fail(id, _errorFor(error));
    }
  }

  void _cancelIfStale(int id) {
    if (!_current(id)) unawaited(_cancelNative(id));
  }

  Future<void> stop() async {
    if (_disposed || _id == null) return;
    if (_state == VoiceInputState.starting) {
      await cancel();
      return;
    }
    if (_state == VoiceInputState.stopping) {
      await _stopCompletion?.future;
      return;
    }
    if (_state != VoiceInputState.listening) return;
    final id = _id!;
    final completion = _stopCompletion = Completer<void>();
    _state = VoiceInputState.stopping;
    _level = 0;
    _stopTimer = Timer(stopTimeout, () => _fail(id, 'timeout'));
    _changed();
    if (_current(id)) unawaited(_requestStop(id));
    await completion.future;
  }

  Future<void> _requestStop(int id) async {
    try {
      await _backend.stop(id: id).timeout(stopTimeout);
      // This is only endAudio acknowledgement; finished carries completion.
    } catch (error) {
      if (_current(id)) _fail(id, _errorFor(error));
    }
  }

  Future<void> cancel() async {
    if (_disposed) return;
    final id = _invalidate();
    _state = VoiceInputState.idle;
    _errorCode = null;
    _text = '';
    _changed();
    if (id != null) unawaited(_cancelNative(id));
  }

  void _fail(int id, String code) {
    if (!_current(id)) return;
    _invalidate();
    _state = VoiceInputState.error;
    _errorCode = code;
    _changed();
    unawaited(_cancelNative(id));
  }

  void _event(VoiceEvent event) {
    if (!_current(event.id) || !event.isValid) return;
    switch (event.type) {
      case VoiceEventType.listening:
        if (_state != VoiceInputState.starting) return;
        _state = VoiceInputState.listening;
      case VoiceEventType.transcript:
        _text = event.text!;
      case VoiceEventType.level:
        if (_state != VoiceInputState.listening) return;
        _level = event.level!;
      case VoiceEventType.finished:
        if (event.text != null) _text = event.text!;
        _invalidate();
        _state = VoiceInputState.idle;
        _errorCode = null;
      case VoiceEventType.error:
        _fail(event.id, event.code!);
        return;
    }
    _changed();
  }

  @override
  void dispose() {
    if (_disposed) return;
    final id = _invalidate();
    _disposed = true;
    _state = VoiceInputState.idle;
    _text = '';
    _errorCode = null;
    if (id != null) unawaited(_cancelNative(id));
    unawaited(_subscription.cancel().catchError((Object _) {}));
    _backend.dispose();
    super.dispose();
  }
}
