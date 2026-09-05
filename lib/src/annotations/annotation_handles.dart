import 'dart:ui' show Offset, Rect;

import '../coordinates/normalized_point.dart';
import '../coordinates/normalized_rect.dart';
import '../geometry/image_transform.dart';
import 'annotation.dart';

/// Touch target for a resize handle, in logical pixels.
///
/// Pixels, not normalized units — a finger is the same size whatever the
/// image's resolution. Note this is the *opposite* rule from
/// `AnnotationStyle.strokeWidth`, which scales with the image: a stroke
/// is part of the picture, a handle is part of the UI. Both are correct;
/// changing either to match the other would be a regression.
const double kHandleHitSlop = 24;

/// Drawn radius of a handle, in logical pixels. Smaller than the touch
/// target, so handles stay unobtrusive without being hard to grab.
const double kHandleRadius = 7;

/// Which grip on a selected annotation a drag has taken hold of.
enum AnnotationGrip {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,

  /// An arrow's tail.
  start,

  /// An arrow's head.
  end,
}

/// The grips [annotation] offers, in *original image* space.
///
/// Freehand strokes offer none: scaling a sampled path is a different
/// operation from dragging a corner, and naive per-point scaling
/// distorts the stroke. They can still be moved and deleted.
Map<AnnotationGrip, NormalizedPoint> gripsOf(Annotation annotation) {
  return switch (annotation) {
    RectangleAnnotation(:final rect) || CircleAnnotation(:final rect) => {
      AnnotationGrip.topLeft: NormalizedPoint(rect.left, rect.top),
      AnnotationGrip.topRight: NormalizedPoint(rect.right, rect.top),
      AnnotationGrip.bottomLeft: NormalizedPoint(rect.left, rect.bottom),
      AnnotationGrip.bottomRight: NormalizedPoint(rect.right, rect.bottom),
    },
    ArrowAnnotation(:final start, :final end) => {
      AnnotationGrip.start: start,
      AnnotationGrip.end: end,
    },
    FreehandAnnotation() => const {},
  };
}

/// The grip of [annotation] under [position], or null.
///
/// [position] and the grips are compared in *widget* space, because the
/// slop that decides a hit is a finger size — comparing in normalized
/// space would make handles harder to grab on a large image than a
/// small one.
///
/// Callers must consult this *before* hit-testing the shape itself: a
/// handle sits on the shape's edge, so without priority every corner
/// drag would move the shape instead of resizing it.
AnnotationGrip? gripAt(
  Annotation annotation,
  Offset position,
  Rect contentRect,
  ImageTransform transform, {
  double slopPixels = kHandleHitSlop,
}) {
  AnnotationGrip? best;
  var bestDistance = double.infinity;

  gripsOf(annotation).forEach((grip, point) {
    final mapped = transform.mapPoint(point);
    final at = Offset(
      contentRect.left + mapped.x * contentRect.width,
      contentRect.top + mapped.y * contentRect.height,
    );
    final distance = (position - at).distance;
    // Nearest wins, so overlapping handles on a small shape still
    // resolve to one deterministically rather than by declaration order.
    if (distance <= slopPixels && distance < bestDistance) {
      best = grip;
      bestDistance = distance;
    }
  });

  return best;
}

/// Returns [annotation] with [grip] moved to [point], or null if the
/// result would be degenerate.
///
/// Returning null rather than clamping to a minimum keeps the caller's
/// options open: dragging a corner past its opposite is a no-op here
/// instead of silently pinning the shape to an arbitrary floor.
Annotation? resizeAnnotation(
  Annotation annotation,
  AnnotationGrip grip,
  NormalizedPoint point, {
  double minimumExtent = 0.01,
}) {
  switch (annotation) {
    case RectangleAnnotation(:final rect):
      final resized = _resizeRect(rect, grip, point, minimumExtent);
      return resized == null ? null : annotation.copyWith(rect: resized);

    case CircleAnnotation(:final rect):
      final resized = _resizeRect(rect, grip, point, minimumExtent);
      return resized == null ? null : annotation.copyWith(rect: resized);

    case ArrowAnnotation():
      // Endpoints, so an arrow keeps its direction and can be reversed
      // by dragging one end past the other -- which is meaningful for a
      // shape whose whole point is which way it points.
      return switch (grip) {
        AnnotationGrip.start => annotation.copyWith(start: point),
        AnnotationGrip.end => annotation.copyWith(end: point),
        _ => null,
      };

    case FreehandAnnotation():
      return null;
  }
}

NormalizedRect? _resizeRect(
  NormalizedRect rect,
  AnnotationGrip grip,
  NormalizedPoint point,
  double minimum,
) {
  var left = rect.left;
  var top = rect.top;
  var right = rect.right;
  var bottom = rect.bottom;

  switch (grip) {
    case AnnotationGrip.topLeft:
      left = point.x;
      top = point.y;
    case AnnotationGrip.topRight:
      right = point.x;
      top = point.y;
    case AnnotationGrip.bottomLeft:
      left = point.x;
      bottom = point.y;
    case AnnotationGrip.bottomRight:
      right = point.x;
      bottom = point.y;
    case AnnotationGrip.start:
    case AnnotationGrip.end:
      return null;
  }

  // Refuse rather than clamp: a corner dragged past its opposite would
  // otherwise flip the rect inside out or pin it to an arbitrary size.
  if ((right - left).abs() < minimum) return null;
  if ((bottom - top).abs() < minimum) return null;

  return NormalizedRect(
    left: left,
    top: top,
    right: right,
    bottom: bottom,
  );
}
