import 'package:material_ui/material_ui.dart';

import 'aura_renderer.dart';
import 'aura_ui.dart';
import 'presentation_profile.dart';

String backgroundLabel(PresentationBackground value, String language) {
  final ru = language == 'ru';
  return switch (value) {
    PresentationBackground.stars => ru ? 'Звёздная пустота' : 'Starry Void',
    PresentationBackground.galaxy => ru ? 'Галактика' : 'Galaxy',
    PresentationBackground.aurora => ru ? 'Полярное сияние' : 'Aurora',
    PresentationBackground.gravity => ru ? 'Гравитация' : 'Gravity',
  };
}

String answerStyleLabel(PresentationAnswerStyle value, String language) {
  final ru = language == 'ru';
  return switch (value) {
    PresentationAnswerStyle.livingMatter =>
      ru ? 'Живая материя' : 'Living Matter',
    PresentationAnswerStyle.liquidMetal =>
      ru ? 'Жидкий металл' : 'Liquid Metal',
    PresentationAnswerStyle.infinity => ru ? 'Бесконечность' : 'Infinity',
    PresentationAnswerStyle.constellation => ru ? 'Созвездие' : 'Constellation',
  };
}

/// Visual previews have no access to the question session, model, random source,
/// notifications or cooldown clock.
class PersonalizationControls extends StatefulWidget {
  final PresentationProfile profile;
  final String language;
  final bool busy, active;
  final ValueChanged<PresentationProfile> onChanged;
  const PersonalizationControls({
    super.key,
    required this.profile,
    required this.language,
    required this.onChanged,
    this.busy = false,
    this.active = true,
  });
  @override
  State<PersonalizationControls> createState() =>
      _PersonalizationControlsState();
}

class _PersonalizationControlsState extends State<PersonalizationControls>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _preview = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4500),
  )..addStatusListener(_status);
  bool _foreground = true;
  bool get _active => widget.active && _foreground;
  String t(String ru, String en) => widget.language == 'ru' ? ru : en;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  void _status(AnimationStatus status) {
    if (mounted) setState(() {});
  }

  void _stopPreview() {
    _preview.stop();
    _preview.reset();
  }

  @override
  void didUpdateWidget(PersonalizationControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_active ||
        oldWidget.profile.background != widget.profile.background ||
        oldWidget.profile.answerStyle != widget.profile.answerStyle)
      _stopPreview();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _stopPreview();
    if (mounted) setState(() {});
  }

  void _startPreview() {
    if (!_active || widget.busy || _preview.isAnimating) return;
    _preview.duration =
        MediaQuery.disableAnimationsOf(context) ||
            MediaQuery.accessibleNavigationOf(context)
        ? const Duration(milliseconds: 350)
        : const Duration(milliseconds: 4500);
    _preview.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PreviewCarousel(
          kind: 'background',
          title: t('Пространство', 'Space'),
          language: widget.language,
          selected: profile.background.index,
          names: [
            for (final value in PresentationBackground.values) value.name,
          ],
          labels: [
            for (final value in PresentationBackground.values)
              backgroundLabel(value, widget.language),
          ],
          height: 180,
          active: _active,
          busy: widget.busy,
          accent: auraAccent(profile.background.name),
          onSelected: (index) {
            _stopPreview();
            widget.onChanged(
              profile.copyWith(
                background: PresentationBackground.values[index],
              ),
            );
          },
          scene: (index, active) => _PreviewScene(
            background: PresentationBackground.values[index].name,
            form: profile.answerStyle.name,
            active: active && !_preview.isAnimating,
            showForm: false,
            label: backgroundLabel(
              PresentationBackground.values[index],
              widget.language,
            ),
          ),
        ),
        const SizedBox(height: 28),
        _PreviewCarousel(
          kind: 'answer-style',
          title: t('Форма ответа', 'Answer form'),
          language: widget.language,
          selected: profile.answerStyle.index,
          names: [
            for (final value in PresentationAnswerStyle.values) value.name,
          ],
          labels: [
            for (final value in PresentationAnswerStyle.values)
              answerStyleLabel(value, widget.language),
          ],
          height: 210,
          active: _active,
          busy: widget.busy,
          accent: auraAccent(profile.background.name),
          onSelected: (index) {
            _stopPreview();
            widget.onChanged(
              profile.copyWith(
                answerStyle: PresentationAnswerStyle.values[index],
              ),
            );
          },
          scene: (index, active) => AnimatedBuilder(
            animation: _preview,
            builder: (context, _) => _PreviewScene(
              background: profile.background.name,
              form: PresentationAnswerStyle.values[index].name,
              active: active,
              phase: _preview.isAnimating && active
                  ? AuraPhase.answerAnimation
                  : AuraPhase.idle,
              progress: active ? _preview.value : 0,
              showForm: true,
              label: t(
                'Интерактивное превью формы',
                'Interactive form preview',
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const ValueKey('preview-animation'),
          onPressed: !_active || widget.busy || _preview.isAnimating
              ? null
              : _startPreview,
          icon: const AuraIcon(kind: AuraIconKind.universe, size: 20),
          label: Text(t('Посмотреть анимацию', 'Preview animation')),
        ),
        const SizedBox(height: 8),
        Text(
          t(
            'Предпросмотр · без вопроса и ответа',
            'Preview · no question or answer',
          ),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _preview.removeStatusListener(_status);
    _preview.dispose();
    super.dispose();
  }
}

class _PreviewCarousel extends StatefulWidget {
  final String kind, title, language;
  final List<String> names, labels;
  final int selected;
  final double height;
  final bool active, busy;
  final Color accent;
  final ValueChanged<int> onSelected;
  final Widget Function(int index, bool active) scene;
  const _PreviewCarousel({
    required this.kind,
    required this.title,
    required this.language,
    required this.names,
    required this.labels,
    required this.selected,
    required this.height,
    required this.active,
    required this.busy,
    required this.accent,
    required this.onSelected,
    required this.scene,
  });
  @override
  State<_PreviewCarousel> createState() => _PreviewCarouselState();
}

class _PreviewCarouselState extends State<_PreviewCarousel> {
  late final PageController _pages = PageController(
    initialPage: widget.selected,
  );
  late int _page = widget.selected;
  bool _syncing = false;
  bool get _enabled => widget.active && !widget.busy;
  @override
  void didUpdateWidget(_PreviewCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A rejected save restores the confirmed choice without another write.
    if (!widget.busy && _page != widget.selected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !_pages.hasClients ||
            widget.busy ||
            _page == widget.selected)
          return;
        _syncing = true;
        _pages.jumpToPage(widget.selected);
        setState(() => _page = widget.selected);
        _syncing = false;
      });
    }
  }

  void _choose(int index) {
    if (!_enabled ||
        index < 0 ||
        index >= widget.names.length ||
        index == _page)
      return;
    if ((index - _page).abs() > 1 ||
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context)) {
      _pages.jumpToPage(index);
    } else {
      _pages.animateToPage(
        index,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ru = widget.language == 'ru';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 14),
        SizedBox(
          height: widget.height,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: PageView.builder(
              key: ValueKey('${widget.kind}-carousel'),
              controller: _pages,
              itemCount: widget.names.length,
              physics: _enabled
                  ? const PageScrollPhysics()
                  : const NeverScrollableScrollPhysics(),
              onPageChanged: (index) {
                setState(() => _page = index);
                if (!_syncing && _enabled && index != widget.selected)
                  widget.onSelected(index);
              },
              itemBuilder: (context, index) =>
                  widget.scene(index, widget.active && index == _page),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            IconButton(
              key: ValueKey('${widget.kind}-previous'),
              tooltip: ru ? 'Предыдущий вариант' : 'Previous option',
              onPressed: _enabled && _page > 0
                  ? () => _choose(_page - 1)
                  : null,
              icon: const AuraIcon(kind: AuraIconKind.back),
            ),
            Expanded(
              child: Text(
                widget.labels[_page],
                key: ValueKey('${widget.kind}-label'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
            IconButton(
              key: ValueKey('${widget.kind}-next'),
              tooltip: ru ? 'Следующий вариант' : 'Next option',
              onPressed: _enabled && _page < widget.names.length - 1
                  ? () => _choose(_page + 1)
                  : null,
              icon: const RotatedBox(
                quarterTurns: 2,
                child: AuraIcon(kind: AuraIconKind.back),
              ),
            ),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var index = 0; index < widget.names.length; ++index)
              Semantics(
                label:
                    '${widget.labels[index]}, ${index + 1} ${ru ? 'из' : 'of'} ${widget.names.length}',
                button: true,
                selected: _page == index,
                enabled: _enabled,
                child: InkResponse(
                  key: ValueKey('${widget.kind}-${widget.names[index]}'),
                  onTap: _enabled ? () => _choose(index) : null,
                  radius: 22,
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Center(
                      child: Container(
                        width: _page == index ? 7 : 4,
                        height: _page == index ? 7 : 4,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: widget.accent.withValues(
                            alpha: _page == index ? 0.95 : 0.3,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }
}

class _PreviewScene extends StatefulWidget {
  final String background, form, label;
  final bool active, showForm;
  final AuraPhase phase;
  final double progress;
  const _PreviewScene({
    required this.background,
    required this.form,
    required this.active,
    required this.showForm,
    required this.label,
    this.phase = AuraPhase.idle,
    this.progress = 0,
  });
  @override
  State<_PreviewScene> createState() => _PreviewSceneState();
}

class _PreviewSceneState extends State<_PreviewScene> {
  final _interaction = AuraInteractionController();
  @override
  Widget build(BuildContext context) => AuraTouchSurface(
    interaction: _interaction,
    active: widget.active,
    label: widget.label,
    phase: widget.phase,
    child: AuraScene(
      background: widget.background,
      form: widget.form,
      interaction: _interaction,
      active: widget.active,
      showForm: widget.showForm,
      preview: true,
      phase: widget.phase,
      progress: widget.progress,
      formAlignment: Alignment.center,
      formScale: 0.9,
      child: const SizedBox.expand(),
    ),
  );
  @override
  void dispose() {
    _interaction.dispose();
    super.dispose();
  }
}
