import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'cosmic_scene.dart';
import 'narration.dart';
import 'personalization.dart';
import 'presentation_profile.dart';

class OnboardingPage extends StatefulWidget {
  final PresentationController controller;
  final String language;
  final Future<void> Function(String) onLanguage;
  final NarrationBackend? narrationBackend;
  const OnboardingPage({
    super.key,
    required this.controller,
    required this.language,
    required this.onLanguage,
    this.narrationBackend,
  });
  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage>
    with WidgetsBindingObserver {
  late final TextEditingController _name;
  late final NarrationController _audio;
  NarrationTrack? _track;
  bool _fullText = false,
      _active = true,
      _nameInvalid = false,
      _trackFailed = false;
  int _loadGeneration = 0;
  int _audioEpoch = 0;
  int get _step => widget.controller.profile!.completed
      ? 2
      : widget.controller.profile!.onboardingStep;
  String t(String ru, String en) => widget.language == 'ru' ? ru : en;
  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.controller.profile!.name);
    _audio = NarrationController(
      widget.narrationBackend ?? IosNarrationBackend(),
    )..addListener(_audioChanged);
    WidgetsBinding.instance.addObserver(this);
    _active =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _loadTrack();
  }

  void _audioChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadTrack({bool autoPlay = true}) async {
    final generation = ++_loadGeneration;
    final audioEpoch = _audioEpoch;
    _audio.stop();
    _track = null;
    _trackFailed = false;
    try {
      final track = await NarrationTrack.load(widget.language);
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _track = track);
      if (autoPlay && _step == 2 && audioEpoch == _audioEpoch)
        _startNarration();
    } catch (_) {
      if (mounted && generation == _loadGeneration)
        setState(() => _trackFailed = true);
    }
  }

  void _startNarration() {
    final profile = widget.controller.profile!;
    if (_active &&
        _track != null &&
        profile.audioEnabled &&
        !profile.completed &&
        !_audio.playing &&
        !_audio.starting) {
      unawaited(_audio.play(widget.language));
    }
  }

  @override
  void didUpdateWidget(OnboardingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.language != widget.language) {
      ++_audioEpoch;
      _fullText = true;
      _loadTrack(autoPlay: false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (!_active) {
      ++_audioEpoch;
      _audio.stop();
      _fullText = true;
    }
    // Returning from a call/background never resumes sound without a tap.
    if (mounted) setState(() {});
  }

  Future<void> _go(int step, {bool skipName = false}) async {
    final controller = widget.controller;
    if (controller.busy) return;
    final name = skipName ? '' : _name.text.trim();
    if (_step == 0 && !PresentationProfile.isValidName(name)) {
      setState(() => _nameInvalid = true);
      return;
    }
    _audio.stop();
    final audioEpoch = _audioEpoch;
    final saved = await controller.save(
      controller.profile!.copyWith(
        name: _step == 0 ? name : controller.profile!.name,
        onboardingStep: step,
      ),
    );
    if (mounted && saved) {
      if (skipName) _name.clear();
      if (step == 0) _name.text = controller.profile!.name;
      if (step == 2) {
        _fullText = audioEpoch != _audioEpoch;
        if (audioEpoch == _audioEpoch) _startNarration();
      }
    }
  }

  Future<void> _accept() async {
    if (widget.controller.busy || _track == null) return;
    _audio.stop();
    await widget.controller.acceptTerms();
  }

  Future<void> _toggleAudio(bool enabled) async {
    _audio.stop();
    final audioEpoch = _audioEpoch;
    final ok = await widget.controller.save(
      widget.controller.profile!.copyWith(audioEnabled: enabled),
    );
    if (ok && enabled && mounted && audioEpoch == _audioEpoch)
      _startNarration();
  }

  Widget _body() {
    final controller = widget.controller, profile = controller.profile!;
    final style = Theme.of(context).textTheme;
    if (_step == 0) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 34),
          Text(
            t('Спроси\nВселенную', 'Ask the\nUniverse'),
            style: style.displaySmall,
          ),
          const SizedBox(height: 30),
          Text(
            t(
              'Среди миллиардов звёзд у каждого есть свой вопрос. Но прежде чем ты задашь свой, давай познакомимся. Как мне к тебе обращаться?',
              'Among billions of stars, everyone has a question. Before you ask yours, let’s get to know each other. What should I call you?',
            ),
            style: style.bodyLarge,
          ),
          const SizedBox(height: 30),
          TextField(
            controller: _name,
            maxLength: 40,
            textCapitalization: TextCapitalization.words,
            enableSuggestions: false,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: t('Имя или никнейм', 'Name or nickname'),
              helperText: t(
                'Необязательно · только на этом устройстве',
                'Optional · only on this device',
              ),
              errorText: _nameInvalid
                  ? t(
                      'До 40 символов, без переносов строк',
                      'Up to 40 characters, no line breaks',
                    )
                  : null,
            ),
            onSubmitted: (_) => _go(1),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: controller.busy ? null : () => _go(1),
            child: Text(t('Продолжить', 'Continue')),
          ),
          TextButton(
            onPressed: controller.busy ? null : () => _go(1, skipName: true),
            child: Text(t('Пропустить', 'Skip')),
          ),
        ],
      );
    }
    if (_step == 1) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            t(
              'Выбери, как Вселенная\nбудет тебе отвечать',
              'Choose how the Universe\nwill answer you',
            ),
            style: style.headlineMedium,
          ),
          const SizedBox(height: 28),
          PersonalizationControls(
            profile: profile,
            language: widget.language,
            active: _active,
            busy: controller.busy,
            onChanged: (next) => controller.save(next),
          ),
          const SizedBox(height: 26),
          FilledButton(
            onPressed: controller.busy ? null : () => _go(2),
            child: Text(t('Продолжить', 'Continue')),
          ),
          TextButton(
            onPressed: controller.busy ? null : () => _go(0),
            child: Text(t('Назад', 'Back')),
          ),
        ],
      );
    }
    final track = _track;
    final showAll =
        _fullText ||
        !profile.audioEnabled ||
        profile.completed ||
        (!_audio.playing &&
            !_audio.starting &&
            _audio.durationMs > 0 &&
            _audio.positionMs >= _audio.durationMs) ||
        _audio.failed ||
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    final visible = track == null
        ? ''
        : showAll
        ? track.text
        : track.visibleText(_audio.positionMs);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          t('Принципы взаимодействия', 'Our principles'),
          style: style.headlineMedium,
        ),
        const SizedBox(height: 26),
        if (_trackFailed)
          Text(
            t(
              'Не удалось прочитать текст. Попробуй снова.',
              'Could not load the text. Try again.',
            ),
          ),
        if (_trackFailed)
          TextButton(
            onPressed: _loadTrack,
            child: Text(t('Повторить', 'Retry')),
          ),
        if (track == null && !_trackFailed)
          const Center(child: CircularProgressIndicator()),
        if (track != null)
          Semantics(
            label: track.text,
            child: ExcludeSemantics(
              child: Text(
                visible.isEmpty ? '…' : visible,
                key: const ValueKey('principles-text'),
                style: style.bodyLarge,
              ),
            ),
          ),
        const SizedBox(height: 22),
        if (!profile.completed) ...[
          TextButton(
            onPressed: () => setState(() => _fullText = true),
            child: Text(t('Прочитать весь текст', 'Read the full text')),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: profile.audioEnabled,
            title: Text(t('Озвучка', 'Narration')),
            subtitle: Text(t('Тестовая озвучка', 'Provisional narration')),
            onChanged: controller.busy ? null : _toggleAudio,
          ),
          if (profile.audioEnabled &&
              !_audio.playing &&
              !_audio.starting &&
              track != null)
            TextButton(
              onPressed: _active ? _startNarration : null,
              child: Text(
                t('Прослушать с начала', 'Listen from the beginning'),
              ),
            ),
          if (_audio.failed)
            Text(
              t(
                'Звук недоступен. Текст можно прочитать полностью.',
                'Audio is unavailable. You can read the full text.',
              ),
            ),
        ],
        const SizedBox(height: 22),
        FilledButton(
          onPressed: controller.busy || track == null ? null : _accept,
          child: Text(t('Я понимаю и принимаю', 'I understand and accept')),
        ),
        if (!profile.completed)
          TextButton(
            onPressed: controller.busy ? null : () => _go(1),
            child: Text(t('Назад', 'Back')),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => CosmicScene(
    background: widget.controller.profile!.background.name,
    active: _active,
    child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        actions: [
          for (final language in ['ru', 'en'])
            TextButton(
              onPressed: widget.controller.busy || language == widget.language
                  ? null
                  : () => widget.onLanguage(language),
              child: Text(language == 'ru' ? 'Русский' : 'English'),
            ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              key: ValueKey('onboarding-$_step-${widget.language}'),
              padding: const EdgeInsets.fromLTRB(28, 16, 28, 32),
              children: [
                if (!widget.controller.profile!.completed)
                  Text(
                    '${_step + 1} / 3',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                const SizedBox(height: 20),
                _body(),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  @override
  void dispose() {
    ++_loadGeneration;
    WidgetsBinding.instance.removeObserver(this);
    _audio.removeListener(_audioChanged);
    _audio.dispose();
    _name.dispose();
    super.dispose();
  }
}
