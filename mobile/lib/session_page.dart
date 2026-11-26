import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'closed_model_gate.dart';
import 'engine.dart';
import 'ios_session.dart';
import 'session_core.dart';
import 'worker.dart';

enum _LoadStage { preferences, clock, model, state }

class UniverseApp extends StatelessWidget {
  const UniverseApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Спроси Вселенную',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff86a7df),
        brightness: Brightness.dark,
      ),
    ),
    home: const SessionPage(),
  );
}

class SessionPage extends StatefulWidget {
  final bool diagnostic;
  final SessionBackend? backend;
  final Future<Reading> Function(String, String)? inspector;
  final AnswerSource? random;
  const SessionPage({
    super.key,
    this.diagnostic = false,
    this.backend,
    this.inspector,
    this.random,
  });
  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage> with WidgetsBindingObserver {
  final _input = TextEditingController();
  late final SessionBackend _backend;
  QuestionSession? _session;
  ModelWorker? _worker;
  Timer? _tick;
  QuestionReview? _review;
  Answer? _visibleAnswer;
  SubmitResult? _result;
  String _language = 'ru';
  bool _loading = true, _failed = false, _settingsBusy = false;
  bool _loadRunning = false;
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
    _backend =
        widget.backend ?? IosSessionBackend(diagnostic: widget.diagnostic);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _load();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_foreground && !_covered) _session?.refresh();
    });
  }

  Future<void> _load() async {
    if (_loadRunning) return;
    _loadRunning = true;
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
      _language = prefs.language;
      _loadStage = _LoadStage.clock;
      await _backend
          .readClock(); // Preflight: no fallback to process-only time.
      if (!mounted) return;
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
      if (!mounted) {
        _worker?.close();
        return;
      }
      final session = QuestionSession(
        diagnostic: widget.diagnostic,
        store: _backend,
        clock: BackendClock(_backend),
        random: widget.random ?? SystemAnswerSource(),
        validateQuestion: validator,
        notifications: BackendNotifications(_backend),
        initialLanguage: _language,
      );
      _session = session;
      _loadStage = _LoadStage.state;
      session.setActive(_foreground && !_covered);
      await session.initialize();
      session.onChanged = _changed;
    } catch (_) {
      _failed = true;
      _worker?.close();
    } finally {
      _loadRunning = false;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _changed() {
    if (!mounted) return;
    if (_session?.phase != SessionPhase.review) _review = null;
    if (_session?.phase != SessionPhase.pending &&
        _session?.phase != SessionPhase.cooldown) {
      _visibleAnswer = null;
      _reveal = false;
    }
    setState(() {});
  }

  void _hidePrivateView() {
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
      _hidePrivateView();
    } else if (!_covered) {
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
    if (session.busy || session.phase != SessionPhase.ready) return;
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
    _input.clear();
    _review = null;
    final result = await _session!.confirm(review);
    if (mounted && _foreground && !_covered) setState(() => _result = result);
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
    _session?.setActive(_foreground);
    if (_foreground) await _resume();
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

  Widget _content(QuestionSession session) {
    if (!_foreground || _covered) return const SizedBox.shrink();
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
                ),
                onChanged: (value) {
                  session.edit(value, language: _language);
                  _result = null;
                },
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed:
                  session.busy ||
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
    return Scaffold(
      appBar: AppBar(
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
            if (!_loading && !_failed)
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
            if (_language == 'en' && !_englishNotifications)
              const Text('Reminders are currently available in Russian.'),
            if (_notificationError || session?.notificationFailed == true)
              Text(
                t(
                  'Уведомление недоступно. Проверь разрешение в настройках iPhone. Таймер продолжает работать.',
                  'Notification unavailable. Check permission in iPhone Settings. The timer keeps running.',
                ),
              ),
            const SizedBox(height: 24),
            if (!widget.diagnostic)
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
    WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    _session?.onChanged = null;
    _session?.setActive(false);
    _worker?.close();
    _input.dispose();
    super.dispose();
  }
}
