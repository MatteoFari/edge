// Static expressive shapes. The caller supplies the measured fraction; null
// paints only a track and never stands in for a measurement.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

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
