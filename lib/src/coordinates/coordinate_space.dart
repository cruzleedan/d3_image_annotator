import 'dart:ui' show Offset, Rect;

import 'normalized_point.dart';

/// Conversions between widget-pixel space and normalized `[0,1]`
/// image space.
///
/// Annotations are persisted *only* in normalized image space, because
/// that is the one form invariant under everything that differs between
/// drawing an annotation and exporting it: widget size, fit mode
/// (letterbox vs. crop), image resolution, EXIF rotation, and mirroring.
/// Storing widget pixels instead is the drift bug this package's design
/// exists to prevent -- see SPIKE-0005.
///
/// [contentRect] is where the image content actually sits inside the
/// widget, which is *not* the widget's own bounds whenever the two
/// aspect ratios differ. Get it from `computeImageContentRect` rather
/// than computing it again here: sharing that one function is what
/// guarantees the overlay and the image agree on where content is.

/// Converts a pointer position in widget coordinates to normalized
/// image space.
///
/// Points outside [contentRect] are clamped to its edges. A drag that
/// leaves the image cannot produce a meaningful normalized coordinate --
/// there is no image there -- and clamping keeps a freehand stroke
/// running off the edge as a stroke along the edge, which is what a
/// user drawing past the boundary means. The alternative, widening
/// [NormalizedPoint]'s `[0,1]` invariant to admit out-of-range values,
/// was rejected: that invariant is what makes every downstream
/// consumer (painter, hit-testing, export) safe to write without
/// range checks of its own.
NormalizedPoint toNormalized(Offset widgetPoint, Rect contentRect) {
  if (contentRect.width <= 0 || contentRect.height <= 0) {
    return const NormalizedPoint(0, 0);
  }
  final x = (widgetPoint.dx - contentRect.left) / contentRect.width;
  final y = (widgetPoint.dy - contentRect.top) / contentRect.height;
  return NormalizedPoint(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));
}

/// Converts a normalized image-space point back to widget coordinates.
///
/// The exact inverse of [toNormalized] for any point that was inside
/// [contentRect] to begin with; a clamped point maps back to the edge it
/// was clamped to, not to where the pointer actually was.
Offset fromNormalized(NormalizedPoint point, Rect contentRect) {
  return Offset(
    contentRect.left + point.x * contentRect.width,
    contentRect.top + point.y * contentRect.height,
  );
}

/// Scales a distance expressed in widget pixels into normalized units
/// along each axis.
///
/// Hit-test tolerance has to start life in widget pixels: "within 20
/// logical pixels of the line" means the same thing to a user on every
/// screen, whereas a fixed normalized tolerance would be a different
/// physical distance on every image size. The two axes scale
/// independently because [contentRect] is generally not square.
({double x, double y}) normalizedTolerance(
  double widgetPixels,
  Rect contentRect,
) {
  if (contentRect.width <= 0 || contentRect.height <= 0) {
    return (x: 0, y: 0);
  }
  return (
    x: widgetPixels / contentRect.width,
    y: widgetPixels / contentRect.height,
  );
}
