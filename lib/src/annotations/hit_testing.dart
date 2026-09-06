import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import '../coordinates/coordinate_space.dart';
import '../coordinates/normalized_point.dart';
import '../geometry/image_transform.dart';
import 'annotation.dart';
import 'annotation_handles.dart';

/// Default touch slop for annotation hit-testing, in widget pixels.
///
/// Deliberately in *widget pixels*, not normalized units: "within 20
/// logical pixels" means the same thing to a finger on every device,
/// whereas a fixed normalized tolerance would be a different physical
/// distance on every image size -- generous on a small preview, an
/// unhittable hairline on a large one.
const double kAnnotationHitSlop = 20;

/// Returns the top-most annotation at [point], or null.
///
/// Searches in reverse paint order, so the annotation drawn last -- the
/// one visually on top -- wins when several overlap. That matches what
/// the user sees and therefore what they expect to grab.
///
/// [pixelPosition]/[contentRect]/[transform] are only used for rotated
/// rectangles and circles (WORK-0033) -- see [unrotatedEquivalentPoint]
/// for why a rotated shape cannot be tested in [point]'s space directly.
/// An unrotated shape (the overwhelmingly common case) ignores all three
/// and is tested exactly as before.
Annotation? hitTestAnnotations(
  List<Annotation> annotations,
  NormalizedPoint point,
  Rect contentRect, {
  double hitSlopPixels = kAnnotationHitSlop,
  Offset? pixelPosition,
  ImageTransform transform = ImageTransform.identity,
}) {
  final tolerance = normalizedTolerance(hitSlopPixels, contentRect);
  for (var i = annotations.length - 1; i >= 0; i--) {
    final annotation = annotations[i];
    final testPoint = pixelPosition == null
        ? point
        : unrotatedEquivalentPoint(
            annotation,
            pixelPosition,
            contentRect,
            transform,
          );
    if (hitTest(annotation, testPoint, tolerance.x, tolerance.y)) {
      return annotation;
    }
  }
  return null;
}

/// Whether [point] hits [annotation] within the given per-axis
/// tolerance.
bool hitTest(
  Annotation annotation,
  NormalizedPoint point,
  double toleranceX,
  double toleranceY,
) {
  switch (annotation) {
    case RectangleAnnotation(:final rect):
      // Filled rectangles are hit anywhere inside; outlined ones only
      // near the edge, so a large outlined rect does not swallow taps
      // meant for whatever sits within it.
      if (annotation.style.filled) {
        return rect.containsWithTolerance(point, toleranceX, toleranceY);
      }
      final outer = rect.containsWithTolerance(point, toleranceX, toleranceY);
      if (!outer) return false;
      final insideX = point.x > rect.left + toleranceX &&
          point.x < rect.right - toleranceX;
      final insideY = point.y > rect.top + toleranceY &&
          point.y < rect.bottom - toleranceY;
      return !(insideX && insideY);

    case CircleAnnotation(:final rect):
      final cx = (rect.left + rect.right) / 2;
      final cy = (rect.top + rect.bottom) / 2;
      final rx = rect.width / 2;
      final ry = rect.height / 2;
      if (rx <= 0 || ry <= 0) return false;
      // Ellipse equation: <1 inside, ==1 on the edge.
      final dx = (point.x - cx) / rx;
      final dy = (point.y - cy) / ry;
      final value = dx * dx + dy * dy;
      if (annotation.style.filled) {
        // Tolerance widens the ellipse by roughly one slop-width.
        final slack = math.max(toleranceX / rx, toleranceY / ry);
        return value <= (1 + slack) * (1 + slack);
      }
      final slack = math.max(toleranceX / rx, toleranceY / ry);
      final inner = math.max(0.0, 1 - slack);
      return value >= inner * inner && value <= (1 + slack) * (1 + slack);

    case ArrowAnnotation(:final start, :final end):
      return _nearSegment(point, start, end, toleranceX, toleranceY);

    case FreehandAnnotation(:final points):
      if (points.length == 1) {
        return _within(point, points.first, toleranceX, toleranceY);
      }
      for (var i = 0; i < points.length - 1; i++) {
        if (_nearSegment(point, points[i], points[i + 1], toleranceX,
            toleranceY)) {
          return true;
        }
      }
      return false;
  }
}

bool _within(
  NormalizedPoint a,
  NormalizedPoint b,
  double toleranceX,
  double toleranceY,
) {
  if (toleranceX <= 0 || toleranceY <= 0) return a == b;
  final dx = (a.x - b.x) / toleranceX;
  final dy = (a.y - b.y) / toleranceY;
  return dx * dx + dy * dy <= 1;
}

/// Distance from [p] to segment [a]-[b], measured in tolerance-scaled
/// units so an anisotropic content rect still tests as a circle under
/// the finger rather than an ellipse.
bool _nearSegment(
  NormalizedPoint p,
  NormalizedPoint a,
  NormalizedPoint b,
  double toleranceX,
  double toleranceY,
) {
  if (toleranceX <= 0 || toleranceY <= 0) return false;

  // Work in units of tolerance: a hit is then simply "distance <= 1".
  final px = p.x / toleranceX;
  final py = p.y / toleranceY;
  final ax = a.x / toleranceX;
  final ay = a.y / toleranceY;
  final bx = b.x / toleranceX;
  final by = b.y / toleranceY;

  final abx = bx - ax;
  final aby = by - ay;
  final lengthSquared = abx * abx + aby * aby;

  double closestX;
  double closestY;
  if (lengthSquared < 1e-12) {
    closestX = ax;
    closestY = ay;
  } else {
    // Project onto the segment, clamped to its ends.
    final t = (((px - ax) * abx + (py - ay) * aby) / lengthSquared)
        .clamp(0.0, 1.0);
    closestX = ax + t * abx;
    closestY = ay + t * aby;
  }

  final dx = px - closestX;
  final dy = py - closestY;
  return dx * dx + dy * dy <= 1;
}
