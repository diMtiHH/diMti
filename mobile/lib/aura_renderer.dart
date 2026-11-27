import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'aura_power_budget.dart';

/// Pure presentation phases. The caller, never the renderer, authorizes an
/// answer animation/reveal and supplies its progress after the closed gate.
enum AuraPhase {
  idle,
  touchDown,
  holding,
  dragging,
  touchRelease,
  questionInput,
  questionConfirmation,
  safetyValidation,
  answerAnimation,
  answerReveal,
  cooldown,
}

const auraEnvironments = ['stars', 'galaxy', 'aurora', 'gravity'];
const auraForms = ['livingMatter', 'liquidMetal', 'infinity', 'constellation'];

Color auraAccent(String environment) => switch (environment) {
  'stars' => const Color(0xffbad2f8),
  'galaxy' => const Color(0xff96aaf9),
  'gravity' => const Color(0xffedb584),
  _ => const Color(0xff71dcc5),
};

double _unit(double value) => value.isFinite ? value.clamp(0.0, 1.0) : 0;
double _hash(double value) =>
    (math.sin(value * 127.13 + 17.7) * 43758.5453) % 1;
double _mix(double a, double b, double t) => a + (b - a) * t;

/// Shared visual memory survives route/widget rebuilds. It contains no question,
/// answer, random source, persistence, permissions or business callback.
class AuraInteractionController extends ChangeNotifier {
  Offset _point = Offset.zero;
  bool _pressed = false;
  double _pressure = 0, _hold = 0, _release = 0, _pulse = 0;
  double _elapsed = 0, _quality = 1;
  Duration? _frame;
  bool _disposed = false;

  Offset get point => _point;
  bool get pressed => _pressed;
  double get pressure => _pressure;
  double get hold => _hold;
  double get release => _release;
  double get inputPulse => _pulse;
  double get elapsed => _elapsed;
  double get quality => _quality;

  void pulse([double strength = 1]) {
    if (_disposed) return;
    _pulse = math.max(_pulse, _unit(strength));
    notifyListeners();
  }

  void _down(Offset value) {
    if (_disposed) return;
    _point = value;
    _pressed = true;
    _hold = 0;
    _pressure = math.max(_pressure, 0.22);
    _release = 0;
    notifyListeners();
  }

  void _move(Offset value) {
    if (_disposed || !_pressed) return;
    _point = value;
    notifyListeners();
  }

  void _holding() {
    if (_disposed || !_pressed) return;
    _hold = math.max(_hold, 0.22);
    notifyListeners();
  }

  void _up() {
    if (_disposed) return;
    _pressed = false;
    _release = 1;
    notifyListeners();
  }

  void cancel() {
    if (_disposed) return;
    _pressed = false;
    _pressure = _hold = _release = _pulse = 0;
    notifyListeners();
  }

  // Multiple active layers share the scheduler timestamp: advancing a local
  // object and a full-screen background in one frame never doubles their time.
  void _advance(Duration frame) {
    if (_disposed || frame == _frame) return;
    final dt = _frame == null
        ? 1 / 60
        : ((frame - _frame!).inMicroseconds / 1000000).clamp(0.0, 0.05);
    _frame = frame;
    _elapsed += dt;
    _pressure = _mix(
      _pressure,
      _pressed ? 1 : 0,
      1 - math.exp(-dt * (_pressed ? 12 : 5)),
    );
    _hold = _pressed
        ? math.min(1, _hold + dt * 0.35)
        : _hold * math.exp(-dt * 3.5);
    _release *= math.exp(-dt * 2.2);
    _pulse *= math.exp(-dt * 3.8);
  }

  void _budget(List<FrameTiming> samples) {
    if (samples.isEmpty || _disposed) return;
    final costs =
        samples
            .map(
              (value) => math.max(
                value.rasterDuration.inMicroseconds,
                value.buildDuration.inMicroseconds,
              ),
            )
            .toList()
          ..sort();
    final cost = costs[(costs.length * 0.9).floor().clamp(0, costs.length - 1)];
    if (cost > 26000)
      _quality = math.max(0.3, _quality - 0.15);
    else if (cost > 19000)
      _quality = math.max(0.45, _quality - 0.06);
    else if (cost < 13000)
      _quality = math.min(1, _quality + 0.02);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// A transparent hit surface. Touch-down reacts immediately; only a short,
/// stationary release in idle may open input. Holding/dragging never submits.
class AuraTouchSurface extends StatefulWidget {
  final AuraInteractionController interaction;
  final Widget child;
  final String label;
  final VoidCallback? onShortTap, onTouchFeedback;
  final AuraPhase phase;
  final bool active, enabled;
  const AuraTouchSurface({
    super.key,
    required this.interaction,
    required this.child,
    required this.label,
    this.onShortTap,
    this.onTouchFeedback,
    this.phase = AuraPhase.idle,
    this.active = true,
    this.enabled = true,
  });
  @override
  State<AuraTouchSurface> createState() => _AuraTouchSurfaceState();
}

class _AuraTouchSurfaceState extends State<AuraTouchSurface>
    with WidgetsBindingObserver {
  int? _pointer;
  Offset _origin = Offset.zero;
  Timer? _holdTimer;
  bool _held = false, _dragged = false, _foreground = true;
  bool get _enabled => widget.active && widget.enabled && _foreground;
  bool get _canOpen =>
      _enabled && widget.phase == AuraPhase.idle && widget.onShortTap != null;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  Offset _normalize(Offset point, Size size) => Offset(
    (point.dx / math.max(1, size.width) * 2 - 1).clamp(-1, 1),
    (point.dy / math.max(1, size.height) * 2 - 1).clamp(-1, 1),
  );
  void _cancel() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _pointer = null;
    widget.interaction.cancel();
  }

  @override
  void didUpdateWidget(AuraTouchSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.interaction != widget.interaction) {
      oldWidget.interaction.cancel();
    }
    if (!_enabled ||
        oldWidget.phase != widget.phase ||
        oldWidget.interaction != widget.interaction)
      _cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _cancel();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final size = Size(
        bounds.maxWidth.isFinite ? bounds.maxWidth : 320,
        bounds.maxHeight.isFinite ? bounds.maxHeight : 320,
      );
      return Semantics(
        label: widget.label,
        button: _canOpen,
        enabled: _enabled,
        onTap: _canOpen ? widget.onShortTap : null,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            if (!_enabled || _pointer != null) return;
            _pointer = event.pointer;
            _origin = event.localPosition;
            _held = _dragged = false;
            widget.interaction._down(_normalize(event.localPosition, size));
            widget.onTouchFeedback?.call();
            _holdTimer = Timer(const Duration(milliseconds: 320), () {
              if (_pointer != null && _enabled) {
                _held = true;
                widget.interaction._holding();
              }
            });
          },
          onPointerMove: (event) {
            if (_pointer != event.pointer || !_enabled) return;
            if ((event.localPosition - _origin).distance > 12) _dragged = true;
            widget.interaction._move(_normalize(event.localPosition, size));
          },
          onPointerUp: (event) {
            if (_pointer != event.pointer) return;
            _holdTimer?.cancel();
            _holdTimer = null;
            _pointer = null;
            widget.interaction._up();
            if (!_held && !_dragged && _canOpen) widget.onShortTap?.call();
          },
          onPointerCancel: (event) {
            if (_pointer == event.pointer) _cancel();
          },
          child: widget.child,
        ),
      );
    },
  );
  @override
  void dispose() {
    _holdTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (_pointer != null) widget.interaction.cancel();
    super.dispose();
  }
}

class _ShaderLibrary {
  final ui.FragmentProgram environment, matter, metal;
  const _ShaderLibrary(this.environment, this.matter, this.metal);
  static Future<_ShaderLibrary>? _pending;
  static _ShaderLibrary? ready;
  static Future<_ShaderLibrary> load() => _pending ??= _read();
  static Future<_ShaderLibrary> _read() async => ready = _ShaderLibrary(
    await ui.FragmentProgram.fromAsset('shaders/aura_environment.frag'),
    await ui.FragmentProgram.fromAsset('shaders/aura_matter.frag'),
    await ui.FragmentProgram.fromAsset('shaders/aura_metal.frag'),
  );
}

/// Lets automated native/renderer checks require compiled shaders explicitly.
/// A scene itself retains a procedural mesh while its shader assets warm up.
Future<void> warmUpAuraShaders() async {
  await _ShaderLibrary.load();
}

class AuraScene extends StatefulWidget {
  final String background, form;
  final AuraPhase phase;
  final AuraInteractionController? interaction;
  final AuraPowerBudget? powerBudget;
  final double energy, progress, formScale;
  final bool active, showForm, showBackground, preview;
  final Alignment formAlignment;
  final Widget child;
  const AuraScene({
    super.key,
    required this.background,
    this.form = 'livingMatter',
    this.phase = AuraPhase.idle,
    this.interaction,
    this.powerBudget,
    this.energy = 0,
    this.progress = 0,
    this.active = true,
    this.showForm = true,
    this.showBackground = true,
    this.formAlignment = const Alignment(0, -.18),
    this.formScale = 1,
    this.preview = false,
    required this.child,
  });
  @override
  State<AuraScene> createState() => _AuraSceneState();
}

class _PaintSignal extends ChangeNotifier {
  void repaint() => notifyListeners();
}

class _AuraSceneState extends State<AuraScene>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late AuraInteractionController _interaction;
  late AuraPowerBudget _power;
  late final Ticker _ticker = createTicker(_tick);
  final _signal = _PaintSignal();
  ui.FragmentShader? _environment, _matter, _metal;
  bool _foreground = true, _motion = false;
  Duration? _paintedAt;
  @override
  void initState() {
    super.initState();
    _interaction = widget.interaction ?? AuraInteractionController();
    _interaction.addListener(_changed);
    _power = widget.powerBudget ?? AuraPowerBudget.instance;
    _power.addListener(_powerChanged);
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addTimingsCallback(_timings);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _load();
  }

  Future<void> _load() async {
    try {
      final cached = _ShaderLibrary.ready;
      if (cached != null) {
        _environment = cached.environment.fragmentShader();
        _matter = cached.matter.fragmentShader();
        _metal = cached.metal.fragmentShader();
        return;
      }
      final library = await _ShaderLibrary.load();
      if (!mounted) return;
      _environment = library.environment.fragmentShader();
      _matter = library.matter.fragmentShader();
      _metal = library.metal.fragmentShader();
      setState(() {});
    } catch (_) {
      // The bounded procedural geometry still responds to touch. Native tests
      // call warmUpAuraShaders separately, so a missing shader cannot pass CI.
    }
  }

  void _changed() {
    if (mounted && widget.active) _signal.repaint();
  }

  void _powerChanged() {
    if (mounted) setState(() {});
  }

  void _timings(List<FrameTiming> frames) {
    if (_motion && widget.active && widget.showBackground && !widget.preview)
      _interaction._budget(frames);
  }

  void _tick(Duration elapsed) {
    final stamp = SchedulerBinding.instance.currentFrameTimeStamp;
    final interval = Duration(
      microseconds: (1000000 / _power.maxFps - 500).round(),
    );
    if (_paintedAt != null && stamp - _paintedAt! < interval) return;
    _paintedAt = stamp;
    _interaction._advance(stamp);
    _signal.repaint();
  }

  void _sync() {
    _motion =
        widget.active &&
        _foreground &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context) &&
        !MediaQuery.accessibleNavigationOf(context);
    if (_motion && !_ticker.isActive) {
      _paintedAt = null;
      _ticker.start();
    } else if (!_motion && _ticker.isActive)
      _ticker.stop();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(AuraScene oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.powerBudget != widget.powerBudget) {
      _power.removeListener(_powerChanged);
      _power = widget.powerBudget ?? AuraPowerBudget.instance;
      _power.addListener(_powerChanged);
    }
    if (oldWidget.interaction != widget.interaction) {
      _interaction.removeListener(_changed);
      if (oldWidget.interaction == null) _interaction.dispose();
      _interaction = widget.interaction ?? AuraInteractionController();
      _interaction.addListener(_changed);
    }
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _interaction.cancel();
    _sync();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Positioned.fill(
        child: IgnorePointer(
          child: ExcludeSemantics(
            child: RepaintBoundary(
              child: CustomPaint(
                isComplex: true,
                willChange: _motion,
                painter: AuraPainter(
                  background: widget.background,
                  form: widget.form,
                  phase: widget.phase,
                  interaction: _interaction,
                  energy: widget.energy,
                  progress: widget.progress,
                  showBackground: widget.showBackground,
                  showForm: widget.showForm,
                  formAlignment: widget.formAlignment,
                  formScale: widget.formScale,
                  preview: widget.preview,
                  qualityCap: _power.qualityCap,
                  motion: _motion,
                  environmentShader: _environment,
                  matterShader: _matter,
                  metalShader: _metal,
                  repaint: _signal,
                ),
              ),
            ),
          ),
        ),
      ),
      widget.child,
    ],
  );
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    _interaction.removeListener(_changed);
    _power.removeListener(_powerChanged);
    if (widget.interaction == null) _interaction.dispose();
    _ticker.dispose();
    _signal.dispose();
    _environment?.dispose();
    _matter?.dispose();
    _metal?.dispose();
    super.dispose();
  }
}

/// All geometry is deterministic decoration, with no dependency on answer RNG.
class AuraPainter extends CustomPainter {
  final String background, form;
  final AuraPhase phase;
  final AuraInteractionController interaction;
  final double energy, progress, formScale, qualityCap;
  final bool showBackground, showForm, preview, motion;
  final Alignment formAlignment;
  final ui.FragmentShader? environmentShader, matterShader, metalShader;
  AuraPainter({
    required this.background,
    required this.form,
    required this.phase,
    required this.interaction,
    this.energy = 0,
    this.progress = 0,
    this.formScale = 1,
    this.qualityCap = 1,
    this.showBackground = true,
    this.showForm = true,
    this.preview = false,
    this.motion = true,
    this.formAlignment = Alignment.center,
    this.environmentShader,
    this.matterShader,
    this.metalShader,
    super.repaint,
  });

  double get _progress =>
      phase == AuraPhase.answerAnimation ? _unit(progress) : 0;
  double get _energy => _unit(energy + interaction.inputPulse * .22);
  double get _activity => switch (phase) {
    AuraPhase.safetyValidation => .18,
    AuraPhase.questionConfirmation => .10,
    AuraPhase.answerAnimation => 1,
    AuraPhase.answerReveal => .04,
    AuraPhase.cooldown => .02,
    _ => 0,
  };
  double get _time => motion ? interaction.elapsed : 7.3;
  double get _quality => math.min(
    preview ? .30 : interaction.quality,
    qualityCap.isFinite ? qualityCap.clamp(.30, 1.0) : 1.0,
  );

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || !size.width.isFinite || !size.height.isFinite) return;
    if (showBackground) {
      final shader = environmentShader;
      if (shader != null) {
        final values = [
          size.width,
          size.height,
          _time,
          math.max(0, auraEnvironments.indexOf(background)).toDouble(),
          interaction.point.dx,
          interaction.point.dy,
          interaction.pressure,
          _energy,
          _progress,
          _activity,
          _quality,
        ];
        for (var i = 0; i < values.length; ++i) {
          shader.setFloat(i, values[i]);
        }
        canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
      } else {
        paintAuraEnvironment(
          canvas,
          size,
          background,
          _time,
          interaction: interaction,
          progress: _progress,
        );
      }
    }
    if (!showForm) return;
    final scale = formScale.isFinite ? formScale.clamp(.15, 2.5) : 1.0;
    final rebound = motion
        ? math.sin((1 - interaction.release) * math.pi * 3) *
              interaction.release *
              .025
        : 0.0;
    final diameter =
        math.min(size.width * .86 * scale, size.height * .94) * (1 + rebound);
    final free = Size(size.width - diameter, size.height - diameter);
    final origin = formAlignment.alongSize(free);
    final objectSize = Size.square(diameter);
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    final shader = form == 'liquidMetal'
        ? metalShader
        : form == 'livingMatter'
        ? matterShader
        : null;
    if (shader != null) {
      final color = auraAccent(background);
      final values = [
        diameter,
        diameter,
        _time,
        color.r,
        color.g,
        color.b,
        interaction.point.dx,
        interaction.point.dy,
        interaction.pressure,
        interaction.hold,
        _energy,
        _progress,
        _activity,
        _quality,
        motion ? 1.0 : 0.0,
      ];
      for (var i = 0; i < values.length; ++i) {
        shader.setFloat(i, values[i]);
      }
      canvas.drawRect(Offset.zero & objectSize, Paint()..shader = shader);
    } else {
      paintAuraForm(
        canvas,
        objectSize,
        form,
        background,
        _time,
        interaction: interaction,
        energy: _energy,
        progress: _progress,
        quality: _quality,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(AuraPainter oldDelegate) => true;
}

// Procedural geometry is also the shader warm-up path, and the two non-solid
// forms use it directly: projected 3D ribbons/points are batch-rendered by Skia.
void paintAuraEnvironment(
  Canvas canvas,
  Size size,
  String environment,
  double time, {
  AuraInteractionController? interaction,
  double progress = 0,
}) {
  final color = auraAccent(environment);
  canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xff03070d));
  final p = _unit(progress), flow = time * .025;
  for (var layer = 0; layer < 3; ++layer) {
    final points = Float32List((layer == 0 ? 150 : 80) * 2);
    for (var i = 0; i < points.length ~/ 2; ++i) {
      final seed = i + layer * 183;
      var x = _hash(seed + 1), y = _hash(seed + 1237);
      x = (x + math.sin(flow + seed) * .006 * (layer + 1)) % 1;
      y = (y + flow * .006 * (layer + 1)) % 1;
      if (environment == 'gravity') {
        final d = Offset(x - .66, y - .4), r = d.distance + .06;
        final bend = .045 / (r * r + .10);
        x += d.dy * bend;
        y -= d.dx * bend * .6;
      }
      points[i * 2] = _mix(x, .5, math.sin(p * math.pi) * .48) * size.width;
      points[i * 2 + 1] =
          _mix(y, .4, math.sin(p * math.pi) * .48) * size.height;
    }
    canvas.drawRawPoints(
      ui.PointMode.points,
      points,
      Paint()
        ..color = color.withValues(alpha: .18 + layer * .14)
        ..strokeWidth = .65 + layer * .45
        ..strokeCap = StrokeCap.round,
    );
  }
  if (environment == 'aurora') {
    for (var ribbon = 0; ribbon < 40; ++ribbon) {
      final path = Path();
      for (var j = 0; j <= 40; ++j) {
        final f = j / 40;
        final x =
            size.width *
            (.05 + f * .88 + .17 * math.sin(f * 5 + flow + ribbon * .035));
        final y =
            size.height *
            (.07 +
                f * .85 +
                .09 * math.sin(f * 9 + ribbon * .045 - flow * 1.3));
        if (j == 0)
          path.moveTo(x, y);
        else
          path.lineTo(x, y);
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = Color.lerp(
            const Color(0xff154d8b),
            color,
            ribbon / 40,
          )!.withValues(alpha: .025 + .06 * math.sin(ribbon / 40 * math.pi)),
      );
    }
  } else if (environment == 'galaxy') {
    for (var arm = 0; arm < 4; ++arm) {
      final points = Float32List(260 * 2);
      for (var j = 0; j < 260; ++j) {
        final f = j / 260, angle = arm * math.pi / 2 + f * 8 + flow;
        final radius = size.width * (.035 + f * .85);
        points[j * 2] = size.width * .78 + math.cos(angle) * radius;
        points[j * 2 + 1] =
            size.height * .24 +
            math.sin(angle) * radius * .44 +
            math.cos(angle) * radius * .32;
      }
      canvas.drawRawPoints(
        ui.PointMode.points,
        points,
        Paint()
          ..color = color.withValues(alpha: .22)
          ..strokeWidth = 1.0
          ..strokeCap = StrokeCap.round,
      );
    }
  } else if (environment == 'gravity') {
    for (var i = 0; i < 10; ++i) {
      final rect = Rect.fromCenter(
        center: Offset(size.width * .70, size.height * .4),
        width: size.width * (.5 + i * .11),
        height: size.height * (.28 + i * .05),
      );
      canvas.drawArc(
        rect,
        -.9 + flow * .2,
        math.pi * 1.2,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = .6
          ..color = color.withValues(alpha: .045),
      );
    }
  }
}

class _P3 {
  final double x, y, z;
  const _P3(this.x, this.y, this.z);
}

_P3 _rotate(_P3 p, double yaw, double roll) {
  final x = p.x * math.cos(yaw) + p.z * math.sin(yaw);
  final z = p.z * math.cos(yaw) - p.x * math.sin(yaw);
  return _P3(
    x * math.cos(roll) - p.y * math.sin(roll),
    x * math.sin(roll) + p.y * math.cos(roll),
    z,
  );
}

Offset _project(_P3 point, double radius, Offset center) {
  final depth = 3.8 / (3.8 - point.z);
  return center + Offset(point.x, point.y) * radius * depth;
}

void paintAuraForm(
  Canvas canvas,
  Size size,
  String form,
  String environment,
  double time, {
  AuraInteractionController? interaction,
  double energy = 0,
  double progress = 0,
  double quality = 1,
}) {
  final accent = auraAccent(environment), center = size.center(Offset.zero);
  final pressure = interaction?.pressure ?? 0, hold = interaction?.hold ?? 0;
  final pointer = interaction?.point ?? Offset.zero;
  final burst = math.sin(_unit(progress) * math.pi);
  final radius = size.shortestSide * (.42 - hold * .030 - burst * .045);
  final clock = time * .17;
  if (form == 'constellation') {
    final nodes = <_P3>[];
    for (var i = 0; i < 44; ++i) {
      final y = 1 - i / 43 * 2, a = i * 2.39996323 + clock * .5;
      final r = math.sqrt(1 - y * y);
      var point = _rotate(
        _P3(math.cos(a) * r, y, math.sin(a) * r),
        clock * .43,
        .2 * math.sin(clock),
      );
      final influence =
          math.exp(
            -((point.x - pointer.dx) * (point.x - pointer.dx) +
                    (point.y - pointer.dy) * (point.y - pointer.dy)) *
                3,
          ) *
          pressure *
          .2;
      point = _P3(
        point.x +
            pointer.dx * influence +
            burst * math.sin(i * 1.7 + clock) * .18,
        point.y + pointer.dy * influence + burst * math.cos(i * 1.1) * .15,
        point.z,
      );
      nodes.add(point);
    }
    final lines = Paint()
      ..strokeWidth = .65
      ..style = PaintingStyle.stroke;
    for (var i = 0; i < nodes.length; ++i) {
      for (var j = i + 1; j < nodes.length; ++j) {
        final a = nodes[i], b = nodes[j];
        final d = math.sqrt(
          math.pow(a.x - b.x, 2) +
              math.pow(a.y - b.y, 2) +
              math.pow(a.z - b.z, 2),
        );
        if (d > .65 + .07 * math.sin(clock + i)) continue;
        lines.color = accent.withValues(
          alpha: (.04 + .20 * (a.z + b.z + 2) / 4) * (1 - burst * .45),
        );
        canvas.drawLine(
          _project(a, radius, center),
          _project(b, radius, center),
          lines,
        );
      }
    }
    nodes.sort((a, b) => a.z.compareTo(b.z));
    for (final point in nodes) {
      final at = _project(point, radius, center),
          brightness = (point.z + 1) / 2;
      canvas.drawCircle(
        at,
        4 + brightness * 5,
        Paint()
          ..shader = ui.Gradient.radial(at, 4 + brightness * 5, [
            accent.withValues(alpha: .12 + energy * .1),
            accent.withValues(alpha: 0),
          ]),
      );
      canvas.drawCircle(
        at,
        .7 + brightness * 1.6,
        Paint()
          ..color = Color.lerp(
            accent,
            Colors.white,
            brightness,
          )!.withValues(alpha: .35 + brightness * .65),
      );
    }
    return;
  }
  if (form == 'infinity') {
    // Depth bins preserve front/back lighting with only 20 draw calls.
    final bins = List.generate(10, (_) => <double>[]);
    final strands = (10 + quality * 10).round();
    const steps = 144;
    for (var strand = 0; strand < strands; ++strand) {
      _P3? previous;
      for (var i = 0; i <= steps; ++i) {
        final a = i / steps * math.pi * 2;
        final twist = strand / strands * math.pi * 2 + clock;
        final k = .6 + .14 * math.sin(clock * .3);
        final fold = .5 + .5 * math.sin(clock * .19);
        final width = .055 * math.sin(twist + a * 3);
        final point = _rotate(
          _P3(
            math.sin(a) * (1 + width) +
                .12 * fold * math.sin(a * 3 + clock * .13),
            math.sin(a * 2 + .23 * math.sin(clock)) * k +
                .24 * fold * math.cos(a + clock * .11) +
                width * math.cos(a),
            math.cos(a) * .42 +
                .15 * math.sin(a * 3 + clock) +
                .06 * math.cos(twist),
          ),
          .76 * math.sin(clock * .21) + burst * 1.1,
          -.38 + .36 * math.sin(clock * .16),
        );
        final touched = _P3(
          point.x + pointer.dx * pressure * .12 * math.sin(a),
          point.y + pointer.dy * pressure * .16 * math.cos(a * 2),
          point.z,
        );
        if (previous != null) {
          final depth = (touched.z + previous.z) / 2;
          final front = _project(previous, radius * 1.04, center);
          final next = _project(touched, radius * 1.04, center);
          final bin = ((depth + .8) / 1.6 * 9).round().clamp(0, 9);
          bins[bin].addAll([front.dx, front.dy, next.dx, next.dy]);
        }
        previous = touched;
      }
    }
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (var i = 0; i < bins.length; ++i) {
      if (bins[i].isEmpty) continue;
      final points = Float32List.fromList(bins[i]);
      final front = i / 9, alpha = .10 + front * .38 + energy * .12;
      final color = Color.lerp(accent, Colors.white, front * .7)!;
      canvas.drawRawPoints(
        ui.PointMode.lines,
        points,
        paint
          ..strokeWidth = 3.5 + front * 2
          ..color = color.withValues(alpha: alpha * .075),
      );
      canvas.drawRawPoints(
        ui.PointMode.lines,
        points,
        paint
          ..strokeWidth = .55 + front * .85
          ..color = color.withValues(alpha: alpha),
      );
    }
    return;
  }
  // Fine depth-projected filaments: visible and interactive even during shader
  // warm-up. Liquid metal normally uses its ray-marched physical material.
  final strands = (60 + quality * 100).round();
  const steps = 48;
  final segments = Float32List(strands * steps * 4);
  var index = 0;
  for (var strand = 0; strand < strands; ++strand) {
    final latitude = (strand / strands * 2 - 1) * .96;
    Offset? previous;
    for (var i = 0; i <= steps; ++i) {
      final a = i / steps * math.pi * 2;
      final shell = math.sqrt(1 - latitude * latitude);
      final warp =
          1 +
          .17 * math.sin(a * 3 + latitude * 6 + clock) +
          .075 * math.cos(a * 5 - clock * .7);
      final p = _rotate(
        _P3(
          math.cos(a) * shell * warp,
          latitude * (.88 + .16 * math.cos(a * 2 + clock)),
          math.sin(a) * shell * warp,
        ),
        clock * .23,
        -.2,
      );
      final attract =
          math.exp(-math.pow(a - math.atan2(pointer.dy, pointer.dx), 2) * 2) *
          pressure *
          .12;
      final point = _project(
        _P3(p.x + pointer.dx * attract, p.y + pointer.dy * attract, p.z),
        radius,
        center,
      );
      if (previous != null) {
        segments[index++] = previous.dx;
        segments[index++] = previous.dy;
        segments[index++] = point.dx;
        segments[index++] = point.dy;
      }
      previous = point;
    }
  }
  canvas.drawRawPoints(
    ui.PointMode.lines,
    segments,
    Paint()
      ..color = accent.withValues(alpha: .12 + energy * .09)
      ..strokeWidth = .55,
  );
}
