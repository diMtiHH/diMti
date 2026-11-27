import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'cosmic_theme.dart';

enum AuraIconKind {
  brand,
  settings,
  universe,
  world,
  back,
  close,
  microphone,
  arrowRight,
  check,
  volume,
  haptics,
}

/// Original vector glyphs. The surrounding control owns its accessible label.
class AuraIcon extends StatelessWidget {
  final AuraIconKind kind;
  final double size, strokeWidth;
  final Color? color;
  const AuraIcon({
    super.key,
    required this.kind,
    this.size = 24,
    this.color,
    this.strokeWidth = 1.5,
  });

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: AuraIconPainter(
          kind: kind,
          color: color ?? IconTheme.of(context).color ?? CosmicPalette.silver,
          strokeWidth: strokeWidth,
        ),
      ),
    ),
  );
}

/// A four-ray energy mark with an offset orbital arc, shared by the identity.
class AuraBrandMark extends StatelessWidget {
  final double size;
  final Color? color;
  const AuraBrandMark({super.key, this.size = 28, this.color});
  @override
  Widget build(BuildContext context) =>
      AuraIcon(kind: AuraIconKind.brand, size: size, color: color);
}

class AuraIconPainter extends CustomPainter {
  final AuraIconKind kind;
  final Color color;
  final double strokeWidth;
  const AuraIconPainter({
    required this.kind,
    required this.color,
    this.strokeWidth = 1.5,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = color;
    void path(List<Offset> points) {
      final shape = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) {
        shape.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(shape, line);
    }

    switch (kind) {
      case AuraIconKind.brand:
      case AuraIconKind.universe:
        final rays = Path()
          ..moveTo(12, 2.3)
          ..cubicTo(12.7, 9.1, 14.9, 11.2, 21.7, 12)
          ..cubicTo(14.9, 12.8, 12.7, 14.9, 12, 21.7)
          ..cubicTo(11.3, 14.9, 9.1, 12.8, 2.3, 12)
          ..cubicTo(9.1, 11.2, 11.3, 9.1, 12, 2.3)
          ..close();
        canvas.drawPath(rays, line);
        canvas.drawCircle(const Offset(12, 12), 1.2, fill);
        if (kind == AuraIconKind.brand) {
          canvas.drawArc(
            const Rect.fromLTWH(3, 3, 18, 18),
            -1.08,
            0.63,
            false,
            Paint()
              ..color = color.withValues(alpha: 0.6)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 0.8
              ..strokeCap = StrokeCap.round,
          );
          canvas.drawCircle(const Offset(19.6, 5.9), 0.65, fill);
        }
      case AuraIconKind.settings:
        for (final row in [(6.0, 8.0), (12.0, 16.0), (18.0, 10.0)]) {
          canvas.drawLine(
            Offset(3, row.$1),
            Offset(row.$2 - 2.2, row.$1),
            line,
          );
          canvas.drawLine(
            Offset(row.$2 + 2.2, row.$1),
            Offset(21, row.$1),
            line,
          );
          canvas.drawCircle(Offset(row.$2, row.$1), 2.2, line);
        }
      case AuraIconKind.world:
        canvas.drawCircle(const Offset(12, 12), 9, line);
        canvas.drawOval(const Rect.fromLTWH(7.1, 3, 9.8, 18), line);
        canvas.drawArc(
          const Rect.fromLTWH(3.3, 7.6, 17.4, 8.8),
          0,
          math.pi,
          false,
          line,
        );
        canvas.drawArc(
          const Rect.fromLTWH(3.3, 7.6, 17.4, 8.8),
          math.pi,
          math.pi,
          false,
          line,
        );
        canvas.drawCircle(const Offset(17.7, 6.3), 1.4, fill);
      case AuraIconKind.back:
        path(const [Offset(14.5, 5), Offset(7.5, 12), Offset(14.5, 19)]);
      case AuraIconKind.close:
        path(const [Offset(6.5, 6.5), Offset(17.5, 17.5)]);
        path(const [Offset(17.5, 6.5), Offset(6.5, 17.5)]);
      case AuraIconKind.arrowRight:
        path(const [Offset(3.5, 12), Offset(20.5, 12)]);
        path(const [Offset(14.5, 6), Offset(20.5, 12), Offset(14.5, 18)]);
      case AuraIconKind.check:
        path(const [Offset(4.5, 12), Offset(9.5, 17), Offset(20, 6.5)]);
      case AuraIconKind.microphone:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(8.5, 2.5, 7, 12),
            const Radius.circular(3.5),
          ),
          line,
        );
        final cradle = Path()
          ..moveTo(5.5, 10.8)
          ..lineTo(5.5, 12)
          ..cubicTo(5.5, 20.1, 18.5, 20.1, 18.5, 12)
          ..lineTo(18.5, 10.8);
        canvas.drawPath(cradle, line);
        path(const [Offset(12, 18), Offset(12, 21.5)]);
        path(const [Offset(8.5, 21.5), Offset(15.5, 21.5)]);
      case AuraIconKind.volume:
        final speaker = Path()
          ..moveTo(3, 9)
          ..lineTo(7.5, 9)
          ..lineTo(12, 5)
          ..lineTo(12, 19)
          ..lineTo(7.5, 15)
          ..lineTo(3, 15)
          ..close();
        canvas.drawPath(speaker, line);
        canvas.drawArc(
          const Rect.fromLTWH(10, 7.5, 9, 9),
          -0.8,
          1.6,
          false,
          line,
        );
        canvas.drawArc(
          const Rect.fromLTWH(8, 3.5, 17, 17),
          -0.72,
          1.44,
          false,
          line,
        );
      case AuraIconKind.haptics:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(8, 4, 8, 16),
            const Radius.circular(2.3),
          ),
          line,
        );
        path(const [
          Offset(5, 6),
          Offset(3, 9),
          Offset(5, 12),
          Offset(3, 15),
          Offset(5, 18),
        ]);
        path(const [
          Offset(19, 6),
          Offset(21, 9),
          Offset(19, 12),
          Offset(21, 15),
          Offset(19, 18),
        ]);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(AuraIconPainter oldDelegate) =>
      kind != oldDelegate.kind ||
      color != oldDelegate.color ||
      strokeWidth != oldDelegate.strokeWidth;
}
