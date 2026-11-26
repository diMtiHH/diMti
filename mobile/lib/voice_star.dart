import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Procedural light: audio controls the glow; it never chooses an answer.
class VoiceStar extends StatefulWidget {
  final double level;
  final bool listening, active, enabled;
  final String label;
  final VoidCallback? onPressed;
  const VoiceStar({
    super.key,
    this.level = 0,
    this.listening = false,
    this.active = true,
    this.enabled = true,
    required this.label,
    this.onPressed,
  });

  @override
  State<VoiceStar> createState() => _VoiceStarState();
}

class _VoiceStarState extends State<VoiceStar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  );
  bool _motion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(VoiceStar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMotion();
  }

  void _syncMotion() {
    _motion =
        widget.active &&
        widget.enabled &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context) &&
        !MediaQuery.accessibleNavigationOf(context);
    if (_motion && !_breath.isAnimating) {
      _breath.repeat();
    } else if (!_motion) {
      _breath.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final level = widget.level.isFinite
        ? widget.level.clamp(0.0, 1.0).toDouble()
        : 0.0;
    return Center(
      child: Semantics(
        label: widget.label,
        button: true,
        enabled: widget.enabled,
        onTap: widget.enabled ? widget.onPressed : null,
        child: ExcludeSemantics(
          child: SizedBox.square(
            dimension: 176,
            child: TextButton(
              key: const ValueKey('voice-star'),
              onPressed: widget.enabled ? widget.onPressed : null,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                shape: const CircleBorder(),
              ),
              child: ExcludeSemantics(
                child: RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: _breath,
                    builder: (context, _) => CustomPaint(
                      size: const Size.square(176),
                      painter: VoiceStarPainter(
                        // Reduced motion keeps a steady shape; real audio still
                        // controls a restrained brightness change.
                        energy: widget.listening ? level : 0,
                        breath: _motion
                            ? (1 - math.cos(_breath.value * math.pi * 2)) / 2
                            : 0.5,
                        motion: _motion,
                        enabled: widget.enabled,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }
}

class VoiceStarPainter extends CustomPainter {
  final double energy, breath;
  final bool motion, enabled;
  const VoiceStarPainter({
    required this.energy,
    required this.breath,
    required this.motion,
    required this.enabled,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius =
        size.shortestSide *
        (0.31 + (motion ? breath * 0.015 + energy * 0.065 : 0));
    final strength = enabled ? 0.52 + energy * 0.24 : 0.18;
    final halo = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xffb9d7ff).withValues(alpha: strength),
          const Color(0xff668ed2).withValues(alpha: strength * 0.45),
          const Color(0xff6c4e9b).withValues(alpha: strength * 0.16),
          const Color(0xff050507).withValues(alpha: 0),
        ],
        stops: const [0, 0.22, 0.53, 1],
      ).createShader(Rect.fromCircle(center: center, radius: radius * 1.48));
    canvas.drawCircle(center, radius * 1.48, halo);
    for (var i = 0; i < 18; i++) {
      final angle = i * math.pi * 2 / 18 + i * 0.19;
      final distance = radius * (0.72 + (i % 5) * 0.12);
      final point =
          center + Offset(math.cos(angle), math.sin(angle)) * distance;
      canvas.drawCircle(
        point,
        i % 3 == 0 ? 1.1 : 0.65,
        Paint()
          ..color = const Color(0xffc5cad3).withValues(alpha: strength * 0.7),
      );
    }
    final coreRadius = radius * (0.19 + (motion ? energy * 0.035 : 0));
    canvas.drawCircle(
      center,
      coreRadius * 2.7,
      Paint()
        ..shader =
            RadialGradient(
              colors: [
                const Color(0xfff2f3f5)
                    .withValues(alpha: enabled ? 0.95 : 0.35),
                const Color(0xffb9d7ff).withValues(alpha: strength * 0.8),
                const Color(0xff86a7df).withValues(alpha: 0),
              ],
              stops: const [0, 0.28, 1],
            ).createShader(
              Rect.fromCircle(center: center, radius: coreRadius * 2.7),
            ),
    );
  }

  @override
  bool shouldRepaint(VoiceStarPainter oldDelegate) =>
      energy != oldDelegate.energy ||
      breath != oldDelegate.breath ||
      motion != oldDelegate.motion ||
      enabled != oldDelegate.enabled;
}
