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

    // Text's real on-screen box needs a TextPainter layout pass --
    // unlike every other type, [hitTest]'s normalized-space geometry
    // cannot express it exactly (see TextAnnotation.bounds), so this
    // tests directly in pixel space rather than through the shared
    // per-type switch whenever a pixel position is available. Rotation
    // -aware the same way a rotated rect/circle is: the *unrotated*
    // mapped box is rotated into on-screen corners and tested as a
    // polygon, rather than inverse-rotating the tap the way
    // [unrotatedEquivalentPoint] does -- equivalent for a hit test,
    // and avoids a round trip back through the normalized pipeline for
    // a type whose normalized-space geometry is only ever a coarse
    // estimate to begin with.
    if (annotation is TextAnnotation && pixelPosition != null) {
      final unrotated = textBoundsInPixels(annotation, contentRect, transform);
      final corners = rotatedCorners(
        unrotated.inflate(hitSlopPixels),
        annotation.rotation,
      );
      if (_containsPoint(corners, pixelPosition)) return annotation;
      continue;
    }

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

    case TextAnnotation():
      // Uses the coarse `bounds` estimate -- adequate for a caller
      // working in pure normalized space with no pixel context. The
      // real, exact on-screen box is only reachable in pixel space (it
      // needs a `TextPainter` layout pass), which is what
      // [hitTestAnnotations] uses instead whenever a [pixelPosition] is
      // available -- the overwhelmingly common case, since every real
      // gesture in this package supplies one.
      return annotation.bounds.containsWithTolerance(
        point,
        toleranceX,
        toleranceY,
      );

    case ImageAnnotation(:final rect):
      // Always hit anywhere inside, unlike an unfilled rectangle --
      // an image annotation has no "outline only" mode, and hit-testing
      // must work regardless of decode state (WORK-0037's decision),
      // so this never depends on whether the image has finished
      // decoding.
      return rect.containsWithTolerance(point, toleranceX, toleranceY);
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

/// Whether [point] lies inside the polygon described by [corners], via
/// the standard even-odd ray-casting test.
///
/// Only ever called with the four corners [rotatedCorners] returns (a
/// possibly-rotated rectangle), never an arbitrary polygon -- general
/// enough for that shape without needing anything more specialised for
/// a quadrilateral specifically.
bool _containsPoint(List<Offset> corners, Offset point) {
  var inside = false;
  for (var i = 0, j = corners.length - 1; i < corners.length; j = i++) {
    final a = corners[i];
    final b = corners[j];
    final crosses = (a.dy > point.dy) != (b.dy > point.dy);
    if (!crosses) continue;
    final xAtY = (b.dx - a.dx) * (point.dy - a.dy) / (b.dy - a.dy) + a.dx;
    if (point.dx < xAtY) inside = !inside;
  }
  return inside;
}
