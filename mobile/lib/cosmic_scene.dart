import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'cosmic_theme.dart';

const cosmicBackgrounds = ['stars', 'galaxy', 'nebula', 'blackHole'];
const cosmicAnswerStyles = ['coin', 'sphere', 'blackHole', 'constellation'];

/// A bounded, decorative background. Its foreground child remains interactive.
/// The 60 deterministic points and gradient layers do not consume answer RNG.
class CosmicScene extends StatelessWidget {
  final String background;
  final bool active, animate;
  final Widget child;
  const CosmicScene({
    super.key,
    required this.background,
    required this.child,
    this.active = true,
    this.animate = true,
  });

  @override
  Widget build(BuildContext context) => _CosmicMotion(
    active: active,
    animate: animate,
    period: const Duration(seconds: 96),
    painter: (phase) => CosmicScenePainter(
      background: cosmicBackgrounds.contains(background) ? background : 'stars',
      phase: phase,
    ),
    child: child,
  );
}

/// A decorative style sample. It has no answer, tap action or random draw.
class AnswerStylePreview extends StatelessWidget {
  final String style;
  final bool active, animate;
  final double size;
  final String? semanticLabel;
  const AnswerStylePreview({
    super.key,
    required this.style,
    this.active = true,
    this.animate = true,
    this.size = 176,
    this.semanticLabel,
  }) : assert(size > 0);

  @override
  Widget build(BuildContext context) {
    final selected = cosmicAnswerStyles.contains(style) ? style : 'coin';
    final ru = Localizations.maybeLocaleOf(context)?.languageCode == 'ru';
    final name = switch (selected) {
      'sphere' => ru ? 'сфера' : 'sphere',
      'blackHole' => ru ? 'чёрная дыра' : 'black hole',
      'constellation' => ru ? 'созвездие' : 'constellation',
      _ => ru ? 'монета' : 'coin',
    };
    return Semantics(
      image: true,
      label:
          semanticLabel ??
          (ru
              ? 'Предпросмотр: $name. Ответ не выбирается.'
              : 'Style preview: $name. No answer is selected.'),
      child: ExcludeSemantics(
        child: SizedBox.square(
          dimension: size,
          child: _CosmicMotion(
            active: active,
            animate: animate,
            period: const Duration(seconds: 18),
            painter: (phase) =>
                AnswerStylePainter(style: selected, phase: phase),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

class _CosmicMotion extends StatefulWidget {
  final bool active, animate;
  final Duration period;
  final CustomPainter Function(double phase) painter;
  final Widget child;
  const _CosmicMotion({
    required this.active,
    required this.animate,
    required this.period,
    required this.painter,
    required this.child,
  });

  @override
  State<_CosmicMotion> createState() => _CosmicMotionState();
}

class _CosmicMotionState extends State<_CosmicMotion>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: widget.period,
  );
  bool _foreground = true, _moving = false;

  @override
  void initState() {
    super.initState();
    final binding = WidgetsBinding.instance;
    _foreground =
        binding.lifecycleState == null ||
        binding.lifecycleState == AppLifecycleState.resumed;
    binding.addObserver(this);
  }

  void _syncMotion() {
    _moving =
        widget.active &&
        widget.animate &&
        _foreground &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context) &&
        !MediaQuery.accessibleNavigationOf(context);
    if (_moving && !_clock.isAnimating) {
      _clock.repeat();
    } else if (!_moving) {
      _clock.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(_CosmicMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.period != widget.period) _clock.duration = widget.period;
    _syncMotion();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncMotion();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _clock,
    child: widget.child,
    builder: (context, child) => Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: ClipRect(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: widget.painter(_clock.value),
                    isComplex: true,
                    willChange: _moving,
                  ),
                ),
              ),
            ),
          ),
        ),
        child!,
      ],
    ),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock.dispose();
    super.dispose();
  }
}

class _Point {
  final double x, y, radius, alpha;
  final int layer;
  const _Point(this.x, this.y, this.radius, this.alpha, this.layer);
}

// A fixed procedural distribution, independent of every question and answer.
double _fraction(int seed) {
  final value = math.sin(seed * 127.1 + 311.7) * 43758.5453123;
  return value - value.floorToDouble();
}

final _points = List<_Point>.generate(
  60,
  (index) => _Point(
    _fraction(index * 7 + 1),
    _fraction(index * 7 + 2),
    index < 48
        ? 0.45 + _fraction(index * 7 + 3) * 0.85
        : 2 + _fraction(index * 7 + 3) * 8,
    index < 48
        ? 0.16 + _fraction(index * 7 + 4) * 0.46
        : 0.014 + _fraction(index * 7 + 4) * 0.025,
    index % 3,
  ),
  growable: false,
);

void _glow(
  Canvas canvas,
  Offset center,
  double radius,
  List<Color> colors, {
  List<double>? stops,
}) {
  if (radius <= 0) return;
  canvas.drawCircle(
    center,
    radius,
    Paint()
      ..shader = RadialGradient(
        colors: colors,
        stops: stops,
      ).createShader(Rect.fromCircle(center: center, radius: radius)),
  );
}

Color _silver(double alpha) => CosmicPalette.silver.withValues(alpha: alpha);
Color _white(double alpha) => CosmicPalette.white.withValues(alpha: alpha);
Color _violet(double alpha) => CosmicPalette.violet.withValues(alpha: alpha);
const _clear = Color(0x00050507);

class CosmicScenePainter extends CustomPainter {
  final String background;
  final double phase;
  const CosmicScenePainter({required this.background, required this.phase});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final angle = phase * math.pi * 2;
    final shortest = size.shortestSide;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [CosmicPalette.night, CosmicPalette.deep, CosmicPalette.deep],
          stops: [0, 0.65, 1],
        ).createShader(rect),
    );

    switch (background) {
      case 'galaxy':
        _galaxy(canvas, size, angle);
      case 'nebula':
        _glow(
          canvas,
          Offset(
            size.width * (0.13 + 0.035 * math.sin(angle)),
            size.height * 0.26,
          ),
          shortest * 0.95,
          [_violet(0.88), _violet(0.32), _clear],
          stops: [0, 0.43, 1],
        );
        _glow(
          canvas,
          Offset(
            size.width * 0.9,
            size.height * (0.61 + 0.025 * math.cos(angle)),
          ),
          shortest * 0.8,
          [_silver(0.09), _violet(0.45), _clear],
          stops: [0, 0.35, 1],
        );
        _glow(
          canvas,
          Offset(size.width * 0.34, size.height * 0.47),
          shortest * 0.43,
          [CosmicPalette.deep.withValues(alpha: 0.82), _clear],
        );
      case 'blackHole':
        _glow(
          canvas,
          Offset(size.width * 0.72, size.height * 0.28),
          shortest * 0.65,
          [_violet(0.48), _violet(0.1), _clear],
        );
      default:
        _glow(
          canvas,
          Offset(size.width * 0.9, size.height * 0.12),
          shortest * 0.85,
          [_violet(0.36), _clear],
        );
    }

    for (var i = 0; i < _points.length; i++) {
      final point = _points[i];
      final x =
          point.x + math.sin(angle + i * 0.43) * 0.006 * (point.layer + 1);
      final y =
          point.y + math.cos(angle * (point.layer + 1) + i * 0.31) * 0.004;
      final center = Offset(x * size.width, y * size.height);
      final alpha = point.alpha * (0.85 + 0.15 * math.sin(angle * 2 + i));
      canvas.drawCircle(center, point.radius, Paint()..color = _silver(alpha));
      if (i < 48 && i % 17 == 0) {
        _glow(canvas, center, 6, [_white(alpha * 0.3), _clear]);
        canvas.drawLine(
          center - const Offset(3.6, 0),
          center + const Offset(3.6, 0),
          Paint()
            ..color = _white(alpha * 0.6)
            ..strokeWidth = 0.4,
        );
      }
    }
    if (background == 'blackHole') {
      _blackHole(
        canvas,
        Offset(size.width * 0.72, size.height * 0.28),
        shortest * 0.15,
        angle,
        subtle: true,
      );
    }
    // Keep the lower reading area quiet without hiding the independent layers.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_clear, CosmicPalette.deep.withValues(alpha: 0.5)],
        ).createShader(rect),
    );
  }

  void _galaxy(Canvas canvas, Size size, double angle) {
    final center = Offset(size.width * 0.68, size.height * 0.28);
    final radius = size.shortestSide * 0.7;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-0.58 + 0.025 * math.sin(angle));
    canvas.scale(1, 0.32);
    _glow(
      canvas,
      Offset.zero,
      radius,
      [_white(0.25), _silver(0.1), _violet(0.5), _clear],
      stops: [0, 0.14, 0.48, 1],
    );
    for (var arm = 0; arm < 3; arm++) {
      final path = Path();
      for (var step = 0; step <= 36; step++) {
        final fraction = step / 36;
        final a = fraction * math.pi * 1.7 + arm * math.pi * 2 / 3;
        final distance = radius * (0.07 + fraction * 0.8);
        final point = Offset(math.cos(a) * distance, math.sin(a) * distance);
        if (step == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = _silver(0.08)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }
    canvas.restore();
    _glow(canvas, center, radius * 0.13, [_white(0.1), _clear]);
  }

  @override
  bool shouldRepaint(CosmicScenePainter oldDelegate) =>
      background != oldDelegate.background || phase != oldDelegate.phase;
}

void _blackHole(
  Canvas canvas,
  Offset center,
  double radius,
  double angle, {
  bool subtle = false,
}) {
  final strength = subtle ? 0.66 : 1.0;
  _glow(canvas, center, radius * 2.2, [
    _violet(0.5 * strength),
    _silver(0.05 * strength),
    _clear,
  ]);
  canvas.save();
  canvas.translate(center.dx, center.dy);
  canvas.rotate(-0.35 + 0.035 * math.sin(angle));
  final disc = Rect.fromCenter(
    center: Offset.zero,
    width: radius * 4.0,
    height: radius * 1.18,
  );
  canvas.drawOval(
    disc,
    Paint()
      ..color = _silver(0.27 * strength)
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius * 0.055,
  );
  canvas.drawOval(
    disc.inflate(radius * 0.12),
    Paint()
      ..color = _violet(0.75 * strength)
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius * 0.07,
  );
  canvas.drawCircle(Offset.zero, radius, Paint()..color = CosmicPalette.deep);
  canvas.drawCircle(
    Offset.zero,
    radius * 1.02,
    Paint()
      ..color = _silver(0.62 * strength)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.6, radius * 0.022),
  );
  canvas.drawArc(
    Rect.fromCircle(center: Offset.zero, radius: radius * 1.04),
    math.pi * 1.02,
    math.pi * 0.72,
    false,
    Paint()
      ..color = _white(0.83 * strength)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = radius * 0.035,
  );
  canvas.drawArc(
    disc,
    0,
    math.pi,
    false,
    Paint()
      ..color = _silver(0.56 * strength)
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius * 0.055,
  );
  canvas.restore();
}

class AnswerStylePainter extends CustomPainter {
  final String style;
  final double phase;
  const AnswerStylePainter({required this.style, required this.phase});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final center = size.center(Offset.zero), radius = size.shortestSide * 0.29;
    final angle = phase * math.pi * 2;
    _glow(canvas, center, radius * 1.65, [_violet(0.5), _clear]);
    switch (style) {
      case 'sphere':
        _sphere(canvas, center, radius, angle);
      case 'blackHole':
        _blackHole(canvas, center, radius * 0.82, angle);
      case 'constellation':
        _constellation(canvas, center, radius, angle);
      default:
        _coin(canvas, center, radius, angle);
    }
  }

  void _coin(Canvas canvas, Offset center, double radius, double angle) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-0.16 + math.sin(angle) * 0.05);
    canvas.scale(0.87 + math.cos(angle) * 0.08, 1);
    final disc = Rect.fromCircle(center: Offset.zero, radius: radius);
    canvas.drawCircle(
      Offset.zero,
      radius,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_silver(0.36), CosmicPalette.night, _silver(0.13)],
          stops: const [0, 0.55, 1],
        ).createShader(disc),
    );
    canvas.drawCircle(
      Offset.zero,
      radius,
      Paint()
        ..color = _silver(0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3,
    );
    canvas.drawCircle(
      Offset.zero,
      radius * 0.85,
      Paint()
        ..color = _silver(0.22)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7,
    );
    final emblem = Path();
    for (var i = 0; i < 8; i++) {
      final a = -math.pi / 2 + i * math.pi / 4;
      final length = radius * (i.isEven ? 0.39 : 0.115);
      final point = Offset(math.cos(a) * length, math.sin(a) * length);
      if (i == 0) {
        emblem.moveTo(point.dx, point.dy);
      } else {
        emblem.lineTo(point.dx, point.dy);
      }
    }
    emblem.close();
    canvas.drawPath(emblem, Paint()..color = _silver(0.62));
    canvas.restore();
  }

  void _sphere(Canvas canvas, Offset center, double radius, double angle) {
    _glow(
      canvas,
      center,
      radius,
      [_silver(0.05), _violet(0.16), _silver(0.32), _clear],
      stops: [0, 0.7, 0.96, 1],
    );
    canvas.drawCircle(
      center,
      radius * 0.97,
      Paint()
        ..color = _silver(0.62)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7,
    );
    _glow(
      canvas,
      center + Offset(-radius * 0.32, -radius * 0.39),
      radius * 0.27,
      [_white(0.26), _clear],
    );
    final ellipse = Rect.fromCenter(
      center: center,
      width: radius * 1.6,
      height: radius * 0.58,
    );
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-0.6 + 0.05 * math.sin(angle));
    canvas.translate(-center.dx, -center.dy);
    canvas.drawArc(
      ellipse,
      math.pi * 1.15,
      math.pi * 0.7,
      false,
      Paint()
        ..color = _white(0.62)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.7
        ..strokeCap = StrokeCap.round,
    );
    canvas.restore();
    for (var i = 0; i < 3; i++) {
      final a = angle + i * 2.1;
      canvas.drawCircle(
        center +
            Offset(math.cos(a) * radius * 0.32, math.sin(a) * radius * 0.2),
        0.75,
        Paint()..color = _silver(0.52),
      );
    }
  }

  void _constellation(
    Canvas canvas,
    Offset center,
    double radius,
    double angle,
  ) {
    const positions = [
      Offset(-0.82, 0.45),
      Offset(-0.5, -0.15),
      Offset(-0.1, 0.12),
      Offset(0.13, -0.7),
      Offset(0.58, -0.36),
      Offset(0.9, 0.3),
    ];
    final points = positions
        .map(
          (point) =>
              center +
              Offset(
                point.dx * radius * 1.1,
                (point.dy + math.sin(angle) * 0.025) * radius * 1.1,
              ),
        )
        .toList(growable: false);
    final line = Paint()
      ..color = _silver(0.36)
      ..strokeWidth = 0.8;
    for (var i = 0; i < points.length - 1; i++) {
      canvas.drawLine(points[i], points[i + 1], line);
    }
    canvas.drawLine(
      points[2],
      points[4],
      Paint()
        ..color = _silver(0.12)
        ..strokeWidth = 0.6,
    );
    for (var i = 0; i < points.length; i++) {
      _glow(canvas, points[i], i == 3 ? 11 : 7, [_white(0.23), _clear]);
      canvas.drawCircle(
        points[i],
        i == 3 ? 2.1 : 1.35,
        Paint()..color = _white(0.88),
      );
    }
  }

  @override
  bool shouldRepaint(AnswerStylePainter oldDelegate) =>
      style != oldDelegate.style || phase != oldDelegate.phase;
}
