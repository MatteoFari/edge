// Expressive shapes. Gauges use measured fractions; null paints only a track.
// The loading shape takes a caller-owned animation phase, not a measurement.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// M3-inspired loading silhouettes, sampled on the same radial grid so every
/// outline morphs continuously. The caller owns phase and reduced-motion gating.
/// Sequence: soft burst, nine-lobed cookie, pentagon, pill, sunny, four-lobed
/// cookie, oval. https://m3.material.io/components/loading-indicator/overview
class ExpressiveLoadingShape extends CustomPainter {
  const ExpressiveLoadingShape(this.phase, this.color, this.curve);
  final double phase;
  final Color color;
  final Curve curve;
  static const _samples = 96;

  static final _shapes = List.generate(7, (shape) {
    return List.generate(_samples, (i) {
      final angle = i * math.pi * 2 / _samples - math.pi / 2;
      final cos = math.cos(angle), sin = math.sin(angle);
      final radius = switch (shape) {
        0 => .78 + .22 * math.cos(10 * angle),
        1 => .92 + .08 * math.cos(9 * (angle + math.pi / 2)),
        2 =>
          math.cos(math.pi / 5) /
              math.cos((angle + math.pi / 2) % (math.pi * 2 / 5) - math.pi / 5),
        3 =>
          sin.abs() * .64 <= cos.abs() * .36
              ? .64 / cos.abs()
              : .36 * sin.abs() + math.sqrt(.64 * .64 - .36 * .36 * cos * cos),
        4 => .9 + .1 * math.cos(8 * angle),
        5 => .82 + .18 * math.cos(4 * angle),
        _ =>
          1 /
              math.sqrt(
                math.pow(math.cos(angle + math.pi / 4), 2) +
                    math.pow(math.sin(angle + math.pi / 4) / .64, 2),
              ),
      };
      return Offset(cos, sin) * radius;
    });
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final t = phase.isFinite ? phase.clamp(0.0, 1.0) % 1 : 0.0;
    final step = t * _shapes.length;
    final from = step.floor(), to = (from + 1) % _shapes.length;
    final blend = curve.transform(step - from).clamp(0.0, 1.0);
    final points = List.generate(
      _samples,
      (i) => Offset.lerp(_shapes[from][i], _shapes[to][i], blend)!,
    );
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 0; i < _samples; i++) {
      final p0 = points[(i - 1) % _samples], p1 = points[i];
      final p2 = points[(i + 1) % _samples], p3 = points[(i + 2) % _samples];
      final c1 = p1 + (p2 - p0) / 6, c2 = p2 - (p3 - p1) / 6;
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
    }
    path.close();
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    // Four complete turns keep the rotation continuous at the loop boundary.
    canvas.rotate(t * math.pi * 8);
    final scale = math.min(size.width, size.height) * .395;
    canvas.scale(scale);
    canvas.drawPath(path, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ExpressiveLoadingShape oldDelegate) =>
      phase != oldDelegate.phase ||
      color != oldDelegate.color ||
      curve != oldDelegate.curve;
}

class ExpressiveRecoveryGauge extends CustomPainter {
  final double? fraction;
  final Color color, track;

  const ExpressiveRecoveryGauge(this.fraction, this.color, this.track);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2 - S.x2;
    if (radius <= 0) return;
    Path arc(double fraction) {
      final path = Path();
      final samples = (360 * fraction).ceil();
      for (var i = 0; i <= samples; i++) {
        final turn = samples == 0 ? 0.0 : fraction * i / samples;
        final angle = -math.pi / 2 + turn * math.pi * 2;
        final waveRadius = radius + math.sin(turn * math.pi * 2 * 14) * S.x1;
        final point =
            center + Offset(math.cos(angle), math.sin(angle)) * waveRadius;
        if (i == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      return path;
    }

    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = S.x1 + 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(arc(1), pen..color = track);
    final fill = fraction?.clamp(0.0, 1.0);
    if (fill != null && fill > 0) {
      canvas.drawPath(arc(fill), pen..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant ExpressiveRecoveryGauge oldDelegate) =>
      fraction != oldDelegate.fraction ||
      color != oldDelegate.color ||
      track != oldDelegate.track;
}

class ExpressiveSleepMeter extends CustomPainter {
  final double? fraction;
  final Color color, track;

  const ExpressiveSleepMeter(this.fraction, this.color, this.track);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= S.x2 || size.height <= 0) return;
    final width = size.width - S.x2;
    // Integral waves keep the two ends level; clipping a partial wave changes
    // only the amount filled, never the wavelength of the measured track.
    final waves = math.max(2, (width / S.x6).round());
    Path line(double fraction) {
      final path = Path();
      final samples = (width * fraction).ceil();
      for (var i = 0; i <= samples; i++) {
        final t = samples == 0 ? 0.0 : fraction * i / samples;
        final x = S.x1 + width * t;
        final y = size.height / 2 + math.sin(t * math.pi * 2 * waves) * S.x1;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      return path;
    }

    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = S.x1 + 2
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(line(1), pen..color = track);
    final fill = fraction?.clamp(0.0, 1.0);
    if (fill != null && fill > 0) {
      canvas.drawPath(line(fill), pen..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant ExpressiveSleepMeter oldDelegate) =>
      fraction != oldDelegate.fraction ||
      color != oldDelegate.color ||
      track != oldDelegate.track;
}

class ExpressiveStrainSegments extends CustomPainter {
  final double? fraction;
  final Color color, track;

  const ExpressiveStrainSegments(this.fraction, this.color, this.track);

  @override
  void paint(Canvas canvas, Size size) {
    // Seven capsules each cover three points of the existing 0–21 scale. A
    // partially filled capsule preserves the fraction between those marks.
    const segments = 7;
    final width = (size.width - S.x1 * (segments - 1)) / segments;
    if (width <= 0 || size.height <= 0) return;
    final fill = fraction?.clamp(0.0, 1.0);
    final pen = Paint();
    for (var i = 0; i < segments; i++) {
      final rect = Rect.fromLTWH(i * (width + S.x1), 0, width, size.height);
      final pill = RRect.fromRectAndRadius(rect, const Radius.circular(R.pill));
      canvas.drawRRect(pill, pen..color = track);
      final part = fill == null ? 0.0 : (fill * segments - i).clamp(0.0, 1.0);
      if (part <= 0) continue;
      canvas.save();
      canvas.clipRRect(pill);
      canvas.drawRect(
        Rect.fromLTRB(
          rect.left,
          rect.bottom - rect.height * part,
          rect.right,
          rect.bottom,
        ),
        pen..color = color,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant ExpressiveStrainSegments oldDelegate) =>
      fraction != oldDelegate.fraction ||
      color != oldDelegate.color ||
      track != oldDelegate.track;
}
