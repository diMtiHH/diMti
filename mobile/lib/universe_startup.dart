import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// The cover waits for actual session/model and shader readiness. Animation is
/// decorative and never pretends that elapsed time proves successful loading.
class UniverseStartup extends StatefulWidget {
  final String language, name;
  final bool ready;
  final Color accent;
  final VoidCallback onComplete;
  const UniverseStartup({
    super.key,
    required this.language,
    required this.name,
    required this.ready,
    required this.onComplete,
    this.accent = const Color(0xff71dcc5),
  });
  @override
  State<UniverseStartup> createState() => _UniverseStartupState();
}

class _UniverseStartupState extends State<UniverseStartup>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _light = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  );
  Timer? _welcomeTimer, _finishTimer;
  bool _welcome = false, _sent = false, _reduced = false, _active = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _active =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _welcomeTimer = Timer(const Duration(milliseconds: 650), () {
      if (!mounted) return;
      setState(() => _welcome = true);
      _finish();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    if (_reduced) {
      _welcomeTimer?.cancel();
      _welcome = true;
    }
    _animate();
    _finish();
  }

  void _animate() {
    if (_active && !_reduced && TickerMode.valuesOf(context).enabled) {
      if (!_light.isAnimating) _light.repeat();
    } else {
      _light.stop();
    }
  }

  void _finish() {
    if (!widget.ready || !_welcome || !_active || _sent || _finishTimer != null)
      return;
    _finishTimer = Timer(
      _reduced ? Duration.zero : const Duration(milliseconds: 700),
      () {
        _finishTimer = null;
        if (!mounted || !widget.ready || !_active || _sent) return;
        _sent = true;
        widget.onComplete();
      },
    );
  }

  @override
  void didUpdateWidget(UniverseStartup oldWidget) {
    super.didUpdateWidget(oldWidget);
    _finish();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (!_active) {
      _finishTimer?.cancel();
      _finishTimer = null;
    }
    _animate();
    _finish();
  }

  @override
  Widget build(BuildContext context) {
    final ru = widget.language == 'ru';
    final compact =
        MediaQuery.sizeOf(context).height < 650 ||
        MediaQuery.textScalerOf(context).scale(16) > 22;
    final greeting = widget.name.isEmpty
        ? (ru ? 'Привет' : 'Hello')
        : '${ru ? 'Привет' : 'Hello'}, ${widget.name}';
    return ColoredBox(
      key: const ValueKey('startup-full-bleed'),
      color: const Color(0xff050a12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(painter: _StartupSky(widget.accent)),
            ),
          ),
          Align(
            alignment: Alignment(0, compact ? -.45 : -.24),
            child: RepaintBoundary(
              child: SizedBox.square(
                dimension: compact ? 126 : 192,
                child: CustomPaint(
                  painter: _CreationLight(_light, widget.accent),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: const Alignment(0, .35),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 30),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      ru ? 'ТВОЯ ВСЕЛЕННАЯ' : 'YOUR UNIVERSE',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: widget.accent.withValues(alpha: .8),
                        fontSize: 10,
                        letterSpacing: 3,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _welcome
                          ? greeting
                          : (ru
                                ? 'Создаём твою Вселенную'
                                : 'Creating your Universe'),
                      key: const ValueKey('startup-title'),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.headlineLarge
                          ?.copyWith(fontWeight: FontWeight.w300),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      _welcome
                          ? (ru
                                ? 'Мгновение тишины…'
                                : 'A moment of stillness…')
                          : (ru
                                ? 'Всё начинается с искры'
                                : 'It begins with a spark'),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: const Color(0xff949eac)),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: 40,
                      height: 1,
                      child: ColoredBox(
                        color: widget.accent.withValues(alpha: .45),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _welcomeTimer?.cancel();
    _finishTimer?.cancel();
    _light.dispose();
    super.dispose();
  }
}

class _CreationLight extends CustomPainter {
  final Animation<double> time;
  final Color accent;
  _CreationLight(this.time, this.accent) : super(repaint: time);
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .65;
    final t = time.value * math.pi * 2;
    for (var strand = 0; strand < 16; strand++) {
      final path = Path();
      for (var i = 0; i <= 60; i++) {
        final a = i / 60 * math.pi * 2;
        final r = 52 + strand * .9 + 5 * math.sin(a * 3 + t + strand * .26);
        final p = center + Offset(math.cos(a) * r, math.sin(a) * r * .63);
        final angle = strand * .135 + .12 * math.sin(t);
        final relative = p - center;
        final q =
            center +
            Offset(
              relative.dx * math.cos(angle) - relative.dy * math.sin(angle),
              relative.dx * math.sin(angle) + relative.dy * math.cos(angle),
            );
        if (i == 0) {
          path.moveTo(q.dx, q.dy);
        } else {
          path.lineTo(q.dx, q.dy);
        }
      }
      paint.color = accent.withValues(alpha: .12 + .14 * (strand % 4) / 3);
      canvas.drawPath(path, paint);
    }
    paint
      ..style = PaintingStyle.fill
      ..color = const Color(0xffe7f2ee);
    canvas.drawCircle(center, 1.4, paint);
    paint
      ..style = PaintingStyle.stroke
      ..color = accent.withValues(alpha: .5);
    canvas.drawLine(
      center - const Offset(0, 7),
      center + const Offset(0, 7),
      paint,
    );
    canvas.drawLine(
      center - const Offset(7, 0),
      center + const Offset(7, 0),
      paint,
    );
  }

  @override
  bool shouldRepaint(_CreationLight oldDelegate) =>
      oldDelegate.time != time || oldDelegate.accent != accent;
}

class _StartupSky extends CustomPainter {
  final Color accent;
  const _StartupSky(this.accent);
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final center = Offset(size.width * .5, size.height * .39);
    canvas.drawRect(
      rect,
      Paint()
        ..shader =
            RadialGradient(
              colors: [accent.withValues(alpha: .07), const Color(0x00050a12)],
            ).createShader(
              Rect.fromCircle(center: center, radius: size.width * .8),
            ),
    );
    final paint = Paint();
    for (var i = 0; i < 44; i++) {
      final x = ((i * 73.37) % 100) / 100 * size.width;
      final y = ((i * 31.61 + 7) % 100) / 100 * size.height;
      paint.color = accent.withValues(alpha: .10 + (i % 4) * .045);
      canvas.drawCircle(Offset(x, y), i % 9 == 0 ? .9 : .45, paint);
    }
  }

  @override
  bool shouldRepaint(_StartupSky old) => old.accent != accent;
}
