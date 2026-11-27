import 'package:material_ui/material_ui.dart';

import 'aura_renderer.dart';
import 'aura_ui.dart';
import 'aura_haptics.dart';
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
  final AuraHapticsBackend? hapticsBackend;
  const PersonalizationControls({
    super.key,
    required this.profile,
    required this.language,
    required this.onChanged,
    this.busy = false,
    this.active = true,
    this.hapticsBackend,
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
  late final AuraHapticsController _haptics = AuraHapticsController(
    backend: widget.hapticsBackend,
  );
  bool _foreground = true;
  bool _reducedPreview = false;
  bool get _active => widget.active && _foreground;
  String t(String ru, String en) => widget.language == 'ru' ? ru : en;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _configureHaptics();
  }

  void _configureHaptics() => _haptics.configure(
    enabled: widget.profile.hapticsEnabled,
    active: _active,
  );

  void _status(AnimationStatus status) {
    if (status == AnimationStatus.completed && !_reducedPreview) {
      _haptics.reveal();
    }
    if (mounted) setState(() {});
  }

  void _stopPreview() {
    _preview.stop();
    _preview.reset();
    _haptics.cancel();
  }

  @override
  void didUpdateWidget(PersonalizationControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    _configureHaptics();
    if (!_active ||
        oldWidget.profile.background != widget.profile.background ||
        oldWidget.profile.answerStyle != widget.profile.answerStyle)
      _stopPreview();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _configureHaptics();
    if (!_foreground) _stopPreview();
    if (mounted) setState(() {});
  }

  void _startPreview() {
    if (!_active || widget.busy || _preview.isAnimating) return;
    _reducedPreview =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    _preview.duration = _reducedPreview
        ? const Duration(milliseconds: 350)
        : const Duration(milliseconds: 4500);
    _configureHaptics();
    if (_reducedPreview) {
      _haptics.tap();
    } else {
      _haptics.animationStart();
    }
    _preview.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    final accent = auraAccent(profile.background.name);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A single composed sample replaces two independently animated scenes.
        // Idle settings are still; only this explicit preview owns a ticker.
        SizedBox(
          height: 224,
          child: AnimatedBuilder(
            animation: _preview,
            builder: (context, _) => _PreviewScene(
              background: profile.background.name,
              form: profile.answerStyle.name,
              active: _active && _preview.isAnimating,
              phase: _preview.isAnimating
                  ? AuraPhase.answerAnimation
                  : AuraPhase.idle,
              progress: _preview.isAnimating ? _preview.value : 0,
            ),
          ),
        ),
        Align(
          alignment: Alignment.center,
          child: OutlinedButton.icon(
            key: const ValueKey('preview-animation'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(48, 48),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
              side: BorderSide(color: accent.withValues(alpha: .28), width: .7),
            ),
            onPressed: !_active || widget.busy || _preview.isAnimating
                ? null
                : _startPreview,
            icon: AuraIcon(
              kind: AuraIconKind.universe,
              size: 16,
              color: accent,
            ),
            label: Text(t('Посмотреть анимацию', 'Preview animation')),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          t(
            'Предпросмотр · без вопроса и ответа',
            'Preview · no question or answer',
          ),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11),
        ),
        const SizedBox(height: 24),
        _AppearanceSelector(
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
          active: _active,
          busy: widget.busy,
          accent: accent,
          onSelected: (index) {
            _stopPreview();
            widget.onChanged(
              profile.copyWith(
                background: PresentationBackground.values[index],
              ),
            );
          },
        ),
        const SizedBox(height: 24),
        _AppearanceSelector(
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
          active: _active,
          busy: widget.busy,
          accent: accent,
          onSelected: (index) {
            _stopPreview();
            widget.onChanged(
              profile.copyWith(
                answerStyle: PresentationAnswerStyle.values[index],
              ),
            );
          },
        ),
      ],
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _preview.removeStatusListener(_status);
    _preview.dispose();
    _haptics.dispose();
    super.dispose();
  }
}

/// Both controls edit the confirmed profile directly. There is no optimistic
/// page index which could visually diverge from a rejected native save.
class _AppearanceSelector extends StatelessWidget {
  final String kind, title, language;
  final List<String> names, labels;
  final int selected;
  final bool active, busy;
  final Color accent;
  final ValueChanged<int> onSelected;
  const _AppearanceSelector({
    required this.kind,
    required this.title,
    required this.language,
    required this.names,
    required this.labels,
    required this.selected,
    required this.active,
    required this.busy,
    required this.accent,
    required this.onSelected,
  });
  bool get enabled => active && !busy;
  void choose(int index) {
    if (enabled && index >= 0 && index < names.length && index != selected)
      onSelected(index);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final ru = language == 'ru';
    var dragDistance = 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(title, style: theme.titleMedium)),
            IconButton(
              key: ValueKey('$kind-previous'),
              tooltip: ru ? 'Предыдущий вариант' : 'Previous option',
              onPressed: enabled && selected > 0
                  ? () => choose(selected - 1)
                  : null,
              icon: const AuraIcon(kind: AuraIconKind.back, size: 17),
            ),
            Text(
              '${selected + 1} / ${names.length}',
              style: theme.bodySmall?.copyWith(fontSize: 11),
            ),
            IconButton(
              key: ValueKey('$kind-next'),
              tooltip: ru ? 'Следующий вариант' : 'Next option',
              onPressed: enabled && selected < names.length - 1
                  ? () => choose(selected + 1)
                  : null,
              icon: const RotatedBox(
                quarterTurns: 2,
                child: AuraIcon(kind: AuraIconKind.back, size: 17),
              ),
            ),
          ],
        ),
        GestureDetector(
          key: ValueKey('$kind-carousel'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: enabled ? (_) => dragDistance = 0 : null,
          onHorizontalDragUpdate: enabled
              ? (details) => dragDistance += details.primaryDelta ?? 0
              : null,
          onHorizontalDragEnd: enabled
              ? (details) {
                  if (dragDistance.abs() > 28)
                    choose(selected + (dragDistance < 0 ? 1 : -1));
                }
              : null,
          child: LayoutBuilder(
            builder: (context, bounds) {
              final width = (bounds.maxWidth - 12) / 2;
              return Wrap(
                spacing: 12,
                runSpacing: 6,
                children: [
                  for (var index = 0; index < names.length; index++)
                    SizedBox(
                      width: width,
                      child: Semantics(
                        selected: index == selected,
                        child: TextButton(
                          key: ValueKey('$kind-${names[index]}'),
                          onPressed: enabled ? () => choose(index) : null,
                          style: TextButton.styleFrom(
                            minimumSize: const Size(44, 52),
                            padding: const EdgeInsets.fromLTRB(10, 12, 8, 12),
                            alignment: Alignment.centerLeft,
                            shape: const RoundedRectangleBorder(),
                            backgroundColor: index == selected
                                ? accent.withValues(alpha: .07)
                                : Colors.transparent,
                            foregroundColor: index == selected
                                ? const Color(0xfff2f3f5)
                                : const Color(0xffa8b2c2),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      top: 2,
                                      right: 8,
                                    ),
                                    child: Text(
                                      '0${index + 1}',
                                      style: theme.bodySmall?.copyWith(
                                        fontSize: 10,
                                        color: index == selected
                                            ? accent
                                            : const Color(0xff747f94),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      labels[index],
                                      style: theme.bodySmall?.copyWith(
                                        fontSize: 12,
                                        color: index == selected
                                            ? const Color(0xfff2f3f5)
                                            : const Color(0xffa8b2c2),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Container(
                                height: .7,
                                color: index == selected
                                    ? accent.withValues(alpha: .75)
                                    : const Color(0x26a8b2c2),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PreviewScene extends StatefulWidget {
  final String background, form;
  final bool active;
  final AuraPhase phase;
  final double progress;
  const _PreviewScene({
    required this.background,
    required this.form,
    required this.active,
    required this.phase,
    required this.progress,
  });
  @override
  State<_PreviewScene> createState() => _PreviewSceneState();
}

class _PreviewSceneState extends State<_PreviewScene> {
  final _interaction = AuraInteractionController();
  @override
  Widget build(BuildContext context) => RepaintBoundary(
    key: const ValueKey('appearance-preview'),
    child: Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: CustomPaint(
            painter: _PreviewOrbit(auraAccent(widget.background)),
          ),
        ),
        AuraScene(
          background: widget.background,
          form: widget.form,
          interaction: _interaction,
          active: widget.active,
          showBackground: false,
          showForm: true,
          preview: true,
          phase: widget.phase,
          progress: widget.progress,
          formAlignment: Alignment.center,
          formScale: .86,
          child: const SizedBox.expand(),
        ),
      ],
    ),
  );
  @override
  void dispose() {
    _interaction.dispose();
    super.dispose();
  }
}

class _PreviewOrbit extends CustomPainter {
  final Color accent;
  const _PreviewOrbit(this.accent);
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.height * .43;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .65
      ..color = accent.withValues(alpha: .16);
    canvas.drawCircle(center, radius, line);
    canvas.drawLine(
      Offset(0, center.dy),
      Offset(center.dx - radius - 10, center.dy),
      line,
    );
    canvas.drawLine(
      Offset(center.dx + radius + 10, center.dy),
      Offset(size.width, center.dy),
      line,
    );
    final dot = Paint()..color = accent.withValues(alpha: .7);
    canvas.drawCircle(center + Offset(0, -radius), 1.5, dot);
    canvas.drawCircle(center + Offset(0, radius), 1.5, dot);
  }

  @override
  bool shouldRepaint(_PreviewOrbit oldDelegate) => oldDelegate.accent != accent;
}
