import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'aura_power_budget.dart';
import 'aura_motion.dart';

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
  double _elapsed = 0, _quality = .60;
  Duration? _frame;
  int _clocks = 0;
  bool _disposed = false;

  Offset get point => _point;
  bool get pressed => _pressed;
  double get pressure => _pressure;
  double get hold => _hold;
  double get release => _release;
  double get inputPulse => _pulse;
  double get elapsed => _elapsed;
  double get quality => _quality;

  void _clockStarted() {
    if (_clocks++ == 0) _frame = null;
  }

  void _clockStopped() {
    if (_clocks > 0 && --_clocks == 0) _frame = null;
  }

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
        : ((frame - _frame!).inMicroseconds / 1000000).clamp(0.0, 0.25);
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
      _quality = math.min(.65, _quality + 0.01);
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
  final VoidCallback? onShortTap,
      onTouchFeedback,
      onHoldStart,
      onHoldRelease,
      onTouchCancel;
  final AuraPhase phase;
  final bool active, enabled;
  const AuraTouchSurface({
    super.key,
    required this.interaction,
    required this.child,
    required this.label,
    this.onShortTap,
    this.onTouchFeedback,
    this.onHoldStart,
    this.onHoldRelease,
    this.onTouchCancel,
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
      _enabled &&
      (widget.phase == AuraPhase.idle ||
          widget.phase == AuraPhase.questionInput) &&
      widget.onShortTap != null;
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
    if (_pointer != null) widget.onTouchCancel?.call();
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
        (oldWidget.phase != widget.phase && _pointer != null) ||
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
              if (_pointer != null && _enabled && !_dragged) {
                _held = true;
                widget.interaction._holding();
                widget.onHoldStart?.call();
              }
            });
          },
          onPointerMove: (event) {
            if (_pointer != event.pointer || !_enabled) return;
            if ((event.localPosition - _origin).distance > 12 && !_dragged) {
              _dragged = true;
              widget.onTouchCancel?.call();
            }
            widget.interaction._move(_normalize(event.localPosition, size));
          },
          onPointerUp: (event) {
            if (_pointer != event.pointer) return;
            _holdTimer?.cancel();
            _holdTimer = null;
            _pointer = null;
            widget.interaction._up();
            if (_held && !_dragged && _enabled) widget.onHoldRelease?.call();
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
    if (_pointer != null) {
      widget.onTouchCancel?.call();
      widget.interaction.cancel();
    }
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
  if (_ShaderLibrary.ready != null) return;
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

/// Carries the fractional deadline instead of restarting it after each frame.
/// Long scheduler pauses skip work rather than scheduling a catch-up burst.
class AuraFrameCadence {
  double? _next;
  int? _fps;
  int acceptedFrames = 0;
  void reset() {
    _next = null;
    _fps = null;
  }

  bool accept(Duration timestamp, int fps) {
    final now = timestamp.inMicroseconds.toDouble();
    final period = 1000000 / fps;
    if (_fps != fps || _next == null) {
      _fps = fps;
      _next = now;
    }
    if (now + 500 < _next!) return false;
    final skipped = math.max(1, ((now + 500 - _next!) / period).floor() + 1);
    _next = _next! + skipped * period;
    ++acceptedFrames;
    return true;
  }
}

/// Only the soft atmosphere is cached. Fine stars, edges and forms are drawn
/// at the display resolution. This texture is created on a scene change, never
/// at animation frequency, and stays below 4.5 MiB even on large displays.
Size auraRasterSize(
  Size logical, {
  required bool form,
  bool preview = false,
  double quality = 1,
}) {
  if (logical.isEmpty || !logical.width.isFinite || !logical.height.isFinite)
    return Size.zero;
  final cap = quality.isFinite ? quality.clamp(.3, 1.0) : 1.0;
  final longEdge =
      (form ? (preview ? 320.0 : 512.0) : 1536.0) * (.65 + cap * .35);
  final widthCap = form ? longEdge : 768.0 * (.65 + cap * .35);
  final scale = math.min(
    form ? 1.25 : 2.0,
    math.min(widthCap / logical.width, longEdge / logical.longestSide),
  );
  return Size(
    math.max(1, (logical.width * scale).floor()).toDouble(),
    math.max(1, (logical.height * scale).floor()).toDouble(),
  );
}

typedef AuraRasterizer = Future<ui.Image> Function(
  ui.Picture picture,
  int width,
  int height,
);

/// One image and at most one in-flight raster. There is no animation-frame queue.
/// The owner retries its latest state only; superseded work is discarded.
class AuraRasterCache extends ChangeNotifier {
  final AuraRasterizer _rasterize;
  ui.Image? _image;
  ui.ImageShader? _imageShader;
  bool _busy = false, _disposed = false;
  int _generation = 0;
  int startedFrames = 0,
      completedFrames = 0,
      discardedFrames = 0,
      busyDrops = 0;
  Size pixelSize = Size.zero;
  Future<void> _settled = Future<void>.value();
  AuraRasterCache({AuraRasterizer? rasterize})
    : _rasterize = rasterize ?? ((picture, w, h) => picture.toImage(w, h));
  ui.Image? get image => _image;
  ui.ImageShader? get imageShader => _imageShader;
  int get inFlight => _busy ? 1 : 0;
  Future<void> get settled => _settled;
  void invalidate({bool clear = true}) {
    ++_generation;
    if (clear) {
      _imageShader?.dispose();
      _imageShader = null;
      _image?.dispose();
      _image = null;
    }
  }

  bool render(Size logical, Size pixels, void Function(Canvas, Size) paint) {
    if (_disposed || pixels.isEmpty || logical.isEmpty) return false;
    if (_busy) {
      ++busyDrops;
      return false;
    }
    _busy = true;
    pixelSize = pixels;
    ++startedFrames;
    final generation = _generation;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..scale(pixels.width / logical.width, pixels.height / logical.height);
    try {
      paint(canvas, logical);
    } catch (_) {
      recorder.endRecording().dispose();
      _busy = false;
      return false;
    }
    final picture = recorder.endRecording();
    _settled =
        Future<ui.Image>.sync(
              () => _rasterize(
                picture,
                pixels.width.toInt(),
                pixels.height.toInt(),
              ),
            )
            .then<void>((next) {
              if (_disposed || generation != _generation) {
                next.dispose();
                ++discardedFrames;
                return;
              }
              final old = _image;
              _imageShader?.dispose();
              _image = next;
              _imageShader = ui.ImageShader(
                next,
                TileMode.clamp,
                TileMode.clamp,
                Float64List.fromList([
                  1,
                  0,
                  0,
                  0,
                  0,
                  1,
                  0,
                  0,
                  0,
                  0,
                  1,
                  0,
                  0,
                  0,
                  0,
                  1,
                ]),
                filterQuality: FilterQuality.medium,
              );
              ++completedFrames;
              old?.dispose();
            })
            .catchError((Object _) {
              // A bounded procedural fallback stays available if rasterization fails.
            })
            .whenComplete(() {
              picture.dispose();
              _busy = false;
              if (!_disposed) notifyListeners();
            });
    return true;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    invalidate();
    super.dispose();
  }
}

class _AuraSceneState extends State<AuraScene>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late AuraInteractionController _interaction;
  late AuraPowerBudget _power;
  late final Ticker _ticker = createTicker(_tick);
  final _signal = _PaintSignal();
  final _raster = AuraRasterCache();
  final _deviceMotion = AuraMotionController.instance;
  bool _motionLease = false;
  bool _timingsAttached = false;
  ui.FragmentShader? _environment, _matter, _metal;
  bool _foreground = true, _motion = false;
  bool _tickerEnabled = true, _forceRaster = true;
  Size _logicalSize = Size.zero;
  final _cadence = AuraFrameCadence();
  @override
  void initState() {
    super.initState();
    _interaction = widget.interaction ?? AuraInteractionController();
    _interaction.addListener(_changed);
    _power = widget.powerBudget ?? AuraPowerBudget.instance;
    _power.addListener(_powerChanged);
    _raster.addListener(_rasterChanged);
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _load();
  }

  Future<void> _load() async {
    try {
      final cached = _ShaderLibrary.ready;
      if (cached != null) {
        _syncShaders(cached);
        _forceRaster = true;
        return;
      }
      final library = await _ShaderLibrary.load();
      if (!mounted) return;
      _syncShaders(library);
      _forceRaster = true;
      setState(() {});
    } catch (_) {
      // The bounded procedural geometry still responds to touch. Native tests
      // call warmUpAuraShaders separately, so a missing shader cannot pass CI.
    }
  }

  void _syncShaders(_ShaderLibrary library) {
    if (widget.showBackground) {
      _environment ??= library.environment.fragmentShader();
    } else {
      _environment?.dispose();
      _environment = null;
    }
    if (widget.showForm && widget.form == 'livingMatter') {
      _matter ??= library.matter.fragmentShader();
    } else {
      _matter?.dispose();
      _matter = null;
    }
    if (widget.showForm && widget.form == 'liquidMetal') {
      _metal ??= library.metal.fragmentShader();
    } else {
      _metal?.dispose();
      _metal = null;
    }
  }

  void _changed() {
    if (!mounted || !widget.active || !_foreground || !_tickerEnabled) return;
    // Input changes live geometry, never the atmosphere texture.
    _signal.repaint();
    _renderFrame();
  }

  void _rasterChanged() {
    if (!mounted || !_foreground || !_tickerEnabled) return;
    _signal.repaint();
    if (_forceRaster) _renderFrame();
  }

  void _renderFrame() {
    if (!mounted || !_foreground || !_tickerEnabled || _logicalSize.isEmpty)
      return;
    if (!widget.showBackground || !_forceRaster) return;
    final painter = _painter(raw: true);
    if (_raster.render(
      _logicalSize,
      auraRasterSize(
        _logicalSize,
        form: false,
        preview: widget.preview,
        quality: _power.qualityCap,
      ),
      painter.paint,
    )) {
      _forceRaster = false;
    }
  }

  void _powerChanged() {
    if (mounted) {
      _forceRaster = true;
      setState(() {});
    }
  }

  void _timings(List<FrameTiming> frames) {
    if (_motion && widget.active && widget.showBackground && !widget.preview)
      _interaction._budget(frames);
  }

  void _tick(Duration elapsed) {
    final stamp = SchedulerBinding.instance.currentFrameTimeStamp;
    // Common divisors of 60/120 Hz avoid alternating 16/33 ms intervals.
    final cap = _power.maxFps;
    final fps = cap >= 60 && !widget.preview
        ? 60
        : cap >= 30
        ? 30
        : 20;
    if (!_cadence.accept(stamp, fps)) return;
    _interaction._advance(stamp);
    _renderFrame();
    _signal.repaint();
  }

  void _sync() {
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _motion =
        widget.active &&
        _foreground &&
        _tickerEnabled &&
        !MediaQuery.disableAnimationsOf(context) &&
        !MediaQuery.accessibleNavigationOf(context);
    final needsTilt = _motion && widget.showForm && !widget.preview;
    final needsTimings = _motion && widget.showBackground && !widget.preview;
    if (needsTimings != _timingsAttached) {
      _timingsAttached = needsTimings;
      if (needsTimings) {
        SchedulerBinding.instance.addTimingsCallback(_timings);
      } else {
        SchedulerBinding.instance.removeTimingsCallback(_timings);
      }
    }
    if (needsTilt && !_motionLease) {
      _motionLease = true;
      _deviceMotion.acquire();
    }
    if (!needsTilt && _motionLease) {
      _motionLease = false;
      _deviceMotion.release();
    }
    if (_motion && !_ticker.isActive) {
      _cadence.reset();
      _interaction._clockStarted();
      _ticker.start();
    } else if (!_motion && _ticker.isActive) {
      _ticker.stop();
      _interaction._clockStopped();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(AuraScene oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.background != widget.background ||
        oldWidget.showBackground != widget.showBackground) {
      _raster.invalidate();
      _forceRaster = true;
    }
    final library = _ShaderLibrary.ready;
    if (library != null) _syncShaders(library);
    if (oldWidget.powerBudget != widget.powerBudget) {
      _power.removeListener(_powerChanged);
      _power = widget.powerBudget ?? AuraPowerBudget.instance;
      _power.addListener(_powerChanged);
    }
    if (oldWidget.interaction != widget.interaction) {
      _interaction.removeListener(_changed);
      if (_ticker.isActive) _interaction._clockStopped();
      if (oldWidget.interaction == null) _interaction.dispose();
      _interaction = widget.interaction ?? AuraInteractionController();
      if (_ticker.isActive) _interaction._clockStarted();
      _interaction.addListener(_changed);
    }
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    // inactive → hidden → paused is one suspension. Rebuilding on each
    // background notification would schedule layout work after clocks stop.
    if (_foreground == foreground) return;
    _foreground = foreground;
    if (!_foreground) {
      _interaction.cancel();
      _raster.invalidate();
    }
    _forceRaster = true;
    _sync();
    if (mounted) setState(() {});
  }

  AuraPainter _painter({bool raw = false}) => AuraPainter(
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
    pixelRatio: MediaQuery.devicePixelRatioOf(context),
    motion: _motion,
    deviceMotion: raw
        ? null
        : _motionLease
        ? _deviceMotion
        : null,
    environmentShader: _environment,
    matterShader: _matter,
    metalShader: _metal,
    raster: raw || !widget.showBackground ? null : _raster,
    rasterPass: raw,
    repaint: raw ? null : _signal,
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final size = Size(bounds.maxWidth, bounds.maxHeight);
      if (size != _logicalSize && size.width.isFinite && size.height.isFinite) {
        _logicalSize = size;
        _raster.invalidate();
        _forceRaster = true;
      }
      _renderFrame();
      return Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: RepaintBoundary(
                  child: CustomPaint(
                    isComplex: true,
                    willChange: _motion,
                    painter: _painter(),
                  ),
                ),
              ),
            ),
          ),
          widget.child,
        ],
      );
    },
  );
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_timingsAttached)
      SchedulerBinding.instance.removeTimingsCallback(_timings);
    _interaction.removeListener(_changed);
    _power.removeListener(_powerChanged);
    if (_motionLease) _deviceMotion.release();
    if (_ticker.isActive) _interaction._clockStopped();
    if (widget.interaction == null) _interaction.dispose();
    _ticker.dispose();
    _raster.removeListener(_rasterChanged);
    _raster.dispose();
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
  final double pixelRatio;
  final bool showBackground, showForm, preview, motion;
  final Alignment formAlignment;
  final ui.FragmentShader? environmentShader, matterShader, metalShader;
  final AuraMotionController? deviceMotion;
  final AuraRasterCache? raster;
  final bool rasterPass;
  AuraPainter({
    required this.background,
    required this.form,
    required this.phase,
    required this.interaction,
    this.energy = 0,
    this.progress = 0,
    this.formScale = 1,
    this.qualityCap = 1,
    this.pixelRatio = 1,
    this.showBackground = true,
    this.showForm = true,
    this.preview = false,
    this.motion = true,
    this.formAlignment = Alignment.center,
    this.environmentShader,
    this.matterShader,
    this.metalShader,
    this.deviceMotion,
    this.raster,
    this.rasterPass = false,
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
    final cached = raster?.image;
    if (showBackground) {
      final shader = rasterPass ? environmentShader : null;
      if (cached != null && raster!.imageShader != null) {
        paintAuraAtmosphere(canvas, size, raster!, _time);
      } else if (shader != null) {
        final values = [
          size.width,
          size.height,
          7.3,
          math.max(0, auraEnvironments.indexOf(background)).toDouble(),
          0.0,
          0.0,
          0.0,
          0.0,
          0.0,
          0.0,
          _quality,
        ];
        for (var i = 0; i < values.length; ++i) {
          shader.setFloat(i, values[i]);
        }
        canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
      } else {
        paintAuraEnvironment(canvas, size, background, 7.3, stars: false);
      }
      if (!rasterPass)
        paintAuraStars(
          canvas,
          size,
          background,
          _time,
          progress: _progress,
          energy: _energy,
        );
    }
    if (rasterPass) return;
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
    if (!rasterPass) _formMotion(canvas, size);
    final tilt = deviceMotion?.value ?? Offset.zero;
    canvas.translate(
      origin.dx + tilt.dx * diameter * .035,
      origin.dy + tilt.dy * diameter * .035,
    );
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
        pixelRatio,
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

  void _formMotion(Canvas canvas, Size size) {
    if (!motion) return;
    final t = interaction.elapsed;
    final seed = math.max(0, auraForms.indexOf(form)) * 1.37;
    final fluid = form == 'livingMatter'
        ? 1.0
        : form == 'liquidMetal'
        ? .45
        : form == 'infinity'
        ? 1.35
        : .75;
    final settle = interaction.release;
    final driftX =
        math.sin(t * .31 + seed) * .006 + math.sin(t * .73 + seed * 2) * .003;
    final driftY =
        math.cos(t * .23 + seed) * .005 + math.sin(t * .61 - seed) * .003;
    final tilt = deviceMotion?.value ?? Offset.zero;
    final angle =
        math.sin(t * .27 + seed) * .025 +
        math.sin(t * .53 - seed) * .012 +
        interaction.point.dx * interaction.pressure * .055 * fluid +
        math.sin((1 - settle) * math.pi * 4) * settle * .045 * fluid;
    canvas.translate(
      size.width / 2 + size.width * (driftX + tilt.dx * .03),
      size.height / 2 + size.height * (driftY + tilt.dy * .03),
    );
    canvas.rotate(angle);
    if (form == 'livingMatter')
      canvas.skew(
        math.sin(t * .7) * interaction.pressure * .025,
        -interaction.point.dy * interaction.pressure * .018,
      );
    final recoil = math.sin((1 - settle) * math.pi * 3) * settle * .025;
    canvas.scale(1 + recoil, 1 - recoil * .5);
    canvas.translate(-size.width / 2, -size.height / 2);
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
  bool stars = true,
}) {
  final color = auraAccent(environment);
  canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xff03070d));
  final flow = time * .025;
  if (stars)
    paintAuraStars(canvas, size, environment, time, progress: progress);
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
        if (j == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
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
    canvas.drawCircle(
      Offset(size.width * .78, size.height * .24),
      size.width * .7,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(size.width * .78, size.height * .24),
          size.width * .7,
          [color.withValues(alpha: .04), color.withValues(alpha: 0)],
        ),
    );
  }
}

// A small textured mesh moves the cached atmosphere continuously. The image
// shader lives with the cache; only 187 vertices change, with no image readback.
final _atmosphereIndices = Uint16List.fromList([
  for (var y = 0; y < 16; ++y)
    for (var x = 0; x < 10; ++x) ...[
      y * 11 + x,
      y * 11 + x + 1,
      (y + 1) * 11 + x,
      y * 11 + x + 1,
      (y + 1) * 11 + x + 1,
      (y + 1) * 11 + x,
    ],
]);
void paintAuraAtmosphere(
  Canvas canvas,
  Size size,
  AuraRasterCache cache,
  double time,
) {
  final positions = Float32List(187 * 2), tex = Float32List(187 * 2);
  for (var y = 0; y <= 16; ++y) {
    final v = y / 16;
    for (var x = 0; x <= 10; ++x) {
      final u = x / 10, i = (y * 11 + x) * 2;
      positions[i] = u * size.width;
      positions[i + 1] = v * size.height;
      // Overscan absorbs motion at the edges; no dark gaps or image stretching.
      tex[i] =
          (.04 +
              u * .92 +
              .018 * math.sin(v * 7 + time * .075) +
              .008 * math.sin(u * 9 - time * .043)) *
          cache.pixelSize.width;
      tex[i + 1] =
          (.04 +
              v * .92 +
              .018 * math.sin(u * 5 - time * .061) +
              .008 * math.cos(v * 8 + time * .051)) *
          cache.pixelSize.height;
    }
  }
  final mesh = ui.Vertices.raw(
    ui.VertexMode.triangles,
    positions,
    textureCoordinates: tex,
    indices: _atmosphereIndices,
  );
  canvas.drawVertices(mesh, BlendMode.src, Paint()..shader = cache.imageShader);
  mesh.dispose();
}

final _starSeeds = List.generate(
  3,
  (layer) => List.generate(
    layer == 0 ? 150 : 80,
    (i) => Offset(_hash(i + layer * 183 + 1), _hash(i + layer * 183 + 1237)),
  ),
);
void paintAuraStars(
  Canvas canvas,
  Size size,
  String environment,
  double time, {
  double progress = 0,
  double energy = 0,
}) {
  final color = auraAccent(environment);
  final p = _unit(progress), flow = time * .025;
  for (var layer = 0; layer < 3; ++layer) {
    final points = Float32List((layer == 0 ? 150 : 80) * 2);
    for (var i = 0; i < points.length ~/ 2; ++i) {
      final seed = i + layer * 183;
      var x = _starSeeds[layer][i].dx, y = _starSeeds[layer][i].dy;
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
        ..color = color.withValues(alpha: .18 + layer * .14 + energy * .04)
        ..strokeWidth = .65 + layer * .45
        ..strokeCap = StrokeCap.round,
    );
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

class _Rotation {
  final double cy, sy, cr, sr;
  _Rotation(double yaw, double roll)
    : cy = math.cos(yaw),
      sy = math.sin(yaw),
      cr = math.cos(roll),
      sr = math.sin(roll);
  _P3 apply(_P3 p) {
    final x = p.x * cy + p.z * sy;
    return _P3(x * cr - p.y * sr, x * sr + p.y * cr, p.z * cy - p.x * sy);
  }
}

final _constellationSeeds = List.generate(44, (i) {
  final y = 1 - i / 43 * 2, a = i * 2.39996323, r = math.sqrt(1 - y * y);
  return _P3(math.cos(a) * r, y, math.sin(a) * r);
});
final _constellationEdges = <(int, int)>[
  for (var i = 0; i < 44; ++i)
    for (var j = i + 1; j < 44; ++j)
      if (_nearbyStars(_constellationSeeds[i], _constellationSeeds[j])) (i, j),
];
bool _nearbyStars(_P3 a, _P3 b) {
  final x = a.x - b.x, y = a.y - b.y, z = a.z - b.z;
  return x * x + y * y + z * z < 1.44;
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
  final release = interaction?.release ?? 0;
  final wake = math.sin((1 - release) * math.pi * 3) * release;
  final burst = math.sin(_unit(progress) * math.pi);
  final radius = size.shortestSide * (.42 - hold * .030 - burst * .045);
  final clock = time * .17;
  if (form == 'constellation') {
    final rotation = _Rotation(-clock * .07, .2 * math.sin(clock));
    final nodes = <_P3>[], projected = <Offset>[];
    for (var i = 0; i < _constellationSeeds.length; ++i) {
      var point = rotation.apply(_constellationSeeds[i]);
      final dx = point.x - pointer.dx, dy = point.y - pointer.dy;
      final influence = math.exp(-(dx * dx + dy * dy) * 3) * pressure * .2;
      point = _P3(
        point.x +
            pointer.dx * influence +
            burst * math.sin(i * 1.7 + clock) * .18 -
            point.y * influence * .5 +
            wake * math.sin(i * 1.7 + clock) * .09,
        point.y +
            pointer.dy * influence +
            burst * math.cos(i * 1.1) * .15 +
            point.x * influence * .5 +
            wake * math.cos(i * 1.1 - clock) * .08,
        point.z + math.sin(clock * .71 + i * 2.3) * .025,
      );
      nodes.add(point);
      projected.add(_project(point, radius, center));
    }
    final lines = Paint()
      ..strokeWidth = .65
      ..style = PaintingStyle.stroke;
    for (final edge in _constellationEdges) {
      final a = nodes[edge.$1], b = nodes[edge.$2];
      final dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
      final distance = math.sqrt(dx * dx + dy * dy + dz * dz);
      final reach = .65 + .07 * math.sin(clock + edge.$1);
      // Fade through the connection boundary instead of popping whole lines.
      final fade = ((reach + .05 - distance) / .10).clamp(0.0, 1.0);
      if (fade == 0) continue;
      lines.color = accent.withValues(
        alpha:
            (.04 + .20 * (a.z + b.z + 2) / 4) *
            (1 - burst * .45) *
            fade *
            fade *
            (3 - 2 * fade),
      );
      canvas.drawLine(projected[edge.$1], projected[edge.$2], lines);
    }
    final paint = Paint();
    for (var i = 0; i < nodes.length; ++i) {
      final at = projected[i],
          brightness = ((nodes[i].z + 1) / 2).clamp(0.0, 1.0);
      // Three cheap translucent discs replace 44 new gradient shaders/frame.
      canvas.drawCircle(
        at,
        4 + brightness * 5,
        paint..color = accent.withValues(alpha: .018 + energy * .01),
      );
      canvas.drawCircle(
        at,
        2 + brightness * 2.8,
        paint..color = accent.withValues(alpha: .045 + energy * .025),
      );
      canvas.drawCircle(
        at,
        .7 + brightness * 1.6,
        paint
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
    final strands = (7 + quality * 7).round();
    const steps = 96;
    final rotation = _Rotation(
      .76 * math.sin(clock * .21) + burst * 1.1,
      -.38 + .36 * math.sin(clock * .16),
    );
    for (var strand = 0; strand < strands; ++strand) {
      _P3? previous;
      for (var i = 0; i <= steps; ++i) {
        final a = i / steps * math.pi * 2;
        final twist = strand / strands * math.pi * 2 + clock;
        final k = .6 + .14 * math.sin(clock * .3);
        final fold = .5 + .5 * math.sin(clock * .19);
        final width = .055 * math.sin(twist + a * 3);
        final point = rotation.apply(
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
        );
        final touched = _P3(
          point.x +
              pointer.dx * pressure * .12 * math.sin(a) +
              wake * .07 * math.cos(a * 3 + clock),
          point.y + pointer.dy * pressure * .16 * math.cos(a * 2),
          point.z +
              pressure * .10 * math.sin(a * 3 + clock) +
              wake * .08 * math.cos(a * 2),
        );
        if (previous != null) {
          final depth = (touched.z + previous.z) / 2;
          final front = _project(previous, radius * 1.04, center);
          final next = _project(touched, radius * 1.04, center);
          final bin = ((depth + .8) / 1.6 * 9).round().clamp(0, 9);
          bins[bin].add(front.dx);
          bins[bin].add(front.dy);
          bins[bin].add(next.dx);
          bins[bin].add(next.dy);
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
  // warm-up. Liquid metal normally uses its analytic reflective material.
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
