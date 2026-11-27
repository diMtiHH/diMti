import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'aura_renderer.dart';
import 'aura_ui.dart';
import 'presentation_profile.dart';
import 'session_core.dart';

/// Foreground-only view of an already selected answer. This route never reads
/// a question from disk, chooses an answer, or owns the cooldown deadline.
class AuraAnswerPage extends StatefulWidget {
  final Answer answer;
  final String question, language;
  final PresentationProfile profile;
  final QuestionSession session;
  final AuraInteractionController interaction;
  final Future<void> Function() onVisible;
  const AuraAnswerPage({
    super.key,
    required this.answer,
    required this.question,
    required this.language,
    required this.profile,
    required this.session,
    required this.interaction,
    required this.onVisible,
  });
  @override
  State<AuraAnswerPage> createState() => _AuraAnswerPageState();
}

class _AuraAnswerPageState extends State<AuraAnswerPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _fade;
  Timer? _timer;
  bool _foreground = true, _queued = false, _shown = false, _started = false;
  String t(String ru, String en) => widget.language == 'ru' ? ru : en;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    )..addListener(_visibleFrame);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _foreground) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _fade.value = 1;
    } else {
      _fade.forward();
    }
  }

  void _visibleFrame() {
    // No acknowledgement for the initial fully transparent frame. The callback
    // runs after a frame with visible text, and the owner rechecks its generation.
    if (_fade.value <= .04 || _queued || _shown || !_foreground) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _queued = false;
      if (!mounted ||
          !_foreground ||
          _shown ||
          !ModalRoute.of(context)!.isCurrent)
        return;
      _shown = true;
      await widget.onVisible();
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed || !_foreground) return;
    setState(() => _foreground = false);
    _fade.stop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ModalRoute.of(context)!.isCurrent)
        Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final seconds = session.remainingSeconds;
    final time =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    final answer = widget.answer == Answer.yes
        ? t('Да', 'Yes')
        : t('Нет', 'No');
    final ringSize = math.min(
      112.0 * (MediaQuery.textScalerOf(context).scale(24) / 24).clamp(1, 2),
      MediaQuery.sizeOf(context).width - 56,
    );
    return AuraScene(
      background: widget.profile.background.name,
      showForm: false,
      interaction: widget.interaction,
      phase: AuraPhase.answerReveal,
      active: _foreground,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: !_foreground
              ? const SizedBox.shrink()
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Row(
                        children: [
                          const SizedBox(width: 48),
                          Expanded(
                            child: Text(
                              t('Ответ Вселенной', 'Answer from the Universe'),
                              key: const ValueKey('answer-heading'),
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                          IconButton(
                            key: const ValueKey('close-answer'),
                            tooltip: t('Закрыть', 'Close'),
                            icon: const AuraIcon(kind: AuraIconKind.close),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 480),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AnimatedBuilder(
                                  animation: _fade,
                                  builder: (context, _) {
                                    final visible = Curves.easeOut.transform(
                                      _fade.value,
                                    );
                                    final blur = 2.2 * (1 - visible);
                                    return Opacity(
                                      opacity: visible,
                                      child: ImageFiltered(
                                        imageFilter: ui.ImageFilter.blur(
                                          sigmaX: blur,
                                          sigmaY: blur,
                                        ),
                                        child: SizedBox(
                                          width: double.infinity,
                                          child: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            child: Text(
                                              answer,
                                              key: const ValueKey('answer'),
                                              semanticsLabel: t(
                                                'Ответ: $answer',
                                                'Answer: $answer',
                                              ),
                                              style: TextStyle(
                                                fontFamily:
                                                    'Cormorant Garamond',
                                                fontWeight: FontWeight.w300,
                                                fontSize: 86,
                                                letterSpacing:
                                                    0.3 + 1.2 * (1 - visible),
                                                color: const Color(0xfff2f5fb),
                                                shadows: [
                                                  Shadow(
                                                    color: auraAccent(
                                                      widget
                                                          .profile
                                                          .background
                                                          .name,
                                                    ).withValues(alpha: .3),
                                                    blurRadius: 32,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                                const SizedBox(height: 38),
                                if (widget.question.isNotEmpty) ...[
                                  Text(
                                    widget.question,
                                    key: const ValueKey('answer-question'),
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyLarge,
                                  ),
                                  const SizedBox(height: 30),
                                ],
                                if (session.phase == SessionPhase.cooldown) ...[
                                  TweenAnimationBuilder<double>(
                                    key: const ValueKey('answer-ring'),
                                    tween: Tween<double>(
                                      begin:
                                          session.remainingMs /
                                          session.currentPauseDurationMs,
                                      end:
                                          session.remainingMs /
                                          session.currentPauseDurationMs,
                                    ),
                                    duration:
                                        MediaQuery.disableAnimationsOf(
                                              context,
                                            ) ||
                                            MediaQuery.accessibleNavigationOf(
                                              context,
                                            )
                                        ? Duration.zero
                                        : const Duration(milliseconds: 900),
                                    curve: Curves.linear,
                                    builder: (context, fraction, child) =>
                                        CustomPaint(
                                          key: const ValueKey(
                                            'answer-ring-paint',
                                          ),
                                          painter: _PauseRing(
                                            fraction,
                                            auraAccent(
                                              widget.profile.background.name,
                                            ),
                                          ),
                                          child: child,
                                        ),
                                    child: SizedBox(
                                      width: ringSize,
                                      height: ringSize,
                                      child: Center(
                                        child: Text(
                                          time,
                                          key: const ValueKey(
                                            'answer-countdown',
                                          ),
                                          semanticsLabel: t(
                                            'Осталось $time',
                                            '$time remaining',
                                          ),
                                          style: Theme.of(context)
                                              .textTheme
                                              .headlineSmall,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 20),
                                  Text(
                                    t(
                                      'До следующего вопроса',
                                      'Until your next question',
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                                const SizedBox(height: 28),
                                TextButton(
                                  onPressed: () => Navigator.of(context).pop(),
                                  child: Text(
                                    t(
                                      'Вернуться во Вселенную',
                                      'Return to the Universe',
                                    ),
                                  ),
                                ),
                              ],
                            ),
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _fade.dispose();
    super.dispose();
  }
}

class _PauseRing extends CustomPainter {
  final double fraction;
  final Color color;
  _PauseRing(this.fraction, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final bounds = (Offset.zero & size).deflate(2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawOval(bounds, paint..color = color.withValues(alpha: .15));
    canvas.drawArc(
      bounds,
      -math.pi / 2,
      2 * math.pi * fraction.clamp(0, 1),
      false,
      paint
        ..color = color.withValues(alpha: .8)
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_PauseRing old) =>
      old.fraction != fraction || old.color != color;
}

class AuraVisualState {
  final AuraPhase phase;
  final double progress, energy;
  const AuraVisualState({
    this.phase = AuraPhase.idle,
    this.progress = 0,
    this.energy = 0,
  });
}
