import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'closed_model_gate.dart';
import 'engine.dart';
import 'ios_session.dart';
import 'session_core.dart';
import 'session_clock_scope.dart';
import 'worker.dart';
import 'voice_input.dart';
import 'voice_star.dart';
import 'aura_answer_page.dart';
import 'aura_renderer.dart';
import 'aura_ui.dart';
import 'presentation_profile.dart';

enum _LoadStage { preferences, clock, model, state }

class SessionPage extends StatefulWidget {
  final bool aura;
  final PresentationProfile? appearance;
  final AuraInteractionController? interaction;
  final ValueChanged<AuraVisualState>? onVisuals;
  final ValueChanged<bool>? onVoiceCapture, onAnswerScreen;
  final ValueChanged<String>? onFeedback;
  final bool embedded, active;
  final String nickname;
  final int languageRevision;
  final bool diagnostic;
  final SessionBackend? backend;
  final Future<Reading> Function(String, String)? inspector;
  final AnswerSource? random;
  final VoiceBackend? voiceBackend;
  const SessionPage({
    super.key,
    this.diagnostic = false,
    this.backend,
    this.inspector,
    this.random,
    this.voiceBackend,
    this.embedded = false,
    this.active = true,
    this.nickname = '',
    this.languageRevision = 0,
    this.aura = false,
    this.appearance,
    this.interaction,
    this.onVisuals,
    this.onVoiceCapture,
    this.onAnswerScreen,
    this.onFeedback,
  });
  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final AnimationController _sequence;
  late final AuraInteractionController _interaction;
  bool _ownsInteraction = false, _inputMode = false, _answerOpen = false;
  bool _sequenceQueued = false;
  int _auraGeneration = 0;
  int _sequenceFeedbackMask = 0;
  bool _quietSequence = false;
  String _shownQuestion = '';
  Route<void>? _answerRoute;
  QuestionSession? _animatingSession;
  PresentationProfile get _appearance =>
      widget.appearance ?? const PresentationProfile.defaults();
  AuraPhase get _auraPhase {
    if (_answerOpen) return AuraPhase.answerReveal;
    if (_sequence.isAnimating) return AuraPhase.answerAnimation;
    return switch (_session?.phase) {
      SessionPhase.review => AuraPhase.questionConfirmation,
      SessionPhase.checking ||
      SessionPhase.loading => AuraPhase.safetyValidation,
      SessionPhase.pending => AuraPhase.answerAnimation,
      SessionPhase.cooldown => AuraPhase.cooldown,
      _ => _inputMode ? AuraPhase.questionInput : AuraPhase.idle,
    };
  }

  void _visuals() {
    if (!widget.aura) return;
    widget.onVisuals?.call(
      AuraVisualState(
        phase: _auraPhase,
        progress: _sequence.value,
        energy: _voice?.recording == true ? _voice!.level : 0,
      ),
    );
  }

  void _haptic([String event = 'touch']) {
    if (!_foreground || !widget.active || _covered) return;
    if (!widget.aura || _appearance.hapticsEnabled)
      unawaited(HapticFeedback.selectionClick());
    if (widget.aura) widget.onFeedback?.call(event);
  }

  void _sequenceFeedback() {
    if (_quietSequence ||
        !_sequence.isAnimating ||
        !_foreground ||
        !widget.active ||
        _covered)
      return;
    var crossed = false;
    for (var i = 0; i < 2; ++i) {
      final threshold = i == 0 ? 2.2 / 4.5 : 3.8 / 4.5;
      if (_sequence.value >= threshold &&
          _sequenceFeedbackMask & (1 << i) == 0) {
        _sequenceFeedbackMask |= 1 << i;
        crossed = true;
      }
    }
    if (crossed && _appearance.hapticsEnabled)
      unawaited(HapticFeedback.lightImpact());
  }

  final _input = TextEditingController();
  VoiceInputController? _voice;
  bool _voiceRevisionActive = false;
  String _beforeVoice = '';
  late final ClockContinuityGuard _clockGuard;
  bool _started = false;
  late final SessionBackend _backend;
  QuestionSession? _session;
  ModelWorker? _worker;
  Timer? _tick;
  QuestionReview? _review;
  Answer? _visibleAnswer;
  SubmitResult? _result;
  String _language = 'ru';
  bool _loading = true, _failed = false, _settingsBusy = false;
  bool _loadRunning = false, _reloadPending = false;
  _LoadStage _loadStage = _LoadStage.preferences;
  bool _notifications = false, _notificationError = false;
  bool _englishNotifications = false;
  bool _foreground = true,
      _covered = false,
      _reveal = false,
      _ackQueued = false;
  String t(String ru, String en) => _language == 'ru' ? ru : en;

  String get _loadFailure => switch (_loadStage) {
    _LoadStage.preferences => t(
      'Не удалось прочитать настройки. Проверка заблокирована.',
      'Could not read settings. Checking is blocked.',
    ),
    _LoadStage.clock => t(
      'Не удалось получить системное время для таймера. Проверка заблокирована.',
      'Could not read the system clock for the timer. Checking is blocked.',
    ),
    _LoadStage.model => t(
      'Не удалось загрузить модель. Проверка заблокирована.',
      'Could not load the model. Checking is blocked.',
    ),
    _LoadStage.state => t(
      'Не удалось восстановить состояние. Проверка заблокирована.',
      'Could not restore the session. Checking is blocked.',
    ),
  };

  @override
  void initState() {
    super.initState();
    _ownsInteraction = widget.interaction == null;
    _interaction = widget.interaction ?? AuraInteractionController();
    _sequence =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 4500),
        )..addListener(() {
          if (mounted) {
            _sequenceFeedback();
            _visuals();
            setState(() {});
          }
        });
    _backend =
        widget.backend ?? IosSessionBackend(diagnostic: widget.diagnostic);
    if (!widget.diagnostic) {
      _voice = VoiceInputController(
        backend: widget.voiceBackend ?? IosVoiceBackend(),
      )..addListener(_voiceChanged);
    }
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_foreground && !_covered && widget.active) _session?.refresh();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _clockGuard = SessionClockScope.of(context);
    _started = true;
    _load();
  }

  @override
  void didUpdateWidget(SessionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) _hidePrivateView();
    if (!oldWidget.active && widget.active && _foreground && !_covered) {
      _session?.setActive(true);
      _resume();
    }
    if (oldWidget.languageRevision != widget.languageRevision) {
      _hidePrivateView();
      _load();
    }
  }

  Future<void> _load() async {
    // Shell language changes may arrive while a native read/model startup is
    // awaiting. Queue the latest reload instead of losing it to the busy guard.
    _reloadPending = true;
    if (_loadRunning) return;
    _loadRunning = true;
    try {
      while (mounted && _reloadPending) {
        _reloadPending = false;
        await _loadOnce();
      }
    } finally {
      _loadRunning = false;
    }
    if (mounted) {
      setState(() => _loading = false);
      _queueAuraAnswer();
      _visuals();
    }
  }

  Future<void> _loadOnce() async {
    _cancelAura();
    _discardVoice();
    _session?.onChanged = null;
    _session = null;
    _worker?.close();
    _worker = null;
    _input.clear();
    _review = null;
    _visibleAnswer = null;
    _reveal = false;
    _result = null;
    if (mounted)
      setState(() {
        _loading = true;
        _failed = false;
      });
    try {
      _loadStage = _LoadStage.preferences;
      final prefs = await _backend.preferences();
      if (!mounted || _reloadPending) return;
      _language = prefs.language;
      _loadStage = _LoadStage.clock;
      // Reloading the worker/session must not forget the last valid clock.
      _clockGuard.accept(await _backend.readClock());
      if (!mounted || _reloadPending) return;
      _language = prefs.language;
      _notifications = prefs.notifications;
      _englishNotifications = prefs.englishNotifications;
      late QuestionValidator validator;
      if (widget.diagnostic) {
        validator = validateDiagnosticFixture;
      } else {
        _loadStage = _LoadStage.model;
        var inspect = widget.inspector;
        if (inspect == null) {
          final worker = _worker = ModelWorker();
          final app = File(Platform.resolvedExecutable).parent;
          await worker.start(
            Directory.fromUri(
              app.uri.resolve(
                'Frameworks/App.framework/flutter_assets/assets/stage2/',
              ),
            ).path,
          );
          inspect = worker.inspect;
        }
        validator = ClosedModelGate(inspect).call;
      }
      if (!mounted || _reloadPending) {
        _worker?.close();
        return;
      }
      final session = QuestionSession(
        diagnostic: widget.diagnostic,
        store: _backend,
        clock: BackendClock(_backend),
        clockGuard: _clockGuard,
        random: widget.random ?? SystemAnswerSource(),
        validateQuestion: validator,
        notifications: BackendNotifications(_backend),
        initialLanguage: _language,
      );
      _loadStage = _LoadStage.state;
      session.setActive(_foreground && !_covered && widget.active);
      await session.initialize();
      if (!mounted || _reloadPending) {
        _worker?.close();
        return;
      }
      // Activity can also change while initialize awaits the native store.
      session.setActive(_foreground && !_covered && widget.active);
      _session = session;
      session.onChanged = _changed;
    } catch (_) {
      _worker?.close();
      if (mounted && !_reloadPending) _failed = true;
    }
  }

  void _changed() {
    if (!mounted) return;
    if (_session?.phase != SessionPhase.ready && _voice?.busy == true) {
      _discardVoice();
    }
    if (_session?.phase != SessionPhase.review) _review = null;
    if (_session?.phase != SessionPhase.pending &&
        _session?.phase != SessionPhase.cooldown) {
      _visibleAnswer = null;
      _reveal = false;
      _shownQuestion = '';
      if (_answerOpen) _closeAuraRoute();
    }
    setState(() {});
    _queueAuraAnswer();
    _visuals();
  }

  void _hidePrivateView({bool keepPermissionRequest = false}) {
    _cancelAura();
    if (!keepPermissionRequest) _discardVoice();
    _input.clear();
    _review = null;
    _visibleAnswer = null;
    _result = null;
    _reveal = false;
    _session?.setActive(false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _hidePrivateView(
        keepPermissionRequest:
            state == AppLifecycleState.inactive &&
            _voice?.state == VoiceInputState.starting,
      );
    } else if (!_covered && widget.active) {
      _session?.setActive(true);
      _resume();
    }
    if (mounted) setState(() {});
  }

  Future<void> _resume() async {
    await _session?.refresh();
    try {
      await _backend.reconcileNotifications();
    } catch (_) {
      if (mounted) setState(() => _notificationError = true);
    }
  }

  void _prepare() {
    final session = _session!;
    if (!widget.active ||
        !_foreground ||
        _covered ||
        session.busy ||
        session.phase != SessionPhase.ready ||
        _voice?.busy == true)
      return;
    _discardVoice();
    if (widget.diagnostic) session.edit(diagnosticFixture, language: _language);
    final review = session.review();
    setState(() {
      _review = review;
      _result = null;
    });
  }

  Future<void> _confirm() async {
    final review = _review;
    if (review == null) return;
    final generation = _auraGeneration;
    final session = _session!;
    final question = widget.diagnostic ? '' : review.text;
    if (widget.aura) _haptic();
    FocusScope.of(context).unfocus();
    _input.clear();
    _review = null;
    final result = await session.confirm(review);
    if (mounted &&
        _foreground &&
        !_covered &&
        widget.active &&
        (!widget.aura || generation == _auraGeneration) &&
        identical(session, _session)) {
      setState(() {
        _result = result;
        if (widget.aura) {
          if (result == SubmitResult.pending)
            _shownQuestion = question;
          else if (session.phase == SessionPhase.ready) {
            _input.text = question;
            session.edit(question, language: _language);
            _inputMode = true;
          }
        }
      });
      _queueAuraAnswer();
      _visuals();
    }
  }

  void _voiceChanged() {
    if (!mounted) return;
    final voice = _voice!;
    final session = _session;
    if (_voiceRevisionActive &&
        _foreground &&
        !_covered &&
        widget.active &&
        session?.phase == SessionPhase.ready) {
      if (_input.text != voice.text) {
        _input.value = TextEditingValue(
          text: voice.text,
          selection: TextSelection.collapsed(offset: voice.text.length),
        );
        session!.edit(voice.text, language: _language);
        _result = null;
      }
    }
    if (!voice.busy) _voiceRevisionActive = false;
    setState(() {});
    widget.onVoiceCapture?.call(voice.busy);
    _visuals();
  }

  void _discardVoice() {
    _voiceRevisionActive = false;
    _beforeVoice = '';
    unawaited(_voice?.cancel());
  }

  Future<void> _startVoice() async {
    if (!widget.active ||
        !_foreground ||
        _covered ||
        _settingsBusy ||
        _voice?.busy == true ||
        _session?.phase != SessionPhase.ready ||
        _session?.busy == true)
      return;
    FocusScope.of(context).unfocus();
    _haptic();
    _beforeVoice = _input.text;
    _voiceRevisionActive = true;
    await _voice!.start(_language, initialText: _beforeVoice);
  }

  void _cancelVoice() {
    final original = _beforeVoice;
    _discardVoice();
    _input.text = original;
    _session?.edit(original, language: _language);
    setState(() {});
  }

  String get _voiceStatus {
    final voice = _voice!;
    if (voice.state == VoiceInputState.starting) {
      return t('Подключаем микрофон…', 'Preparing microphone…');
    }
    if (voice.state == VoiceInputState.listening) {
      return t(
        'Слушаю. Нажми на звезду, чтобы закончить.',
        'Listening. Tap the star to finish.',
      );
    }
    if (voice.state == VoiceInputState.stopping) {
      return t('Завершаем распознавание…', 'Finishing transcription…');
    }
    if (voice.state == VoiceInputState.error) {
      return switch (voice.errorCode) {
        'permissionDenied' => t(
          'Нет разрешения на микрофон или речь. Можно написать вопрос или изменить разрешения в настройках iPhone.',
          'Microphone or speech permission is off. Type your question or change permissions in iPhone Settings.',
        ),
        'unavailable' => t(
          'Распознавание на устройстве недоступно для этого языка. Напиши вопрос.',
          'On-device recognition is unavailable for this language. Type your question.',
        ),
        'interrupted' => t(
          'Запись прервана. Проверь текст или начни снова.',
          'Recording interrupted. Review the text or start again.',
        ),
        _ => t(
          'Не удалось распознать речь. Можно написать вопрос.',
          'Speech could not be recognized. You can type your question.',
        ),
      };
    }
    return t(
      'Коснись звезды и задай вопрос голосом',
      'Touch the star and speak your question',
    );
  }

  Future<void> _languageTo(String language) async {
    if (_settingsBusy || _session?.busy == true) return;
    _hidePrivateView();
    setState(() => _settingsBusy = true);
    try {
      await _backend.setLanguage(language);
      // Re-read state; this never clears a pending answer or the timer.
      await _load();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _settingsBusy = false);
    }
  }

  Future<void> _toggleNotifications(bool enabled) async {
    if (_settingsBusy || _session?.busy == true) return;
    setState(() => _settingsBusy = true);
    try {
      final accepted = await _backend.setNotifications(enabled);
      if (mounted)
        setState(() {
          _notifications = accepted;
          _notificationError = enabled && !accepted;
        });
    } catch (_) {
      if (mounted) setState(() => _notificationError = true);
    } finally {
      if (mounted) setState(() => _settingsBusy = false);
    }
  }

  Future<void> _diagnostic() async {
    if (_covered || _settingsBusy || _session?.busy == true) return;
    _covered = true;
    _hidePrivateView();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const SessionPage(diagnostic: true),
      ),
    );
    if (!mounted) return;
    _covered = false;
    _session?.setActive(_foreground && widget.active);
    if (_foreground && widget.active) await _resume();
  }

  Future<void> _resetDiagnostic() async {
    if (_settingsBusy || _session?.busy == true) return;
    setState(() => _settingsBusy = true);
    try {
      await _backend.resetDiagnostic();
      await _load();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _settingsBusy = false);
    }
  }

  void _afterVisibleFrame(Answer answer) {
    if (_ackQueued) return;
    _ackQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _ackQueued = false;
      if (!mounted ||
          !_foreground ||
          _covered ||
          !widget.active ||
          _session?.phase != SessionPhase.pending ||
          (widget.diagnostic && !_reveal))
        return;
      _visibleAnswer = answer;
      await _session!.acknowledgeShown();
      if (mounted) setState(() {});
    });
  }

  String _outcome(SubmitResult result) => switch (result) {
    SubmitResult.held => t(
      'Проверка завершена. Допуск закрыт.',
      'Check complete. Admission is closed.',
    ),
    SubmitResult.risk => t(
      'Модель отметила возможный риск. Допуск закрыт.',
      'The model flagged possible risk. Admission is closed.',
    ),
    SubmitResult.unavailable || SubmitResult.failed => t(
      'Не удалось выполнить проверку. Ответ не выбран.',
      'The check could not complete. No answer was selected.',
    ),
    _ => '',
  };

  void _closeAuraRoute() {
    final route = _answerRoute;
    if (route == null) return;
    _answerRoute = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route.isActive) route.navigator?.removeRoute(route);
    });
  }

  void _cancelAura() {
    ++_auraGeneration;
    _sequenceQueued = false;
    _sequence.stop();
    _animatingSession = null;
    _inputMode = false;
    _shownQuestion = '';
    if (_answerOpen) _closeAuraRoute();
    _interaction.cancel();
  }

  bool _currentAura(QuestionSession session, int generation) =>
      mounted &&
      _foreground &&
      !_covered &&
      widget.active &&
      generation == _auraGeneration &&
      identical(_session, session);

  void _queueAuraAnswer() {
    final session = _session;
    if (!widget.aura ||
        session == null ||
        session.phase != SessionPhase.pending ||
        session.busy ||
        _loading ||
        !_foreground ||
        _covered ||
        !widget.active ||
        _sequenceQueued ||
        _sequence.isAnimating ||
        _answerOpen)
      return;
    _sequenceQueued = true;
    final generation = _auraGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_currentAura(session, generation)) return;
      _sequenceQueued = false;
      if (session.phase == SessionPhase.pending &&
          session.pendingAnswer != null) {
        unawaited(_animateAura(session, generation));
      }
    });
  }

  Future<void> _animateAura(QuestionSession session, int generation) async {
    if (_animatingSession != null || _answerOpen) return;
    final answer = session.pendingAnswer;
    if (answer == null) return;
    _animatingSession = session;
    _sequenceFeedbackMask = 0;
    _quietSequence =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    _haptic('transform');
    _sequence.duration = _quietSequence
        ? const Duration(milliseconds: 300)
        : const Duration(milliseconds: 4500);
    try {
      await _sequence.forward(from: 0).orCancel;
    } on TickerCanceled {
      return;
    }
    if (!_currentAura(session, generation) ||
        session.phase != SessionPhase.pending)
      return;
    _animatingSession = null;
    await _openAuraAnswer(session, answer, generation);
  }

  Future<void> _openAuraAnswer(
    QuestionSession session,
    Answer answer,
    int generation,
  ) async {
    if (_answerOpen || !_currentAura(session, generation)) return;
    _answerOpen = true;
    widget.onAnswerScreen?.call(true);
    _visuals();
    final route = PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, __, ___) => AuraAnswerPage(
        answer: answer,
        question: _shownQuestion,
        language: _language,
        profile: _appearance,
        session: session,
        interaction: _interaction,
        onVisible: () async {
          if (!_currentAura(session, generation)) return;
          if (session.phase == SessionPhase.pending) {
            _visibleAnswer = answer;
            _haptic('reveal');
            await session.acknowledgeShown();
          }
        },
      ),
    );
    _answerRoute = route;
    await Navigator.of(context).push(route);
    if (!mounted) return;
    if (identical(_answerRoute, route)) _answerRoute = null;
    _answerOpen = false;
    widget.onAnswerScreen?.call(false);
    _visuals();
    setState(() {});
  }

  void _openInput() {
    if (_session?.phase != SessionPhase.ready ||
        _session!.busy ||
        !_foreground ||
        !widget.active ||
        _covered)
      return;
    _haptic();
    setState(() {
      _inputMode = true;
      _result = null;
    });
    _visuals();
  }

  Widget _auraForm(double height) => SizedBox(
    height: height,
    width: double.infinity,
    child: AuraTouchSurface(
      interaction: _interaction,
      label: t(
        'Живая форма. Коснись, чтобы задать вопрос',
        'Living form. Tap to ask a question',
      ),
      active: _foreground && widget.active && !_covered && !_answerOpen,
      phase: _auraPhase,
      onShortTap: _openInput,
      onTouchFeedback: _haptic,
      child: AuraScene(
        background: _appearance.background.name,
        form: _appearance.answerStyle.name,
        showBackground: false,
        formAlignment: Alignment.center,
        formScale: 1.25,
        interaction: _interaction,
        phase: _auraPhase,
        progress: _sequence.value,
        energy: _voice?.recording == true ? _voice!.level : 0,
        active: _foreground && widget.active && !_covered && !_answerOpen,
        child: const SizedBox.expand(),
      ),
    ),
  );

  Widget _auraContent(QuestionSession session, double height) {
    final phase = session.phase;
    if (phase == SessionPhase.failed || phase == SessionPhase.interrupted)
      return _content(session);
    if (phase == SessionPhase.loading ||
        phase == SessionPhase.checking ||
        phase == SessionPhase.pending) {
      return Column(
        children: [
          _auraForm(height),
          const SizedBox(height: 16),
          Text(
            phase == SessionPhase.pending
                ? t('Побудь в этом мгновении', 'Stay in this moment')
                : t('Проверяем вопрос…', 'Checking your question…'),
            textAlign: TextAlign.center,
          ),
        ],
      );
    }
    if (phase == SessionPhase.cooldown) {
      final seconds = session.remainingSeconds;
      final time =
          '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
      return Column(
        children: [
          _auraForm(height),
          Text(
            t('Вселенная уже ответила', 'The Universe has answered'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          Text(
            time,
            key: const ValueKey('cooldown'),
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 12),
          if (_visibleAnswer != null)
            TextButton(
              key: const ValueKey('view-answer'),
              onPressed: () =>
                  _openAuraAnswer(session, _visibleAnswer!, _auraGeneration),
              child: Text(t('Посмотреть ответ', 'View answer')),
            ),
        ],
      );
    }
    if (phase == SessionPhase.review) {
      final review = _review;
      if (review == null) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _auraForm(height * .6),
          Text(
            t('Это твой вопрос?', 'Is this your question?'),
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Text(
            widget.diagnostic
                ? t('Технический пример', 'Technical fixture')
                : review.text,
            key: const ValueKey('review-question'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 32),
          FilledButton(
            key: const ValueKey('confirm-question'),
            onPressed: _confirm,
            child: Text(t('Спросить Вселенную', 'Ask the Universe')),
          ),
          TextButton(
            onPressed: () {
              session.cancelReview();
              _visuals();
            },
            child: Text(t('Изменить вопрос', 'Edit question')),
          ),
        ],
      );
    }
    if (!_inputMode && !widget.diagnostic) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _auraForm(height),
          Text(
            t('О чём ты думаешь?', 'What is on your mind?'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 10),
          Text(
            t('Один вопрос. Один ответ.', 'One question. One answer.'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 24),
          FilledButton(
            key: const ValueKey('ask-question'),
            onPressed: _openInput,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    t('Задать вопрос', 'Ask a question'),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(width: 12),
                const AuraIcon(kind: AuraIconKind.arrowRight, size: 20),
              ],
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _auraForm(height * .55),
        if (!widget.diagnostic)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              t('Твой вопрос', 'Your question'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
        if (!widget.diagnostic)
          TextField(
            key: const ValueKey('question-input'),
            controller: _input,
            minLines: 1,
            maxLines: 5,
            maxLength: 8192,
            enableSuggestions: false,
            autocorrect: false,
            style: Theme.of(context).textTheme.headlineSmall,
            decoration: InputDecoration(
              hintText: t('Стоит ли мне…', 'Should I…'),
              filled: false,
              counterText: '',
              border: const UnderlineInputBorder(),
            ),
            onTap: () {
              if (_voice?.busy == true) _discardVoice();
            },
            onChanged: (value) {
              _discardVoice();
              session.edit(value, language: _language);
              _result = null;
              _interaction.pulse(.3);
              _visuals();
            },
          ),
        if (!widget.diagnostic) ...[
          const SizedBox(height: 12),
          Center(
            child: IconButton(
              key: const ValueKey('voice-input'),
              tooltip: _voice!.recording
                  ? t('Остановить запись', 'Stop recording')
                  : t('Голосовой ввод', 'Voice input'),
              onPressed: _voice!.recording
                  ? _voice!.stop
                  : (_voice!.busy ? null : _startVoice),
              icon: AuraIcon(
                kind: _voice!.recording
                    ? AuraIconKind.close
                    : AuraIconKind.microphone,
              ),
            ),
          ),
          if (_voice!.busy || _voice!.state == VoiceInputState.error)
            Text(
              _voiceStatus
                  .replaceAll('звезду', 'микрофон')
                  .replaceAll('star', 'microphone'),
              key: const ValueKey('voice-status'),
              textAlign: TextAlign.center,
            ),
          if (_voice!.busy)
            TextButton(
              onPressed: _cancelVoice,
              child: Text(t('Отменить запись', 'Cancel recording')),
            ),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed:
              session.busy ||
                  _voice?.busy == true ||
                  (!widget.diagnostic && session.draft.trim().isEmpty)
              ? null
              : () {
                  FocusScope.of(context).unfocus();
                  _haptic();
                  _prepare();
                  _visuals();
                },
          child: Text(
            widget.diagnostic
                ? t('Подготовить тестовый ответ', 'Prepare test answer')
                : t('Продолжить', 'Continue'),
          ),
        ),
        TextButton(
          onPressed: () {
            _discardVoice();
            _input.clear();
            session.edit('', language: _language);
            setState(() {
              _inputMode = false;
              _result = null;
            });
            _visuals();
          },
          child: Text(t('Отмена', 'Cancel')),
        ),
        if (_result != null && _outcome(_result!).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _outcome(_result!),
              key: const ValueKey('outcome'),
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }

  Widget _auraBody() => LayoutBuilder(
    builder: (context, constraints) {
      if (!_foreground || !widget.active || _covered || _answerOpen)
        return const SizedBox.shrink();
      final height = (constraints.maxHeight * .60).clamp(180.0, 430.0);
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.nickname.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      t(
                        'Привет, ${widget.nickname}',
                        'Hello, ${widget.nickname}',
                      ),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                if (_failed) ...[
                  Text(_loadFailure),
                  TextButton(
                    onPressed: _load,
                    child: Text(t('Повторить загрузку', 'Retry loading')),
                  ),
                ] else if (_loading || _session == null) ...[
                  _auraForm(height),
                  Center(
                    child: Text(
                      t('Вселенная пробуждается…', 'The Universe is waking…'),
                    ),
                  ),
                ] else
                  _auraContent(_session!, height),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _content(QuestionSession session) {
    if (!_foreground || _covered || !widget.active)
      return const SizedBox.shrink();
    switch (session.phase) {
      case SessionPhase.loading:
      case SessionPhase.checking:
        return Column(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(t('Проверяем…', 'Checking…')),
          ],
        );
      case SessionPhase.failed:
        return Column(
          children: [
            Text(
              t(
                'Не удалось восстановить состояние. Новая попытка заблокирована.',
                'Could not restore the session. A new attempt is blocked.',
              ),
            ),
            TextButton(
              onPressed: _load,
              child: Text(t('Повторить загрузку', 'Retry loading')),
            ),
          ],
        );
      case SessionPhase.interrupted:
        return Column(
          children: [
            Text(
              t(
                'Попытка прервана до сохранения ответа. Новый ответ автоматически не выбирается.',
                'The attempt stopped before its answer was saved. No new answer is selected automatically.',
              ),
            ),
            FilledButton(
              onPressed: session.busy ? null : session.dismissInterrupted,
              child: Text(t('Понятно', 'Understood')),
            ),
          ],
        );
      case SessionPhase.review:
        final review = _review;
        if (review == null) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t('Подтверди формулировку', 'Confirm the wording'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            Text(
              widget.diagnostic
                  ? t(
                      'Фиксированный технический пример. Это не ответ на личный вопрос.',
                      'Fixed technical fixture. This is not an answer to a personal question.',
                    )
                  : review.text,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _confirm,
              child: Text(t('Подтверждаю', 'Confirm')),
            ),
            TextButton(
              onPressed: session.cancelReview,
              child: Text(t('Изменить', 'Edit')),
            ),
          ],
        );
      case SessionPhase.pending:
        if (widget.diagnostic && !_reveal) {
          return Column(
            children: [
              Text(
                t(
                  'Тестовый ответ сохранён и ещё не показан. Можно полностью закрыть приложение и открыть «Проверку ядра» снова.',
                  'The test answer is saved but not shown yet. You can fully close the app, then reopen Core check.',
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: session.busy
                    ? null
                    : () => setState(() => _reveal = true),
                child: Text(
                  t('Показать сохранённый ответ', 'Show saved answer'),
                ),
              ),
            ],
          );
        }
        final answer = session.pendingAnswer;
        if (answer == null) return const SizedBox.shrink();
        _afterVisibleFrame(answer);
        return _answer(answer);
      case SessionPhase.cooldown:
        final seconds = session.remainingSeconds;
        final time =
            '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
        return Column(
          children: [
            if (!widget.diagnostic)
              VoiceStar(
                enabled: false,
                active: false,
                label: t(
                  'Микрофон недоступен во время паузы',
                  'Microphone unavailable during the pause',
                ),
              ),
            if (_visibleAnswer != null) _answer(_visibleAnswer!),
            Text(
              session.currentPauseDurationMs == diagnosticCooldownMs
                  ? t('Тестовая пауза — одна минута', 'Test pause — one minute')
                  : t('Тридцать минут тишины', 'Thirty minutes of quiet'),
            ),
            if (widget.diagnostic &&
                session.currentPauseDurationMs == cooldownMs)
              Text(
                t(
                  'Продолжается прежний тест. Для нового минутного теста нажми «Сбросить только тест».',
                  'An earlier test is still running. Use Reset test only to start a new one-minute test.',
                ),
              ),
            Semantics(
              label: t('Осталось $time', '$time remaining'),
              child: Text(
                time,
                key: const ValueKey('cooldown'),
                style: Theme.of(context).textTheme.displayMedium,
              ),
            ),
          ],
        );
      case SessionPhase.ready:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.diagnostic)
              Text(
                t(
                  'Один тестовый результат, сохранение и пауза 1 минута. Обычная пауза — 30 минут. Личные вопросы здесь не принимаются.',
                  'One test result, persistence and a 1-minute pause. The normal pause is 30 minutes. Personal questions are not accepted here.',
                ),
              )
            else
              TextField(
                controller: _input,
                maxLines: 4,
                maxLength: 8192,
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: t('Твой вопрос', 'Your question'),
                  border: InputBorder.none,
                ),
                onTap: () {
                  if (_voice?.busy == true) _discardVoice();
                },
                onChanged: (value) {
                  _discardVoice();
                  session.edit(value, language: _language);
                  _result = null;
                },
              ),
            if (!widget.diagnostic) ...[
              VoiceStar(
                level: _voice!.level,
                listening: _voice!.recording,
                active: _foreground && !_covered && widget.active,
                enabled:
                    !_settingsBusy &&
                    !session.busy &&
                    (_voice!.state == VoiceInputState.idle ||
                        _voice!.state == VoiceInputState.error ||
                        _voice!.state == VoiceInputState.listening),
                label: _voice!.recording
                    ? t('Остановить запись', 'Stop recording')
                    : t('Задать вопрос голосом', 'Speak your question'),
                onPressed: _voice!.recording ? _voice!.stop : _startVoice,
              ),
              Text(
                _voiceStatus,
                textAlign: TextAlign.center,
                key: const ValueKey('voice-status'),
              ),
              if (_voice!.busy)
                TextButton(
                  onPressed: _cancelVoice,
                  child: Text(t('Отменить запись', 'Cancel recording')),
                ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed:
                  session.busy ||
                      _voice?.busy == true ||
                      (!widget.diagnostic && session.draft.trim().isEmpty)
                  ? null
                  : _prepare,
              child: Text(
                widget.diagnostic
                    ? t('Подготовить тестовый ответ', 'Prepare test answer')
                    : t('Продолжить', 'Continue'),
              ),
            ),
            if (_result != null && _outcome(_result!).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(_outcome(_result!), key: const ValueKey('outcome')),
              ),
          ],
        );
    }
  }

  Widget _answer(Answer answer) => Padding(
    padding: const EdgeInsets.all(24),
    child: Text(
      answer == Answer.yes ? t('ДА', 'YES') : t('НЕТ', 'NO'),
      key: const ValueKey('answer'),
      style: Theme.of(context).textTheme.displayLarge,
      semanticsLabel: answer == Answer.yes
          ? t('Ответ: да', 'Answer: yes')
          : t('Ответ: нет', 'Answer: no'),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final session = _session;
    if (widget.aura) {
      final body = _auraBody();
      return widget.embedded
          ? body
          : AuraScene(
              background: _appearance.background.name,
              interaction: _interaction,
              showForm: false,
              phase: _auraPhase,
              progress: _sequence.value,
              active: _foreground && widget.active && !_answerOpen,
              child: Scaffold(
                backgroundColor: Colors.transparent,
                body: SafeArea(child: body),
              ),
            );
    }
    return Scaffold(
      backgroundColor: widget.embedded ? Colors.transparent : null,
      appBar: widget.embedded
          ? null
          : AppBar(
              title: Text(
                widget.diagnostic
                    ? t('Проверка ядра', 'Core check')
                    : t('Спроси Вселенную', 'Ask the Universe'),
              ),
            ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (widget.embedded &&
                widget.nickname.isNotEmpty &&
                _foreground &&
                widget.active)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  t(
                    '${widget.nickname}, какой у тебя вопрос?',
                    '${widget.nickname}, what is your question?',
                  ),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            Text(
              widget.diagnostic
                  ? t(
                      'ТЕХНИЧЕСКИЙ ТЕСТ · отдельная попытка',
                      'TECHNICAL TEST · separate attempt',
                    )
                  : t(
                      'Допуск всех вопросов закрыт',
                      'Admission is closed for every question',
                    ),
            ),
            const SizedBox(height: 12),
            if (!widget.embedded)
              Wrap(
                spacing: 12,
                children: ['ru', 'en']
                    .map(
                      (language) => TextButton(
                        onPressed:
                            _loading ||
                                _settingsBusy ||
                                session?.busy == true ||
                                language == _language
                            ? null
                            : () => _languageTo(language),
                        child: Text(language == 'ru' ? 'Русский' : 'English'),
                      ),
                    )
                    .toList(),
              ),
            const SizedBox(height: 24),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_failed)
              Column(
                children: [
                  Text(_loadFailure),
                  TextButton(
                    onPressed: _settingsBusy ? null : _load,
                    child: Text(t('Повторить загрузку', 'Retry loading')),
                  ),
                ],
              )
            else if (session != null)
              _content(session),
            const SizedBox(height: 32),
            if (!widget.embedded && !_loading && !_failed)
              SwitchListTile(
                title: Text(
                  t('Напомнить после паузы', 'Remind me after the pause'),
                ),
                subtitle: Text(
                  t(
                    'Одно уведомление без вопроса и ответа',
                    'One notification without the question or answer',
                  ),
                ),
                value:
                    _notifications &&
                    (_language == 'ru' || _englishNotifications),
                onChanged:
                    _settingsBusy ||
                        session?.busy == true ||
                        (_language == 'en' && !_englishNotifications)
                    ? null
                    : _toggleNotifications,
              ),
            if (!widget.embedded && _language == 'en' && !_englishNotifications)
              const Text('Reminders are currently available in Russian.'),
            if (_notificationError || session?.notificationFailed == true)
              Text(
                t(
                  'Уведомление недоступно. Проверь разрешение в настройках iPhone. Таймер продолжает работать.',
                  'Notification unavailable. Check permission in iPhone Settings. The timer keeps running.',
                ),
              ),
            const SizedBox(height: 24),
            if (!widget.embedded && !widget.diagnostic)
              TextButton(
                onPressed: _loading || _settingsBusy || session?.busy == true
                    ? null
                    : _diagnostic,
                child: Text(t('Проверка ядра', 'Core check')),
              ),
            if (widget.diagnostic && !_loading)
              TextButton(
                onPressed: _settingsBusy || session?.busy == true
                    ? null
                    : _resetDiagnostic,
                child: Text(t('Сбросить только тест', 'Reset test only')),
              ),
            const SizedBox(height: 12),
            if (!widget.embedded)
              Text(
                t(
                  'Случайный ответ не предсказывает будущее и не заменяет профессиональную помощь.',
                  'A random answer does not predict the future or replace professional help.',
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    ++_auraGeneration;
    _sequence.dispose();
    if (_ownsInteraction) _interaction.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    _session?.onChanged = null;
    _session?.setActive(false);
    _worker?.close();
    _voiceRevisionActive = false;
    _voice?.removeListener(_voiceChanged);
    _voice?.dispose();
    _input.dispose();
    super.dispose();
  }
}
