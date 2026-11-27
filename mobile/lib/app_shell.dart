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

class UniverseApp extends StatelessWidget {
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
      ),
    ),
  );
}

class UniverseShell extends StatefulWidget {
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
  });
  @override
  State<UniverseShell> createState() => _UniverseShellState();
}

class _UniverseShellState extends State<UniverseShell>
    with WidgetsBindingObserver {
  late final PresentationController _presentation;
  late final SessionBackend _sessionBackend;
  String _language = 'ru';
  bool _preferencesLoading = true,
      _preferencesFailed = false,
      _languageBusy = false;
  bool _foreground = true, _covered = false;
  int _tab = 0, _languageRevision = 0;
  String t(String ru, String en) => _language == 'ru' ? ru : en;
  @override
  void initState() {
    super.initState();
    _sessionBackend = widget.sessionBackend ?? const IosSessionBackend();
    _presentation = PresentationController(
      widget.presentationBackend ?? IosPresentationBackend(),
    )..addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _load();
  }

  void _changed() {
    if (mounted) setState(() {});
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
    return CosmicScene(
      background: profile.background.name,
      active: _foreground && !_covered,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: Text(t('Спроси Вселенную', 'Ask the Universe')),
          actions: [
            IconButton(
              key: const ValueKey('open-settings'),
              tooltip: t('Настройки', 'Settings'),
              onPressed: _settings,
              icon: const Icon(Icons.tune_rounded),
            ),
          ],
        ),
        body: IndexedStack(
          index: _tab,
          children: [
            TickerMode(
              enabled: _tab == 0 && !_covered,
              child: SessionPage(
                embedded: true,
                active: _tab == 0 && !_covered,
                nickname: profile.name,
                languageRevision: _languageRevision,
                backend: _sessionBackend,
                voiceBackend: widget.voiceBackend,
                inspector: widget.inspector,
                random: widget.random,
              ),
            ),
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(32),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.public_rounded,
                          size: 48,
                          color: Color(0xffaabbd7),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          t('Что волнует мир', 'What moves the world'),
                          style: Theme.of(context).textTheme.headlineMedium,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 18),
                        Text(
                          t(
                            'Этот раздел появится в следующем обновлении. Сейчас данные не собираются.',
                            'This section is coming in a future update. No data is being collected.',
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          backgroundColor: const Color(0xe6090e20),
          onDestinationSelected: (index) => setState(() => _tab = index),
          destinations: [
            NavigationDestination(
              icon: const Icon(Icons.auto_awesome_outlined),
              selectedIcon: const Icon(Icons.auto_awesome),
              label: t('Вселенная', 'Universe'),
            ),
            NavigationDestination(
              icon: const Icon(Icons.public_outlined),
              selectedIcon: const Icon(Icons.public),
              label: t('Что волнует мир', 'The world'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _presentation.removeListener(_changed);
    _presentation.dispose();
    super.dispose();
  }
}

class PresentationSettings extends StatefulWidget {
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
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  TextField(
                    controller: _name,
                    maxLength: 40,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: t('Имя или никнейм', 'Name or nickname'),
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
                    children: [
                      FilledButton(
                        onPressed: busy ? null : _saveName,
                        child: Text(t('Сохранить имя', 'Save name')),
                      ),
                      TextButton(
                        onPressed: busy ? null : () => _saveName(clear: true),
                        child: Text(t('Удалить имя', 'Delete name')),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  Text(
                    t('Язык', 'Language'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Wrap(
                    spacing: 12,
                    children: [
                      for (final language in ['ru', 'en'])
                        TextButton(
                          onPressed: busy || language == _language
                              ? null
                              : () => _languageTo(language),
                          child: Text(language == 'ru' ? 'Русский' : 'English'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  PersonalizationControls(
                    profile: profile,
                    language: _language,
                    busy: busy,
                    active: !_covered,
                    onChanged: (next) => widget.controller.save(next),
                  ),
                  const SizedBox(height: 28),
                  if (_preferences != null)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        t('Напомнить после паузы', 'Remind me after the pause'),
                      ),
                      subtitle: Text(
                        _language == 'en' && !_preferences!.englishNotifications
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
                    ),
                  if (_error)
                    Text(
                      t(
                        'Не удалось изменить настройки или нет разрешения. Таймер сохранён.',
                        'Settings could not be changed or permission is unavailable. The timer is preserved.',
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
                  const SizedBox(height: 24),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(t('Принципы взаимодействия', 'Our principles')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(PrinciplesPage(language: _language)),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(t('Проверка ядра', 'Core check')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(const SessionPage(diagnostic: true)),
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
    _name.dispose();
    super.dispose();
  }
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
