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
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            IndexedStack(
              index: _tab,
              children: [
                TickerMode(
                  enabled:
                      _startupDone && _tab == 0 && !_covered && !_answerCover,
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
                        _startupDone && _foreground && _tab == 1 && !_covered,
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
            if (!_startupDone)
              Positioned.fill(
                child: UniverseStartup(
                  language: _language,
                  name: profile.name,
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

class _PresentationSettingsState extends State<PresentationSettings> {
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
    await widget.controller.save(
      widget.controller.profile!.copyWith(name: name),
    );
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

  @override
  Widget build(BuildContext context) {
    final profile = widget.controller.profile!,
        busy = _busy || widget.controller.busy;
    return CosmicScene(
      background: profile.background.name,
      active: !_covered,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: Text(t('Настройки', 'Settings')),
          centerTitle: true,
          leading: IconButton(
            tooltip: t('Назад', 'Back'),
            icon: const AuraIcon(kind: AuraIconKind.back),
            onPressed: () => Navigator.of(context).pop(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t('Готово', 'Done')),
            ),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 4, 6, 24),
                    child: Text(
                      t(
                        'Пусть это пространство будет твоим.',
                        'Make this space your own.',
                      ),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  _SettingsPanel(
                    title: t('Личное', 'Personal'),
                    description: t(
                      'Необязательно. Имя остаётся только на этом устройстве.',
                      'Optional. Your name stays only on this device.',
                    ),
                    icon: AuraIconKind.brand,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _name,
                          maxLength: 40,
                          enableSuggestions: false,
                          autocorrect: false,
                          onChanged: (_) {
                            if (_nameInvalid)
                              setState(() => _nameInvalid = false);
                          },
                          decoration: InputDecoration(
                            labelText: t('Имя или никнейм', 'Name or nickname'),
                            filled: true,
                            fillColor: const Color(0x24050915),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: const BorderSide(
                                color: Color(0x30c5cad3),
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide(
                                color: auraAccent(profile.background.name)
                                    .withValues(alpha: .7),
                              ),
                            ),
                            errorText: _nameInvalid
                                ? t(
                                    'До 40 символов, без переносов строк',
                                    'Up to 40 characters, no line breaks',
                                  )
                                : null,
                          ),
                        ),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            FilledButton(
                              onPressed: busy ? null : _saveName,
                              child: Text(t('Сохранить имя', 'Save name')),
                            ),
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => _saveName(clear: true),
                              child: Text(t('Удалить имя', 'Delete name')),
                            ),
                          ],
                        ),
                        const SizedBox(height: 28),
                        Text(
                          t('Язык', 'Language'),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        SegmentedButton<String>(
                          style: ButtonStyle(
                            backgroundColor: WidgetStateProperty.resolveWith(
                              (states) => states.contains(WidgetState.selected)
                                  ? const Color(0x24c5cad3)
                                  : Colors.transparent,
                            ),
                            foregroundColor: const WidgetStatePropertyAll(
                              CosmicPalette.white,
                            ),
                            side: const WidgetStatePropertyAll(
                              BorderSide(color: Color(0x55c5cad3), width: .8),
                            ),
                          ),
                          segments: const [
                            ButtonSegment(value: 'ru', label: Text('Русский')),
                            ButtonSegment(value: 'en', label: Text('English')),
                          ],
                          selected: {_language},
                          showSelectedIcon: false,
                          onSelectionChanged: busy
                              ? null
                              : (value) => _languageTo(value.single),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  _SettingsPanel(
                    title: t('Твоя Вселенная', 'Your Universe'),
                    description: t(
                      'Выбирай пространство и форму независимо друг от друга.',
                      'Choose your space and form independently.',
                    ),
                    icon: AuraIconKind.universe,
                    child: PersonalizationControls(
                      profile: profile,
                      language: _language,
                      busy: busy,
                      active: !_covered,
                      onChanged: (next) => widget.controller.save(next),
                    ),
                  ),
                  const SizedBox(height: 20),
                  _SettingsPanel(
                    title: t('Звук и ощущения', 'Sound and feeling'),
                    icon: AuraIconKind.volume,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SwitchListTile(
                          key: const ValueKey('ambient-enabled'),
                          contentPadding: EdgeInsets.zero,
                          title: Text(t('Звук пространства', 'Ambient sound')),
                          subtitle: Text(
                            t(
                              'Четыре встроенных фона. Учитывает беззвучный режим iPhone.',
                              'Four built-in soundscapes. Respects iPhone silent mode.',
                            ),
                          ),
                          value: profile.ambientEnabled,
                          onChanged: busy
                              ? null
                              : (value) => widget.controller.save(
                                  profile.copyWith(ambientEnabled: value),
                                ),
                        ),
                        SwitchListTile(
                          key: const ValueKey('haptics-enabled'),
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            t('Тактильный отклик', 'Haptic feedback'),
                          ),
                          subtitle: Text(
                            t(
                              'Мягкие импульсы во время касаний и анимации',
                              'Gentle pulses during touch and animation',
                            ),
                          ),
                          value: profile.hapticsEnabled,
                          onChanged: busy
                              ? null
                              : (value) => widget.controller.save(
                                  profile.copyWith(hapticsEnabled: value),
                                ),
                        ),
                        if (profile.ambientEnabled &&
                            widget.ambient?.failed == true)
                          Text(
                            t(
                              'Звук сейчас недоступен.',
                              'Sound is currently unavailable.',
                            ),
                          ),
                        if (profile.ambientEnabled &&
                            widget.ambient?.interrupted == true)
                          TextButton(
                            onPressed: widget.onResumeAmbient,
                            child: Text(
                              t('Возобновить звук', 'Resume ambient sound'),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  _SettingsPanel(
                    title: t('Твоя пауза', 'Your pause'),
                    icon: AuraIconKind.settings,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_preferences != null)
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              t(
                                'Напомнить после паузы',
                                'Remind me after the pause',
                              ),
                            ),
                            subtitle: Text(
                              _language == 'en' &&
                                      !_preferences!.englishNotifications
                                  ? 'Reminders are currently available in Russian.'
                                  : t(
                                      'Одно уведомление без вопроса и ответа',
                                      'One notification without the question or answer',
                                    ),
                            ),
                            value:
                                _preferences!.notifications &&
                                (_language == 'ru' ||
                                    _preferences!.englishNotifications),
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
                          ),
                        if (_error)
                          Text(
                            t(
                              'Не удалось изменить настройки или нет разрешения. Таймер сохранён.',
                              'Settings could not be changed or permission is unavailable. The timer is preserved.',
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (widget.controller.failed) ...[
                    Text(
                      t(
                        'Не удалось сохранить оформление. Изменения не подтверждены.',
                        'Appearance could not be saved. Changes are not confirmed.',
                      ),
                    ),
                    TextButton(
                      onPressed: widget.controller.load,
                      child: Text(t('Повторить загрузку', 'Retry loading')),
                    ),
                  ],
                  const SizedBox(height: 20),
                  _SettingsPanel(
                    title: t('О приложении', 'About'),
                    icon: AuraIconKind.brand,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            t('Принципы взаимодействия', 'Our principles'),
                          ),
                          trailing: const AuraIcon(
                            kind: AuraIconKind.arrowRight,
                          ),
                          onTap: () =>
                              _open(PrinciplesPage(language: _language)),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          t(
                            'Пространство для размышлений. Ответы случайны и не предназначены для принятия важных решений.',
                            'A space for reflection. Answers are random and are not intended for important decisions.',
                          ),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    t(
                      'Спроси Вселенную · 0.6.1 (11)',
                      'Ask the Universe · 0.6.1 (11)',
                    ),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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

class _SettingsPanel extends StatelessWidget {
  final String title;
  final String? description;
  final AuraIconKind icon;
  final Widget child;
  const _SettingsPanel({
    required this.title,
    required this.icon,
    required this.child,
    this.description,
  });

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(26),
      border: Border.all(color: const Color(0x26c5cad3), width: .8),
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xc2161b2a), Color(0xc2080b16)],
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                const SizedBox(width: 12),
                AuraIcon(
                  kind: icon,
                  size: 22,
                  color: CosmicPalette.silver.withValues(alpha: .7),
                ),
              ],
            ),
          ),
          if (description != null) ...[
            const SizedBox(height: 8),
            Text(description!, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 18),
          child,
        ],
      ),
    ),
  );
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
