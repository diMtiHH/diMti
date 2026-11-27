import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// The cover waits for actual session/model and shader readiness. Animation is
/// decorative and never pretends that elapsed time proves successful loading.
class UniverseStartup extends StatefulWidget {
  final String language, name;
  final bool ready;
  final VoidCallback onComplete;
  const UniverseStartup({
    super.key,
    required this.language,
    required this.name,
    required this.ready,
    required this.onComplete,
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
    final greeting = widget.name.isEmpty
        ? (ru ? 'Привет' : 'Hello')
        : '${ru ? 'Привет' : 'Hello'}, ${widget.name}';
    return ColoredBox(
      color: const Color(0xff050a12),
      child: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(painter: _CreationLight(_light)),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
                      style: Theme.of(context).textTheme.headlineMedium,
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
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
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
  _CreationLight(this.time) : super(repaint: time);
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * .38);
    final paint = Paint();
    for (var i = 0; i < 36; i++) {
      final phase = i * 2.39996;
      final radius =
          (20 + math.sqrt(i) * size.shortestSide * .035) *
          (1 + .07 * math.sin(time.value * math.pi * 2 + i));
      final point = center + Offset(math.cos(phase), math.sin(phase)) * radius;
      paint.color = const Color(0xff8ed8ce)
          .withValues(alpha: .15 + .5 * (i % 5) / 5);
      canvas.drawCircle(point, i % 7 == 0 ? 1.8 : .8, paint);
    }
  }

  @override
  bool shouldRepaint(_CreationLight oldDelegate) => oldDelegate.time != time;
}
