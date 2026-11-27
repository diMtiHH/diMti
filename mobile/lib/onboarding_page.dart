import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'aura_renderer.dart';
import 'aura_ui.dart';
import 'narration.dart';
import 'personalization.dart';
import 'presentation_profile.dart';

class OnboardingPage extends StatefulWidget {
  final PresentationController controller;
  final String language;
  final Future<void> Function(String) onLanguage;
  final NarrationBackend? narrationBackend;
  final bool active;
  const OnboardingPage({
    super.key,
    required this.controller,
    required this.language,
    required this.onLanguage,
    this.narrationBackend,
    this.active = true,
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
      _foreground = true,
      _nameInvalid = false,
      _trackFailed = false;
  int _loadGeneration = 0;
  int _audioEpoch = 0;
  bool get _active => _foreground && widget.active;
  bool get _blocked =>
      widget.controller.busy || widget.controller.failed || !_active;
  int get _step => widget.controller.profile!.completed
      ? 2
      : widget.controller.profile!.onboardingStep;
  String t(String ru, String en) => widget.language == 'ru' ? ru : en;
  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.controller.profile!.name);
    widget.controller.addListener(_profileChanged);
    _audio = NarrationController(
      widget.narrationBackend ?? IosNarrationBackend(),
    )..addListener(_audioChanged);
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _loadTrack();
  }

  void _audioChanged() {
    if (mounted) setState(() {});
  }

  void _profileChanged() {
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
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_profileChanged);
      widget.controller.addListener(_profileChanged);
      _name.text = widget.controller.profile!.name;
    }
    if (oldWidget.active && !widget.active) {
      ++_audioEpoch;
      _audio.stop();
      _fullText = true;
    }
    if (oldWidget.language != widget.language) {
      ++_audioEpoch;
      _fullText = true;
      _loadTrack(autoPlay: false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
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
    if (controller.busy || controller.failed || !_active) return;
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
    if (widget.controller.busy ||
        widget.controller.failed ||
        !_active ||
        _track == null)
      return;
    _audio.stop();
    await widget.controller.acceptTerms();
  }

  Future<void> _toggleAudio(bool enabled) async {
    if (widget.controller.busy || widget.controller.failed || !_active) return;
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
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 7, right: 16),
                child: AuraBrandMark(
                  size: 34,
                  color: auraAccent(profile.background.name),
                ),
              ),
              Expanded(
                child: Text(
                  t('Спроси\nВселенную', 'Ask the\nUniverse'),
                  style: style.displaySmall,
                ),
              ),
            ],
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
              labelText: t('Твоё имя', 'Your name'),
              enabledBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Color(0x446f8598)),
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(
                  color: auraAccent(profile.background.name),
                ),
              ),
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
            onPressed: _blocked ? null : () => _go(1),
            child: Text(t('Продолжить', 'Continue')),
          ),
          TextButton(
            onPressed: _blocked ? null : () => _go(1, skipName: true),
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
            busy: _blocked,
            onChanged: (next) => controller.save(next),
          ),
          const SizedBox(height: 26),
          FilledButton(
            onPressed: _blocked ? null : () => _go(2),
            child: Text(t('Продолжить', 'Continue')),
          ),
          TextButton(
            onPressed: _blocked ? null : () => _go(0),
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
            onChanged: _blocked ? null : _toggleAudio,
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
          onPressed: _blocked || track == null ? null : _accept,
          child: Text(t('Я понимаю и принимаю', 'I understand and accept')),
        ),
        if (!profile.completed)
          TextButton(
            onPressed: _blocked ? null : () => _go(1),
            child: Text(t('Назад', 'Back')),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => AuraScene(
    background: widget.controller.profile!.background.name,
    form: widget.controller.profile!.answerStyle.name,
    active: _active,
    showForm: false,
    preview: _step == 1,
    child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 20),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'ru',
                  label: Text('RU'),
                  tooltip: 'Русский',
                ),
                ButtonSegment(
                  value: 'en',
                  label: Text('EN'),
                  tooltip: 'English',
                ),
              ],
              selected: {widget.language},
              showSelectedIcon: false,
              onSelectionChanged: _blocked
                  ? null
                  : (values) => widget.onLanguage(values.single),
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                minimumSize: WidgetStatePropertyAll(Size(48, 44)),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              key: ValueKey('onboarding-$_step-${widget.language}'),
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
              children: [
                if (widget.controller.failed) ...[
                  Text(
                    t(
                      'Не удалось сохранить настройки. Данные не сброшены.',
                      'Could not save settings. Your data has not been reset.',
                    ),
                  ),
                  TextButton(
                    onPressed: widget.controller.busy
                        ? null
                        : widget.controller.load,
                    child: Text(t('Повторить загрузку', 'Retry loading')),
                  ),
                  const SizedBox(height: 16),
                ],
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
    widget.controller.removeListener(_profileChanged);
    _audio.removeListener(_audioChanged);
    _audio.dispose();
    _name.dispose();
    super.dispose();
  }
}
