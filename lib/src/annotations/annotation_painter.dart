import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../coordinates/normalized_point.dart';
import '../coordinates/normalized_rect.dart';
import '../geometry/image_transform.dart';
import 'annotation.dart';

/// Renders annotations onto a canvas.
///
/// **This is the only place annotations are drawn.** The live overlay
/// and (in Phase 4) the export pipeline both go through
/// [paintAnnotations], because the failure mode this design exists to
/// prevent is an annotation that looks right on screen and lands
/// somewhere else in the exported file. Two rendering paths cannot be
/// kept in agreement by discipline alone; one path cannot diverge.
///
/// Everything is expressed relative to [contentRect], so the same
/// annotations drawn against a 400px preview rect and a 4000px export
/// rect produce the same picture at different scales.
void paintAnnotations(
  Canvas canvas,
  Rect contentRect,
  List<Annotation> annotations, {
  String? selectedId,
  ImageTransform transform = ImageTransform.identity,
}) {
  // Clip to the visible region so a mark straddling the crop boundary
  // keeps its visible half and loses the rest. Not hidden, not deleted:
  // the stored geometry is untouched, so widening the crop brings the
  // clipped part straight back.
  //
  // The export path calls this same function, so a mark clipped on
  // screen is clipped identically in the saved file -- if the two
  // differed, a partly-clipped annotation would reappear whole in a
  // report.
  if (transform.cropRect != null) {
    canvas.save();
    canvas.clipRect(contentRect);
  }

  // Stroke widths are a fraction of the shorter side so weight scales
  // with the image rather than the device.
  final shorterSide = math.min(contentRect.width, contentRect.height);

  for (final annotation in annotations) {
    final paint = Paint()
      ..color = annotation.style.color
      ..strokeWidth = annotation.style.resolveStrokeWidth(shorterSide)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = annotation.style.filled
          ? PaintingStyle.fill
          : PaintingStyle.stroke;

    // Exhaustive over the sealed hierarchy: adding a shape without
    // teaching this switch about it is a compile error, not a silently
    // invisible annotation.
    switch (annotation) {
      case RectangleAnnotation(:final rect):
        canvas.drawRect(_mapRect(rect, contentRect, transform), paint);
      case CircleAnnotation(:final rect):
        canvas.drawOval(_mapRect(rect, contentRect, transform), paint);
      case ArrowAnnotation(:final start, :final end):
        _paintArrow(
          canvas,
          _mapOffset(start, contentRect, transform),
          _mapOffset(end, contentRect, transform),
          paint,
        );
      case FreehandAnnotation(:final points):
        _paintFreehand(
          canvas,
          [for (final p in points) _mapOffset(p, contentRect, transform)],
          paint,
        );
    }

    if (annotation.id == selectedId) {
      _paintSelection(
        canvas,
        _mapRect(annotation.bounds, contentRect, transform),
        paint,
      );
    }
  }

  if (transform.cropRect != null) canvas.restore();
}

/// Projects a normalized point through [transform] into widget space.
Offset _mapOffset(
  NormalizedPoint point,
  Rect contentRect,
  ImageTransform transform,
) {
  final mapped = transform.mapPoint(point);
  return Offset(
    contentRect.left + mapped.x * contentRect.width,
    contentRect.top + mapped.y * contentRect.height,
  );
}

/// Projects a normalized rect through [transform].
///
/// Built from the mapped corners rather than mapping width and height,
/// since a 90-degree rotation swaps the axes and would otherwise produce
/// a rect of the wrong shape. `Rect.fromPoints` re-normalises the corner
/// order, so a rotation that puts left past right still yields a valid
/// rect.
Rect _mapRect(
  NormalizedRect rect,
  Rect contentRect,
  ImageTransform transform,
) {
  final a = _mapOffset(
    NormalizedPoint(rect.left, rect.top),
    contentRect,
    transform,
  );
  final b = _mapOffset(
    NormalizedPoint(rect.right, rect.bottom),
    contentRect,
    transform,
  );
  return Rect.fromPoints(a, b);
}

void _paintArrow(Canvas canvas, Offset start, Offset end, Paint paint) {
  // An arrow is always stroked -- a "filled" arrow has no meaning, and
  // honouring the flag would silently produce a filled triangle over
  // the whole shaft.
  final shaftPaint = Paint()
    ..color = paint.color
    ..strokeWidth = paint.strokeWidth
    ..strokeCap = StrokeCap.round
    ..style = PaintingStyle.stroke;

  canvas.drawLine(start, end, shaftPaint);

  final dx = end.dx - start.dx;
  final dy = end.dy - start.dy;
  final length = math.sqrt(dx * dx + dy * dy);
  // A degenerate arrow (a tap, not a drag) gets no head: computing one
  // would divide by zero, and there is no direction to point.
  if (length < 1e-6) return;

  // Head size follows stroke weight so it scales with the image, with a
  // floor relative to the arrow's own length so a very short arrow does
  // not become all head.
  final headLength = math.min(paint.strokeWidth * 4, length * 0.4);
  final angle = math.atan2(dy, dx);
  const spread = math.pi / 7;

  final head = Path()
    ..moveTo(end.dx, end.dy)
    ..lineTo(
      end.dx - headLength * math.cos(angle - spread),
      end.dy - headLength * math.sin(angle - spread),
    )
    ..lineTo(
      end.dx - headLength * math.cos(angle + spread),
      end.dy - headLength * math.sin(angle + spread),
    )
    ..close();

  canvas.drawPath(
    head,
    Paint()
      ..color = paint.color
      ..style = PaintingStyle.fill,
  );
}

void _paintFreehand(Canvas canvas, List<Offset> points, Paint paint) {
  final strokePaint = Paint()
    ..color = paint.color
    ..strokeWidth = paint.strokeWidth
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke;

  if (points.length == 1) {
    // A single tap still deserves a visible dot; drawPath on a
    // one-point path renders nothing.
    canvas.drawCircle(points.first, strokePaint.strokeWidth / 2, strokePaint);
    return;
  }

  final path = Path()..moveTo(points.first.dx, points.first.dy);
  for (var i = 1; i < points.length; i++) {
    path.lineTo(points[i].dx, points[i].dy);
  }
  canvas.drawPath(path, strokePaint);
}

void _paintSelection(Canvas canvas, Rect bounds, Paint source) {
  final handle = Paint()
    ..color = source.color.withValues(alpha: 0.9)
    ..strokeWidth = source.strokeWidth * 0.6
    ..style = PaintingStyle.stroke;

  final inflated = bounds.inflate(source.strokeWidth * 2);
  _paintDashedRect(canvas, inflated, handle);
}

void _paintDashedRect(Canvas canvas, Rect rect, Paint paint) {
  const dash = 8.0;
  const gap = 5.0;
  final path = Path()..addRect(rect);
  for (final PathMetric metric in path.computeMetrics()) {
    var distance = 0.0;
    while (distance < metric.length) {
      final next = math.min(distance + dash, metric.length);
      canvas.drawPath(metric.extractPath(distance, next), paint);
      distance = next + gap;
    }
  }
}

/// `CustomPainter` wrapper for the live overlay. Delegates straight to
/// [paintAnnotations] -- it holds no drawing logic of its own, so the
/// export path can call the same function without a widget in sight.
class AnnotationPainter extends CustomPainter {
  const AnnotationPainter({
    required this.annotations,
    required this.contentRect,
    this.selectedId,
    this.transform = ImageTransform.identity,
  });

  final List<Annotation> annotations;
  final Rect contentRect;
  final String? selectedId;
  final ImageTransform transform;

  @override
  void paint(Canvas canvas, Size size) {
    paintAnnotations(
      canvas,
      contentRect,
      annotations,
      selectedId: selectedId,
      transform: transform,
    );
  }

  @override
  bool shouldRepaint(AnnotationPainter oldDelegate) {
    return oldDelegate.contentRect != contentRect ||
        oldDelegate.selectedId != selectedId ||
        oldDelegate.transform != transform ||
        !listEquals(oldDelegate.annotations, annotations);
  }
}
