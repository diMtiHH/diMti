import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'cosmic_scene.dart';
import 'cosmic_theme.dart';
import 'engine.dart';
import 'ios_session.dart';
import 'narration.dart';
import 'onboarding_page.dart';
import 'personalization.dart';
import 'presentation_profile.dart';
import 'session_clock_scope.dart';
import 'session_core.dart';
import 'session_page.dart';
import 'voice_input.dart';
import 'ambient_audio.dart';
import 'aura_answer_page.dart';
import 'aura_renderer.dart';
import 'aura_ui.dart';
import 'universe_startup.dart';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

class UniverseApp extends StatelessWidget {
  final AmbientBackend? ambientBackend;
  final PresentationBackend? presentationBackend;
  final SessionBackend? sessionBackend;
  final NarrationBackend? narrationBackend;
  final VoiceBackend? voiceBackend;
  final Future<Reading> Function(String, String)? inspector;
  final AnswerSource? random;
  const UniverseApp({
    super.key,
    this.presentationBackend,
    this.sessionBackend,
    this.narrationBackend,
    this.voiceBackend,
    this.inspector,
    this.random,
    this.ambientBackend,
  });
  @override
  Widget build(BuildContext context) => SessionClockScope(
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Спроси Вселенную',
      theme: cosmicTheme,
      home: UniverseShell(
        presentationBackend: presentationBackend,
        sessionBackend: sessionBackend,
        narrationBackend: narrationBackend,
        voiceBackend: voiceBackend,
        inspector: inspector,
        random: random,
        ambientBackend: ambientBackend,
      ),
    ),
  );
}

class UniverseShell extends StatefulWidget {
  final AmbientBackend? ambientBackend;
  final PresentationBackend? presentationBackend;
  final SessionBackend? sessionBackend;
  final NarrationBackend? narrationBackend;
  final VoiceBackend? voiceBackend;
  final Future<Reading> Function(String, String)? inspector;
  final AnswerSource? random;
  const UniverseShell({
    super.key,
    this.presentationBackend,
    this.sessionBackend,
    this.narrationBackend,
    this.voiceBackend,
    this.inspector,
    this.random,
    this.ambientBackend,
  });
  @override
  State<UniverseShell> createState() => _UniverseShellState();
}

class _UniverseShellState extends State<UniverseShell>
    with WidgetsBindingObserver {
  late final PresentationController _presentation;
  late final SessionBackend _sessionBackend;
  late final AmbientController _ambient;
  final _interaction = AuraInteractionController();
  final _visual = ValueNotifier(const AuraVisualState());
  bool _capturingSpeech = false, _answerCover = false;
  PresentationProfile? _lastAppearance;
  String _language = 'ru';
  bool _preferencesLoading = true,
      _preferencesFailed = false,
      _languageBusy = false;
  bool _foreground = true, _covered = false;
  int _tab = 0, _languageRevision = 0;
  bool _startupDone = false, _sessionPrepared = false, _shadersPrepared = false;
  String t(String ru, String en) => _language == 'ru' ? ru : en;
  @override
  void initState() {
    super.initState();
    _sessionBackend = widget.sessionBackend ?? const IosSessionBackend();
    _ambient = AmbientController(backend: widget.ambientBackend);
    _presentation = PresentationController(
      widget.presentationBackend ?? IosPresentationBackend(),
    )..addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _load();
    unawaited(_prepareGraphics());
  }

  Future<void> _prepareGraphics() async {
    try {
      await warmUpAuraShaders();
    } catch (_) {
      /* Scene fallback stays available. */
    }
    if (mounted) setState(() => _shadersPrepared = true);
  }

  void _prepared(bool succeeded) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _sessionPrepared = succeeded;
        if (!succeeded) _startupDone = true;
      });
    });
  }

  void _changed() {
    if (!mounted) return;
    final profile = _presentation.profile;
    final old = _lastAppearance;
    final intent =
        profile != null &&
        old != null &&
        profile.ambientEnabled &&
        (!old.ambientEnabled || old.background != profile.background);
    _lastAppearance = profile;
    _syncAmbient(userIntent: intent);
    setState(() {});
  }

  void _syncAmbient({bool userIntent = false}) {
    final profile = _presentation.profile;
    if (profile == null) return;
    unawaited(
      _ambient.sync(
        enabled: profile.ambientEnabled,
        environment: profile.background.name,
        active: _foreground,
        capturingSpeech: _capturingSpeech,
        allowPlayback:
            !_presentation.needsOnboarding &&
            !_presentation.needsConsent &&
            _startupDone,
        userIntent: userIntent,
      ),
    );
  }

  void _visualChanged(AuraVisualState value) {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _visual.value = value;
      });
    } else {
      _visual.value = value;
    }
  }

  void _captureChanged(bool value) {
    _capturingSpeech = value;
    _syncAmbient();
  }

  Future<void> _load() async {
    setState(() {
      _preferencesLoading = true;
      _preferencesFailed = false;
    });
    try {
      final preferences = await _sessionBackend.preferences();
      if (!mounted) return;
      _language = preferences.language;
      await _presentation.load();
    } catch (_) {
      _preferencesFailed = true;
    }
    if (mounted) setState(() => _preferencesLoading = false);
  }

  Future<void> _languageTo(String language) async {
    if (_languageBusy || _presentation.busy || language == _language) return;
    setState(() => _languageBusy = true);
    try {
      await _sessionBackend.setLanguage(language);
      if (!mounted) return;
      setState(() {
        _language = language;
        ++_languageRevision;
      });
    } catch (_) {
      if (mounted) setState(() => _preferencesFailed = true);
    } finally {
      if (mounted) setState(() => _languageBusy = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted)
      setState(() => _foreground = state == AppLifecycleState.resumed);
    _syncAmbient();
  }

  Future<void> _settings() async {
    if (_covered) return;
    setState(() => _covered = true);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PresentationSettings(
          controller: _presentation,
          backend: _sessionBackend,
          language: _language,
          onLanguage: _languageTo,
          ambient: _ambient,
          onResumeAmbient: () => _syncAmbient(userIntent: true),
        ),
      ),
    );
    if (mounted) setState(() => _covered = false);
  }

  @override
  Widget build(BuildContext context) {
    final profile = _presentation.profile;
    if (_preferencesLoading ||
        _presentation.loading ||
        profile == null ||
        _preferencesFailed ||
        _presentation.failed) {
      final failed = _preferencesFailed || _presentation.failed;
      if (!failed)
        return UniverseStartup(
          language: _language,
          name: '',
          ready: false,
          onComplete: () {},
        );
      return CosmicScene(
        background: 'stars',
        active: _foreground,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!failed) const CircularProgressIndicator(),
                    if (failed) ...[
                      Text(
                        t(
                          'Не удалось прочитать или сохранить настройки. Данные не сброшены.',
                          'Could not read or save settings. Your data has not been reset.',
                        ),
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _load,
                        child: Text(t('Повторить загрузку', 'Retry loading')),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (_presentation.needsOnboarding || _presentation.needsConsent) {
      return OnboardingPage(
        controller: _presentation,
        language: _language,
        onLanguage: _languageTo,
        narrationBackend: widget.narrationBackend,
      );
    }
    final content = Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          SafeArea(
            child: Stack(
              fit: StackFit.expand,
              children: [
                IndexedStack(
                  index: _tab,
                  children: [
                    TickerMode(
                      enabled:
                          _startupDone &&
                          _tab == 0 &&
                          !_covered &&
                          !_answerCover,
                      child: SessionPage(
                        embedded: true,
                        aura: true,
                        appearance: profile,
                        interaction: _interaction,
                        onPrepared: _prepared,
                        onVisuals: _visualChanged,
                        onVoiceCapture: _captureChanged,
                        onFeedback: (event) => unawaited(_ambient.cue(event)),
                        onAnswerScreen: (open) {
                          if (mounted) setState(() => _answerCover = open);
                        },
                        active: _startupDone && _tab == 0 && !_covered,
                        nickname: profile.name,
                        languageRevision: _languageRevision,
                        backend: _sessionBackend,
                        voiceBackend: widget.voiceBackend,
                        inspector: widget.inspector,
                        random: widget.random,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 90, bottom: 100),
                      child: _WorldPage(
                        language: _language,
                        background: profile.background.name,
                        active:
                            _startupDone &&
                            _foreground &&
                            _tab == 1 &&
                            !_covered,
                      ),
                    ),
                  ],
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 14, 18, 8),
                    child: Row(
                      children: [
                        AuraBrandMark(
                          size: 28,
                          color: auraAccent(profile.background.name),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            t('Спроси\nВселенную', 'Ask the\nUniverse'),
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(height: 1.1, letterSpacing: .5),
                          ),
                        ),
                        IconButton(
                          key: const ValueKey('open-settings'),
                          tooltip: t('Настройки', 'Settings'),
                          onPressed: _startupDone ? _settings : null,
                          icon: const AuraIcon(kind: AuraIconKind.settings),
                        ),
                      ],
                    ),
                  ),
                ),
                if (MediaQuery.viewInsetsOf(context).bottom == 0)
                  Positioned(
                    bottom: 0,
                    left: 16,
                    right: 16,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 10, bottom: 8),
                      child: Row(
                        children: [
                          _navigation(
                            0,
                            AuraIconKind.universe,
                            t('Вселенная', 'Universe'),
                            profile,
                          ),
                          _navigation(
                            1,
                            AuraIconKind.world,
                            t('Что волнует мир', 'What concerns the world'),
                            profile,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (!_startupDone)
            Positioned.fill(
              child: UniverseStartup(
                language: _language,
                name: profile.name,
                accent: auraAccent(profile.background.name),
                ready: _sessionPrepared && _shadersPrepared,
                onComplete: () {
                  if (mounted) {
                    setState(() => _startupDone = true);
                    _syncAmbient();
                  }
                },
              ),
            ),
        ],
      ),
    );
    return ValueListenableBuilder<AuraVisualState>(
      valueListenable: _visual,
      child: content,
      builder: (_, visual, child) => AuraScene(
        background: profile.background.name,
        showForm: false,
        interaction: _interaction,
        phase: _tab == 0 ? visual.phase : AuraPhase.idle,
        energy: _tab == 0 ? visual.energy : 0,
        progress: _tab == 0 ? visual.progress : 0,
        active: _startupDone && _foreground && !_covered && !_answerCover,
        child: Opacity(
          opacity: _tab == 0 && visual.phase == AuraPhase.answerAnimation
              ? (1 -
                    ((visual.progress - 3.8 / 4.5) / (0.7 / 4.5)).clamp(
                      0.0,
                      1.0,
                    ))
              : 1,
          child: child!,
        ),
      ),
    );
  }

  Widget _navigation(
    int index,
    AuraIconKind icon,
    String label,
    PresentationProfile profile,
  ) {
    final selected = _tab == index;
    return Expanded(
      child: Semantics(
        selected: selected,
        button: true,
        child: InkWell(
          key: ValueKey('tab-$index'),
          borderRadius: BorderRadius.circular(20),
          onTap: () {
            if (profile.hapticsEnabled)
              unawaited(HapticFeedback.selectionClick());
            setState(() => _tab = index);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AuraIcon(
                  kind: icon,
                  color: selected
                      ? auraAccent(profile.background.name)
                      : const Color(0xff8c96a9),
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: selected
                        ? const Color(0xffe9eef8)
                        : const Color(0xff8c96a9),
                  ),
                ),
                const SizedBox(height: 7),
                Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected
                        ? auraAccent(profile.background.name)
                        : Colors.transparent,
                    boxShadow: selected
                        ? [
                            BoxShadow(
                              color: auraAccent(profile.background.name),
                              blurRadius: 8,
                            ),
                          ]
                        : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _presentation.removeListener(_changed);
    _presentation.dispose();
    _ambient.dispose();
    _interaction.dispose();
    _visual.dispose();
    super.dispose();
  }
}

class _WorldPage extends StatelessWidget {
  final String language, background;
  final bool active;
  const _WorldPage({
    required this.language,
    required this.background,
    required this.active,
  });
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
    child: Column(
      children: [
        SizedBox(
          height: 300,
          child: AuraScene(
            background: background,
            form: 'constellation',
            showBackground: false,
            formAlignment: Alignment.center,
            active: active,
            child: const SizedBox.expand(),
          ),
        ),
        Text(
          language == 'ru' ? 'Что волнует мир' : 'What concerns the world',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 18),
        Text(
          language == 'ru'
              ? 'Здесь появится тихое отражение общих тем. Раздел ещё создаётся — сейчас данные не собираются.'
              : 'A quiet reflection of shared themes will appear here. This space is still taking shape — no data is being collected.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      ],
    ),
  );
}

class PresentationSettings extends StatefulWidget {
  final AmbientController? ambient;
  final VoidCallback? onResumeAmbient;
  final PresentationController controller;
  final SessionBackend backend;
  final String language;
  final Future<void> Function(String) onLanguage;
  const PresentationSettings({
    super.key,
    required this.controller,
    required this.backend,
    required this.language,
    required this.onLanguage,
    this.ambient,
    this.onResumeAmbient,
  });
  @override
  State<PresentationSettings> createState() => _PresentationSettingsState();
}

enum _SettingsDestination { appearance, senses, personal, reminders }

class _PresentationSettingsState extends State<PresentationSettings> {
  _SettingsDestination? _section;
  bool _saved = false;
  late final TextEditingController _name;
  late String _language;
  SessionPreferences? _preferences;
  bool _busy = false, _error = false, _nameInvalid = false, _covered = false;
  String t(String ru, String en) => _language == 'ru' ? ru : en;
  @override
  void initState() {
    super.initState();
    _language = widget.language;
    _name = TextEditingController(text: widget.controller.profile!.name);
    widget.controller.addListener(_changed);
    widget.ambient?.addListener(_changed);
    _readPreferences();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _readPreferences() async {
    try {
      final preferences = await widget.backend.preferences();
      if (mounted) setState(() => _preferences = preferences);
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  Future<void> _saveName({bool clear = false}) async {
    final name = clear ? '' : _name.text.trim();
    if (!PresentationProfile.isValidName(name)) {
      setState(() => _nameInvalid = true);
      return;
    }
    if (clear) _name.clear();
    await _saveProfile(widget.controller.profile!.copyWith(name: name));
  }

  Future<void> _saveProfile(PresentationProfile value) async {
    final saved = await widget.controller.save(value);
    if (mounted) setState(() => _saved = saved);
  }

  Future<void> _languageTo(String language) async {
    setState(() => _busy = true);
    try {
      await widget.onLanguage(language);
      final preferences = await widget.backend.preferences();
      if (mounted)
        setState(() {
          _language = preferences.language;
          _preferences = preferences;
          _saved = preferences.language == language;
        });
    } catch (_) {
      if (mounted) setState(() => _error = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _notifications(bool enabled) async {
    setState(() {
      _busy = true;
      _error = false;
    });
    try {
      final accepted = await widget.backend.setNotifications(enabled);
      if (enabled && !accepted) _error = true;
      await _readPreferences();
      if (mounted && !_error) setState(() => _saved = true);
    } catch (_) {
      _error = true;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(Widget page) async {
    setState(() => _covered = true);
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => page));
    if (mounted) setState(() => _covered = false);
  }

  void _go(_SettingsDestination? destination) {
    FocusScope.of(context).unfocus();
    setState(() => _section = destination);
  }

  String _title(_SettingsDestination destination) => switch (destination) {
    _SettingsDestination.appearance => t('Пространство', 'Space'),
    _SettingsDestination.senses => t('Звук и ощущения', 'Sound and feeling'),
    _SettingsDestination.personal => t('Личное', 'Personal'),
    _SettingsDestination.reminders => t('Напоминания', 'Reminders'),
  };

  String _subtitle(_SettingsDestination destination) => switch (destination) {
    _SettingsDestination.appearance => t(
      'Свет, глубина, форма',
      'Light, depth, form',
    ),
    _SettingsDestination.senses => t(
      'То, что слышишь и чувствуешь',
      'What you hear and feel',
    ),
    _SettingsDestination.personal => t(
      'Твоё имя и язык',
      'Your name and language',
    ),
    _SettingsDestination.reminders => t(
      'Мягкое возвращение после паузы',
      'A gentle return after the pause',
    ),
  };

  @override
  Widget build(BuildContext context) {
    // The approved concept pairs the existing display face with quiet sans text.
    final base = Theme.of(context);
    final body = base.textTheme.apply(fontFamily: 'Manrope');
    return Theme(
      data: base.copyWith(
        textTheme: body.copyWith(
          headlineLarge: base.textTheme.headlineLarge,
          headlineSmall: base.textTheme.headlineSmall,
          titleLarge: base.textTheme.titleLarge,
          titleMedium: base.textTheme.titleMedium,
        ),
      ),
      child: Builder(builder: _screen),
    );
  }

  Widget _screen(BuildContext context) {
    final profile = widget.controller.profile!;
    final accent = auraAccent(profile.background.name);
    final text = Theme.of(context).textTheme;
    final reduced =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    return PopScope<void>(
      canPop: _section == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _section != null) _go(null);
      },
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xff071219), Color(0xff050c13), Color(0xff071410)],
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(painter: _SettingsAtmosphere(accent)),
              ),
            ),
            Scaffold(
              backgroundColor: Colors.transparent,
              appBar: AppBar(
                backgroundColor: Colors.transparent,
                toolbarHeight: 52,
                titleSpacing: _section == null ? 24 : 0,
                automaticallyImplyLeading: false,
                title: Text(
                  t('НАСТРОЙКИ', 'SETTINGS'),
                  style: text.bodySmall?.copyWith(
                    fontSize: 11,
                    letterSpacing: 1.8,
                  ),
                ),
                centerTitle: false,
                leading: _section == null
                    ? null
                    : IconButton(
                        key: const ValueKey('settings-back'),
                        tooltip: t('Назад', 'Back'),
                        icon: const AuraIcon(kind: AuraIconKind.back, size: 20),
                        onPressed: () {
                          if (_section != null) {
                            _go(null);
                          } else {
                            Navigator.of(context).pop();
                          }
                        },
                      ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      t('Готово', 'Done'),
                      style: text.bodySmall?.copyWith(color: accent),
                    ),
                  ),
                ],
              ),
              body: SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: AnimatedSwitcher(
                      duration: reduced
                          ? Duration.zero
                          : const Duration(milliseconds: 220),
                      layoutBuilder: (current, previous) => Stack(
                        alignment: Alignment.topCenter,
                        children: [
                          for (final child in previous)
                            IgnorePointer(
                              child: ExcludeSemantics(
                                child: TickerMode(enabled: false, child: child),
                              ),
                            ),
                          if (current != null) current,
                        ],
                      ),
                      child: _section == null
                          ? _overview(context, profile, accent)
                          : _detail(context, profile, accent, _section!),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _overview(
    BuildContext context,
    PresentationProfile profile,
    Color accent,
  ) {
    final text = Theme.of(context).textTheme;
    return ListView(
      key: const ValueKey('settings-overview'),
      padding: const EdgeInsets.fromLTRB(28, 22, 28, 25),
      children: [
        Text(
          profile.name.isEmpty
              ? t('Твоя Вселенная', 'Your Universe')
              : profile.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: text.headlineSmall?.copyWith(
            fontSize: 22,
            height: 1.1,
            fontWeight: FontWeight.w400,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          t('Настройся на свою Вселенную', 'Tune in to your Universe'),
          style: text.bodySmall?.copyWith(
            fontSize: 11,
            height: 1.5,
            color: const Color(0xff98aab5),
          ),
        ),
        const SizedBox(height: 39),
        CustomPaint(
          painter: _SettingsThread(accent),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final destination in _SettingsDestination.values)
                _SettingsEntry(
                  key: ValueKey('settings-${destination.name}'),
                  title: _title(destination),
                  subtitle: _subtitle(destination),
                  index: destination.index,
                  accent: accent,
                  onPressed: () => _go(destination),
                ),
            ],
          ),
        ),
        const SizedBox(height: 42),
        TextButton(
          onPressed: () => _open(PrinciplesPage(language: _language)),
          style: TextButton.styleFrom(padding: EdgeInsets.zero),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  t('Принципы взаимодействия', 'Our principles'),
                  style: text.bodySmall?.copyWith(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        Row(
          children: [
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _saved ? t('Изменения сохранены', 'Changes saved') : '',
                  style: text.bodySmall?.copyWith(fontSize: 11, color: accent),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                t('Только на устройстве', 'Only on this device'),
                textAlign: TextAlign.right,
                style: text.bodySmall?.copyWith(
                  fontSize: 10,
                  color: const Color(0xff81958f),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _detail(
    BuildContext context,
    PresentationProfile profile,
    Color accent,
    _SettingsDestination destination,
  ) {
    final busy = _busy || widget.controller.busy;
    final text = Theme.of(context).textTheme;
    final Widget controls;
    switch (destination) {
      case _SettingsDestination.appearance:
        controls = PersonalizationControls(
          profile: profile,
          language: _language,
          busy: busy,
          active: !_covered,
          onChanged: _saveProfile,
        );
      case _SettingsDestination.personal:
        controls = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('settings-name'),
              controller: _name,
              maxLength: 40,
              enableSuggestions: false,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              onSubmitted: busy ? null : (_) => _saveName(),
              onTapOutside: (_) => FocusScope.of(context).unfocus(),
              style: text.headlineSmall?.copyWith(
                fontSize: 27,
                fontWeight: FontWeight.w400,
              ),
              onChanged: (_) {
                if (_nameInvalid) setState(() => _nameInvalid = false);
              },
              decoration: InputDecoration(
                labelText: t('Имя или никнейм', 'Name or nickname'),
                labelStyle: text.bodySmall,
                filled: false,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: const UnderlineInputBorder(),
                enabledBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0x406d8194), width: .7),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: accent, width: .8),
                ),
                counterStyle: text.bodySmall?.copyWith(fontSize: 10),
                errorText: _nameInvalid
                    ? t(
                        'До 40 символов, без переносов строк',
                        'Up to 40 characters, no line breaks',
                      )
                    : null,
              ),
            ),
            Wrap(
              spacing: 14,
              runSpacing: 2,
              children: [
                TextButton.icon(
                  onPressed: busy ? null : _saveName,
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    foregroundColor: accent,
                  ),
                  icon: AuraIcon(
                    kind: AuraIconKind.arrowRight,
                    size: 17,
                    color: accent,
                  ),
                  label: Text(
                    t('Сохранить имя', 'Save name'),
                    style: text.bodySmall?.copyWith(color: accent),
                  ),
                ),
                TextButton(
                  onPressed: busy ? null : () => _saveName(clear: true),
                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
                  child: Text(
                    t('Удалить имя', 'Delete name'),
                    style: text.bodySmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(t('Язык', 'Language'), style: text.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final entry in const [
                  ('ru', 'Русский'),
                  ('en', 'English'),
                ])
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                        right: entry.$1 == 'ru' ? 16 : 0,
                      ),
                      child: Semantics(
                        selected: _language == entry.$1,
                        child: TextButton(
                          onPressed: busy ? null : () => _languageTo(entry.$1),
                          style: TextButton.styleFrom(
                            alignment: Alignment.centerLeft,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: const RoundedRectangleBorder(),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                entry.$2,
                                style: text.bodyMedium?.copyWith(
                                  color: _language == entry.$1
                                      ? const Color(0xfff2f3f5)
                                      : const Color(0xff929fb2),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Container(
                                height: .7,
                                color: _language == entry.$1
                                    ? accent
                                    : const Color(0x306d8194),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        );
      case _SettingsDestination.senses:
        controls = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SettingsToggle(
              key: const ValueKey('ambient-enabled'),
              title: t('Звук пространства', 'Ambient sound'),
              subtitle: t(
                'Четыре звуковых пространства. Учитывает беззвучный режим.',
                'Four soundscapes. Respects silent mode.',
              ),
              value: profile.ambientEnabled,
              accent: accent,
              onChanged: busy
                  ? null
                  : (value) =>
                        _saveProfile(profile.copyWith(ambientEnabled: value)),
            ),
            const Divider(height: 1),
            _SettingsToggle(
              key: const ValueKey('haptics-enabled'),
              title: t('Тактильный отклик', 'Haptic feedback'),
              subtitle: t(
                'Прикосновение, которое можно почувствовать.',
                'A touch you can feel.',
              ),
              value: profile.hapticsEnabled,
              accent: accent,
              onChanged: busy
                  ? null
                  : (value) =>
                        _saveProfile(profile.copyWith(hapticsEnabled: value)),
            ),
            if (profile.ambientEnabled && widget.ambient?.failed == true)
              Text(
                t('Звук сейчас недоступен.', 'Sound is currently unavailable.'),
                style: text.bodySmall,
              ),
            if (profile.ambientEnabled && widget.ambient?.interrupted == true)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: widget.onResumeAmbient,
                  icon: AuraIcon(
                    kind: AuraIconKind.volume,
                    size: 16,
                    color: accent,
                  ),
                  label: Text(t('Возобновить звук', 'Resume ambient sound')),
                ),
              ),
          ],
        );
      case _SettingsDestination.reminders:
        controls = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_preferences != null)
              _SettingsToggle(
                title: t('Напомнить после паузы', 'Remind me after the pause'),
                subtitle:
                    _language == 'en' && !_preferences!.englishNotifications
                    ? 'Reminders are currently available in Russian.'
                    : t(
                        'Одно тихое напоминание. Без вопроса и ответа.',
                        'One quiet reminder. Without your question or answer.',
                      ),
                accent: accent,
                value:
                    _preferences!.notifications &&
                    (_language == 'ru' || _preferences!.englishNotifications),
                onChanged:
                    busy ||
                        (_language == 'en' &&
                            !_preferences!.englishNotifications)
                    ? null
                    : _notifications,
              )
            else
              Text(
                t(
                  'Загружаем настройки напоминаний…',
                  'Loading reminder settings…',
                ),
                style: text.bodySmall,
              ),
            if (_error)
              Text(
                t(
                  'Не удалось изменить настройки или нет разрешения. Таймер сохранён.',
                  'Settings could not be changed or permission is unavailable. The timer is preserved.',
                ),
                style: text.bodySmall,
              ),
          ],
        );
    }
    return ListView(
      key: ValueKey('settings-detail-${destination.name}'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 40),
      children: [
        SizedBox(
          height: 72,
          child: Center(
            child: SizedBox.square(
              dimension: 60,
              child: CustomPaint(
                painter: _SettingsStar(destination.index, accent),
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Semantics(
          header: true,
          child: Text(
            _title(destination),
            style: text.headlineLarge?.copyWith(
              fontSize: 32,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          destination == _SettingsDestination.personal
              ? t(
                  'Имя остаётся только на этом устройстве.',
                  'Your name stays only on this device.',
                )
              : _subtitle(destination),
          style: text.bodySmall,
        ),
        const SizedBox(height: 28),
        controls,
        if (_error && destination != _SettingsDestination.reminders)
          Text(
            t(
              'Не удалось изменить настройки. Попробуй ещё раз.',
              'Settings could not be changed. Please try again.',
            ),
            style: text.bodySmall,
          ),
        if (widget.controller.failed) ...[
          const SizedBox(height: 16),
          Text(
            t(
              'Не удалось сохранить оформление. Изменения не подтверждены.',
              'Appearance could not be saved. Changes are not confirmed.',
            ),
            style: text.bodySmall,
          ),
          TextButton(
            onPressed: widget.controller.load,
            child: Text(t('Повторить загрузку', 'Retry loading')),
          ),
        ],
      ],
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.ambient?.removeListener(_changed);
    _name.dispose();
    super.dispose();
  }
}

class _SettingsEntry extends StatelessWidget {
  final String title, subtitle;
  final int index;
  final Color accent;
  final VoidCallback onPressed;
  const _SettingsEntry({
    super.key,
    required this.title,
    required this.subtitle,
    required this.index,
    required this.accent,
    required this.onPressed,
  });
  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned(
        right: 9,
        top: 20,
        child: IgnorePointer(
          child: SizedBox(
            width: 28,
            height: 55,
            child: CustomPaint(painter: _SettingsDust(accent)),
          ),
        ),
      ),
      TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.fromLTRB(20, 7, 24, 7),
          minimumSize: const Size(double.infinity, 113),
          shape: const RoundedRectangleBorder(),
          alignment: Alignment.centerLeft,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                fontSize: 32,
                height: 1.1,
                fontWeight: FontWeight.w400,
                letterSpacing: 0,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontSize: 11,
                height: 1.5,
                color: const Color(0xff98aab5),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class _SettingsDust extends CustomPainter {
  final Color accent;
  const _SettingsDust(this.accent);
  @override
  void paint(Canvas canvas, Size size) {
    const points = [
      Offset(.5, 0),
      Offset(.1, .28),
      Offset(.94, .6),
      Offset(.32, .85),
    ];
    for (var i = 0; i < points.length; i++) {
      canvas.drawCircle(
        Offset(points[i].dx * size.width, points[i].dy * size.height),
        1.1,
        Paint()..color = accent.withValues(alpha: .5 - i * .10),
      );
    }
  }

  @override
  bool shouldRepaint(_SettingsDust old) => old.accent != accent;
}

/// Sparse constellations are static vector marks, not another animation layer.
class _SettingsStar extends CustomPainter {
  final int index;
  final Color accent;
  const _SettingsStar(this.index, this.accent);
  @override
  void paint(Canvas canvas, Size size) {
    const shapes = [
      [
        Offset(.08, .62),
        Offset(.3, .22),
        Offset(.62, .42),
        Offset(.9, .15),
        Offset(.76, .86),
      ],
      [
        Offset(.1, .57),
        Offset(.32, .12),
        Offset(.48, .78),
        Offset(.66, .32),
        Offset(.92, .56),
      ],
      [
        Offset(.12, .7),
        Offset(.38, .43),
        Offset(.48, .08),
        Offset(.66, .5),
        Offset(.88, .8),
      ],
      [
        Offset(.12, .32),
        Offset(.42, .14),
        Offset(.8, .36),
        Offset(.66, .82),
        Offset(.28, .65),
      ],
    ];
    final points = shapes[index % shapes.length]
        .map((p) => Offset(p.dx * size.width, p.dy * size.height))
        .toList();
    final line = Paint()
      ..color = accent.withValues(alpha: .35)
      ..strokeWidth = .7
      ..style = PaintingStyle.stroke;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(path, line);
    for (var i = 0; i < points.length; i++) {
      canvas.drawCircle(
        points[i],
        i == 1 ? 2 : 1.2,
        Paint()..color = accent.withValues(alpha: i == 1 ? .95 : .6),
      );
    }
  }

  @override
  bool shouldRepaint(_SettingsStar old) =>
      old.index != index || old.accent != accent;
}

class _SettingsThread extends CustomPainter {
  final Color accent;
  const _SettingsThread(this.accent);
  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..strokeWidth = .6
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          accent.withValues(alpha: .2),
          accent.withValues(alpha: .12),
          Colors.transparent,
        ],
        stops: const [0, .2, .8, 1],
      ).createShader(Offset.zero & size);
    canvas.drawLine(const Offset(40, 20), Offset(-10, size.height - 26), line);
  }

  @override
  bool shouldRepaint(_SettingsThread old) => old.accent != accent;
}

class _SettingsToggle extends StatelessWidget {
  final String title, subtitle;
  final bool value;
  final Color accent;
  final ValueChanged<bool>? onChanged;
  const _SettingsToggle({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.accent,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return Semantics(
      toggled: value,
      enabled: onChanged != null,
      label: '$title. $subtitle',
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: ExcludeSemantics(
        child: TextButton(
          onPressed: onChanged == null ? null : () => onChanged!(!value),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 15),
            shape: const RoundedRectangleBorder(),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: text.bodyMedium?.copyWith(
                        color: onChanged == null
                            ? const Color(0xff8190a4)
                            : const Color(0xfff2f3f5),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      style: text.bodySmall?.copyWith(
                        fontSize: 12,
                        color: const Color(0xff9daabc),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 18),
              AnimatedContainer(
                duration: duration,
                width: 42,
                height: 24,
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: value
                      ? accent.withValues(alpha: .12)
                      : Colors.transparent,
                  border: Border.all(
                    color: value
                        ? accent.withValues(alpha: .6)
                        : const Color(0xff536175),
                    width: .8,
                  ),
                ),
                child: AnimatedAlign(
                  duration: duration,
                  alignment: value
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: onChanged == null
                          ? const Color(0xff536175)
                          : value
                          ? accent
                          : const Color(0xff8b99ad),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A still star field: no blur, shader, sensor, ticker or repeated repaint.
class _SettingsAtmosphere extends CustomPainter {
  final Color accent;
  const _SettingsAtmosphere(this.accent);
  @override
  void paint(Canvas canvas, Size size) {
    final dot = Paint()..color = accent.withValues(alpha: .17);
    for (var i = 0; i < 12; i++) {
      canvas.drawCircle(
        Offset(
          ((i * 73 + 29) % 307) / 307 * size.width,
          ((i * 139 + 59) % 997) / 997 * size.height,
        ),
        i % 4 == 0 ? 1 : .5,
        dot,
      );
    }
  }

  @override
  bool shouldRepaint(_SettingsAtmosphere oldDelegate) =>
      oldDelegate.accent != accent;
}

class PrinciplesPage extends StatefulWidget {
  final String language;
  const PrinciplesPage({super.key, required this.language});
  @override
  State<PrinciplesPage> createState() => _PrinciplesPageState();
}

class _PrinciplesPageState extends State<PrinciplesPage> {
  late Future<NarrationTrack> _track;
  @override
  void initState() {
    super.initState();
    _track = NarrationTrack.load(widget.language);
  }

  @override
  void didUpdateWidget(PrinciplesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.language != widget.language) {
      _track = NarrationTrack.load(widget.language);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.language == 'ru' ? 'Принципы взаимодействия' : 'Our principles',
      ),
    ),
    body: SafeArea(
      child: FutureBuilder<NarrationTrack>(
        future: _track,
        builder: (context, snapshot) => ListView(
          padding: const EdgeInsets.all(28),
          children: [
            if (snapshot.hasData)
              SelectableText(
                snapshot.data!.text,
                style: Theme.of(context).textTheme.bodyLarge,
              )
            else if (snapshot.hasError)
              Text(
                widget.language == 'ru'
                    ? 'Текст недоступен.'
                    : 'Text unavailable.',
              )
            else
              const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    ),
  );
}
