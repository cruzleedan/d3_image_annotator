import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/painting.dart' show TextPainter, TextSpan, TextStyle, TextDirection;

import '../coordinates/normalized_point.dart';
import '../coordinates/normalized_rect.dart';
import '../geometry/image_transform.dart';
import 'annotation.dart';

/// Projects a normalized point through [transform] into widget/pixel
/// space.
///
/// Shared by `annotation_painter.dart` (drawing), `hit_testing.dart`
/// (rotation-aware hit-testing, WORK-0033), and floating shape controls
/// (WORK-0035) -- consolidated here from three near-identical private
/// copies, so there is one place this math can be gotten right or wrong,
/// not three that can silently drift apart.
Offset mapPointToPixels(
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

/// The pixel length `AnnotationStyle.strokeWidth`/`AnnotationStyle
/// .fontSize` are resolved against -- the whole image's shorter side as
/// currently displayed, not the visible [contentRect].
///
/// Those differ under crop: cropping shrinks the content rect, which
/// `contain` then scales back up to fill the viewport, so the rect's
/// shorter side barely changes while the content beneath it is
/// magnified. Dividing by the crop's extent undoes that magnification,
/// so a mark (or a piece of text) keeps its weight relative to the
/// picture -- the rule this package documents: annotations scale *with*
/// the image. Shared here rather than kept private to
/// `annotation_painter.dart` alone, since [textBoundsInPixels] needs the
/// exact same value to lay text out at the size it will actually be
/// drawn -- a hit box computed against a different font size than the
/// one painted would silently drift from what the user sees.
double shorterSidePixels(Rect contentRect, ImageTransform transform) {
  final crop = transform.effectiveCrop;
  final fullWidth = crop.width == 0
      ? contentRect.width
      : contentRect.width / crop.width;
  final fullHeight = crop.height == 0
      ? contentRect.height
      : contentRect.height / crop.height;
  return math.min(fullWidth, fullHeight);
}

/// Projects a normalized rect through [transform] into widget/pixel
/// space.
///
/// Built from the mapped corners rather than mapping width and height,
/// since a 90-degree rotation swaps the axes and would otherwise produce
/// a rect of the wrong shape. `Rect.fromPoints` re-normalises the corner
/// order, so a rotation that puts left past right still yields a valid
/// rect.
///
/// This is the *unrotated* mapped rect -- for a rotated
/// `RectangleAnnotation`/`CircleAnnotation`, callers that need the
/// visual (rotated) extent must rotate this result themselves, the same
/// way `annotation_painter.dart`'s `_drawRotated` does.
Rect mapRectToPixels(
  NormalizedRect rect,
  Rect contentRect,
  ImageTransform transform,
) {
  final a = mapPointToPixels(
    NormalizedPoint(rect.left, rect.top),
    contentRect,
    transform,
  );
  final b = mapPointToPixels(
    NormalizedPoint(rect.right, rect.bottom),
    contentRect,
    transform,
  );
  return Rect.fromPoints(a, b);
}

/// The exact, unrotated on-screen box [text] occupies in pixel space,
/// via a real `TextPainter` layout pass at the font size it will
/// actually be drawn at.
///
/// **This is [TextAnnotation]'s real `bounds`** -- its own
/// `bounds` getter (in `annotation.dart`) can only offer a coarse
/// per-character estimate, since a zero-argument getter has no way to
/// know [contentRect]/[transform], which is what [shorterSidePixels]
/// (and therefore the resolved pixel font size) actually depends on.
/// Every real consumer of a text annotation's on-screen box --
/// `annotation_painter.dart`'s drawing, `hit_testing.dart`'s precise hit
/// test, this file's own handle/floating-control placement -- calls
/// this instead of routing through the coarse estimate.
///
/// Anchored at [TextAnnotation.position] as the top-left corner, mapped
/// through [transform] the same way every other point is, then sized by
/// laying the text out at its *unrotated* size -- callers that need the
/// rotated on-screen box apply [rotatedCorners] to the result themselves,
/// the same pattern `mapRectToPixels` already establishes for
/// rectangles/circles.
Rect textBoundsInPixels(
  TextAnnotation text,
  Rect contentRect,
  ImageTransform transform,
) {
  final fontSizePixels = text.style.resolveFontSize(
    shorterSidePixels(contentRect, transform),
  );
  final painter = TextPainter(
    text: TextSpan(
      text: text.text,
      style: TextStyle(
        color: text.style.color,
        fontSize: fontSizePixels,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  final topLeft = mapPointToPixels(text.position, contentRect, transform);
  return topLeft & painter.size;
}

/// The four corners of [mapped] (an unrotated, already-mapped pixel-space
/// rect) after rotating [rotationRadians] about its own centre, in
/// on-screen order: top-left, top-right, bottom-right, bottom-left
/// *as drawn*, which is a different physical corner from the unrotated
/// labelling once rotated past a quarter turn.
///
/// The same rotation `annotation_painter.dart`'s `_drawRotated` applies
/// via a canvas transform, but returned as points rather than left
/// inside a transformed coordinate system -- needed anywhere that draws
/// or hit-tests against the shape's actual on-screen outline directly
/// (a dashed selection border, a floating control's anchor point) rather
/// than drawing *through* a rotated canvas the way the shape's own fill
/// is painted.
List<Offset> rotatedCorners(Rect mapped, double rotationRadians) {
  final center = mapped.center;
  final corners = [
    mapped.topLeft,
    mapped.topRight,
    mapped.bottomRight,
    mapped.bottomLeft,
  ];
  if (rotationRadians == 0.0) return corners;

  final cosA = math.cos(rotationRadians);
  final sinA = math.sin(rotationRadians);
  return [
    for (final corner in corners)
      _rotateAround(corner, center, cosA, sinA),
  ];
}

Offset _rotateAround(Offset point, Offset center, double cosA, double sinA) {
  final dx = point.dx - center.dx;
  final dy = point.dy - center.dy;
  return Offset(
    center.dx + dx * cosA - dy * sinA,
    center.dy + dx * sinA + dy * cosA,
  );
}

/// Fixed pixel distance the floating delete/duplicate controls sit
/// beyond the shape's own corners (WORK-0035), along the centre-to-corner
/// diagonal -- the same technique and distance as [kRotationHandleOffset],
/// so all three floating controls read as one consistent family of
/// "just outside the corners" handles.
const double kFloatingControlOffset = 28;

/// Where the floating delete (×) and duplicate (+1) controls anchor for
/// [annotation], in pixel space -- always `[delete, duplicate]`.
///
/// **× sits outside the top-left corner; +1 sits outside the
/// bottom-left corner** -- deliberately the two corners the rotation
/// handle (outside bottom-right, [gripPositionsInPixels]) does not use,
/// so all three floating controls (delete, duplicate, rotate) occupy
/// three distinct corners of the shape with no overlap, at any rotation.
/// The fourth corner (top-right) is left for the two ordinary resize
/// handles there to have room of their own.
///
/// Each anchor is offset straight out along its own centre-to-corner
/// diagonal -- the same rigid-with-the-shape direction
/// [gripPositionsInPixels] already uses for the rotation handle, so a
/// rotated shape's controls swing around with it rather than staying
/// screen-axis-aligned and drifting away from "outside that corner".
///
/// An arrow or freehand stroke has no `rotation`, so this is simply
/// outside its (unrotated) corners -- still correct, since
/// [rotatedCorners] is a no-op at `rotation == 0.0`.
List<Offset> floatingControlAnchors(
  Annotation annotation,
  Rect contentRect,
  ImageTransform transform,
) {
  final mapped = annotation is TextAnnotation
      ? textBoundsInPixels(annotation, contentRect, transform)
      : mapRectToPixels(annotation.bounds, contentRect, transform);
  final corners = rotatedCorners(mapped, rotationOf(annotation));
  final topLeft = corners[0];
  final bottomLeft = corners[3];
  // Rotation is applied about the rect's own centre, so the centre
  // itself never moves -- no need to recompute it from the rotated
  // corners.
  final center = mapped.center;

  Offset anchorFor(Offset corner, Offset fallbackDirection) {
    final outward = corner - center;
    final length = outward.distance;
    final direction = length < 1e-9 ? fallbackDirection : outward / length;
    return corner + direction * kFloatingControlOffset;
  }

  return [
    anchorFor(topLeft, const Offset(-1, -1)),
    anchorFor(bottomLeft, const Offset(-1, 1)),
  ];
}

/// The point on [annotation]'s *unrotated* shape that [pixelPosition]
/// corresponds to, given it landed on the shape as actually drawn
/// (rotated by [rotationOf]).
///
/// Used by hit-testing (WORK-0033) to turn a tap on a rotated shape's
/// visual outline into "the equivalent position if this shape had no
/// rotation applied", then hand that to `hitTest`, written without
/// rotation in mind at all. **Not used for corner-drag resize** --
/// [resizeRotatedAnnotation] is that counterpart instead (see its own
/// doc comment for why this function alone is the wrong tool for that
/// job: it inverse-rotates around the shape's *current* centre,
/// which is exactly the point that a resize is about to move).
///
/// **Must work in pixel space, not normalized space, for the same
/// reason `_drawRotated` in `annotation_painter.dart` does** --
/// `ImageTransform.mapPoint`'s crop step scales x and y independently,
/// so inverse-rotating before that mapping would distort the angle
/// under a non-square crop. This inverse-rotates the pixel position
/// around the shape's mapped centre, the mirror image of how the
/// painter rotates the shape itself, then un-maps the result back
/// through the normal pipeline.
NormalizedPoint unrotatedEquivalentPoint(
  Annotation annotation,
  Offset pixelPosition,
  Rect contentRect,
  ImageTransform transform,
) {
  final rotation = rotationOf(annotation);
  if (rotation == 0.0) {
    return _toOriginalSpace(pixelPosition, contentRect, transform);
  }

  final center = (annotation is TextAnnotation
          ? textBoundsInPixels(annotation, contentRect, transform)
          : mapRectToPixels(annotation.bounds, contentRect, transform))
      .center;
  final dx = pixelPosition.dx - center.dx;
  final dy = pixelPosition.dy - center.dy;
  final cosA = math.cos(-rotation);
  final sinA = math.sin(-rotation);
  final localPixel = Offset(
    center.dx + dx * cosA - dy * sinA,
    center.dy + dx * sinA + dy * cosA,
  );
  return _toOriginalSpace(localPixel, contentRect, transform);
}

/// [grip]'s diagonally-opposite corner -- the corner a corner-drag on
/// [grip] must keep visually fixed on screen (WORK-0035's decision,
/// fixed for rotated shapes as a follow-up: dragging one corner must
/// anchor the opposite one, not drift every corner outward together).
/// Returns null for a grip that has no rect-corner opposite
/// ([AnnotationGrip.start]/[AnnotationGrip.end]/[AnnotationGrip.rotate]).
AnnotationGrip? _oppositeCornerGrip(AnnotationGrip grip) => switch (grip) {
  AnnotationGrip.topLeft => AnnotationGrip.bottomRight,
  AnnotationGrip.topRight => AnnotationGrip.bottomLeft,
  AnnotationGrip.bottomLeft => AnnotationGrip.topRight,
  AnnotationGrip.bottomRight => AnnotationGrip.topLeft,
  AnnotationGrip.start || AnnotationGrip.end || AnnotationGrip.rotate => null,
};

/// Resizes [annotation]'s rect from a corner-drag on [grip] to
/// [pixelPosition], keeping the diagonally-opposite corner fixed on
/// screen -- the rotation-aware counterpart to plain [resizeAnnotation],
/// for a type whose `bounds`/`rect` this applies to (rectangle, circle,
/// image). Returns null if the result would be degenerate, same
/// contract as [resizeAnnotation].
///
/// **Why this returns a whole rect, not a point fed through
/// [resizeAnnotation].** An earlier version of this fix tried inverse
/// -rotating only the dragged corner and handing that single point to
/// the existing, rotation-oblivious `_resizeRect` -- which only
/// overwrites the two coordinates for the dragged corner and leaves the
/// *other* two exactly as they were. That is wrong once rotation is
/// involved: resizing one corner while keeping the opposite corner's
/// on-screen position fixed necessarily moves the rect's centre (the
/// midpoint of the two corners), and every corner's *unrotated* local
/// coordinates are measured relative to that centre. Moving the centre
/// without recomputing every corner leaves the two untouched corners
/// silently stale -- confirmed by a failing test before this was
/// corrected, not assumed safe from the geometry alone. So this
/// function computes the complete new rect directly instead of routing
/// through `_resizeRect` for the rotated case.
///
/// **The math.** For any two opposite corners of a rectangle, the
/// midpoint between them is the centre, rotated or not -- rotating a
/// rectangle about its own centre keeps that true. So: take the
/// opposite corner's current on-screen (already-rotated) position as a
/// fixed pivot, use [pixelPosition] (where the finger actually is,
/// already in on-screen/world space) as the other end of the new
/// diagonal, and the new centre is simply their midpoint. Inverse
/// -rotating *both* points around that new centre recovers the new
/// unrotated rect's two corners exactly -- the anchor corner maps back
/// to its own unrotated position unchanged, and the dragged corner maps
/// to wherever the drag point resolves to. The found-on-device symptom
/// this fixes: dragging one corner of a rotated shape visibly moved
/// every corner, as if anchored at nothing -- confirmed numerically (a
/// 30° rotated square resized from one corner shifted its opposite
/// corner by dozens of pixels that should have stayed put) before
/// writing this fix, not assumed from the bug report alone.
Annotation? resizeRotatedAnnotation(
  Annotation annotation,
  AnnotationGrip grip,
  Offset pixelPosition,
  Rect contentRect,
  ImageTransform transform, {
  double minimumExtent = 0.01,
}) {
  final rotation = rotationOf(annotation);
  if (rotation == 0.0) {
    final point = _toOriginalSpace(pixelPosition, contentRect, transform);
    return resizeAnnotation(annotation, grip, point, minimumExtent: minimumExtent);
  }

  final opposite = _oppositeCornerGrip(grip);
  if (opposite == null) return null;

  final positions = gripPositionsInPixels(annotation, contentRect, transform);
  final anchorWorld = positions[opposite]!;
  final newCenter = Offset(
    (anchorWorld.dx + pixelPosition.dx) / 2,
    (anchorWorld.dy + pixelPosition.dy) / 2,
  );

  Offset inverseRotate(Offset point) {
    final dx = point.dx - newCenter.dx;
    final dy = point.dy - newCenter.dy;
    final cosA = math.cos(-rotation);
    final sinA = math.sin(-rotation);
    return Offset(
      newCenter.dx + dx * cosA - dy * sinA,
      newCenter.dy + dx * sinA + dy * cosA,
    );
  }

  final anchorLocal = _toOriginalSpace(
    inverseRotate(anchorWorld),
    contentRect,
    transform,
  );
  final draggedLocal = _toOriginalSpace(
    inverseRotate(pixelPosition),
    contentRect,
    transform,
  );

  // anchorLocal and draggedLocal are the new rect's two corners --
  // which one is which axis depends on which grip was dragged (e.g.
  // dragging bottomRight means anchor=topLeft, dragged=bottomRight, so
  // anchorLocal supplies left/top and draggedLocal supplies
  // right/bottom -- NormalizedRect.fromCorners re-normalises regardless
  // of which corner ends up numerically smaller).
  final left = math.min(anchorLocal.x, draggedLocal.x);
  final top = math.min(anchorLocal.y, draggedLocal.y);
  final right = math.max(anchorLocal.x, draggedLocal.x);
  final bottom = math.max(anchorLocal.y, draggedLocal.y);

  if ((right - left) < minimumExtent || (bottom - top) < minimumExtent) {
    return null;
  }

  final newRect = NormalizedRect(left: left, top: top, right: right, bottom: bottom);

  return switch (annotation) {
    RectangleAnnotation() => annotation.copyWith(rect: newRect),
    CircleAnnotation() => annotation.copyWith(rect: newRect),
    ImageAnnotation() => annotation.copyWith(rect: newRect),
    TextAnnotation() || ArrowAnnotation() || FreehandAnnotation() => null,
  };
}

/// The inverse of [mapPointToPixels] followed by
/// [ImageTransform.unmapPoint] -- pixel space back to the original,
/// pre-transform normalized space geometry logic (`hitTest`,
/// `_resizeRect`) operates in.
NormalizedPoint _toOriginalSpace(
  Offset pixel,
  Rect contentRect,
  ImageTransform transform,
) {
  final x = contentRect.width == 0
      ? 0.0
      : (pixel.dx - contentRect.left) / contentRect.width;
  final y = contentRect.height == 0
      ? 0.0
      : (pixel.dy - contentRect.top) / contentRect.height;
  if (transform.isIdentity) {
    return NormalizedPoint(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));
  }
  return transform.unmapPoint(x, y);
}

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

/// Drawn radius of the rotation handle specifically -- larger than
/// [kHandleRadius] so its rotate glyph (see `annotation_painter.dart`'s
/// `_paintRotateGlyph`) is actually legible, not just a bigger plain
/// dot. A colour-only difference from the resize handles was found
/// on-device not to read clearly enough as "this one does something
/// different" (WORK-0035/0037 follow-up).
const double kRotationHandleRadius = 11;

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

  /// Changes a rectangle's or circle's `rotation` only, leaving its
  /// `rect` untouched (WORK-0035). A dedicated grip rather than folding
  /// this into a corner: a single handle doing both needs a precise,
  /// untested boundary between "close enough to rotate" and "on the
  /// corner to resize", which this package has a documented history of
  /// getting wrong (WORK-0025).
  rotate,
}

/// The grips [annotation] offers, in *original image* space.
///
/// Freehand strokes offer none: scaling a sampled path is a different
/// operation from dragging a corner, and naive per-point scaling
/// distorts the stroke. They can still be moved and deleted.
///
/// Text also returns none here, for a different reason: its corners are
/// only knowable in pixel space (a `TextPainter` layout pass, via
/// [textBoundsInPixels]), not this normalized-space contract --
/// [gripPositionsInPixels] computes text's actual grip positions
/// directly rather than through this function at all. This still
/// returns an empty map, not an error, so a caller checking "does this
/// have grips" through [gripsOf] alone gets a coherent (if incomplete)
/// answer rather than an exception.
Map<AnnotationGrip, NormalizedPoint> gripsOf(Annotation annotation) {
  return switch (annotation) {
    RectangleAnnotation(:final rect) ||
    CircleAnnotation(:final rect) ||
    ImageAnnotation(:final rect) => {
      AnnotationGrip.topLeft: NormalizedPoint(rect.left, rect.top),
      AnnotationGrip.topRight: NormalizedPoint(rect.right, rect.top),
      AnnotationGrip.bottomLeft: NormalizedPoint(rect.left, rect.bottom),
      AnnotationGrip.bottomRight: NormalizedPoint(rect.right, rect.bottom),
    },
    ArrowAnnotation(:final start, :final end) => {
      AnnotationGrip.start: start,
      AnnotationGrip.end: end,
    },
    FreehandAnnotation() || TextAnnotation() => const {},
  };
}

/// Fixed pixel distance the rotation handle sits outside the shape's
/// top-right corner, along the shape's own rotated axis.
///
/// Pixels, not normalized units, for the same reason [kHandleHitSlop]
/// is: a comfortable reach-outside-the-corner distance for a finger
/// does not change with the image's resolution.
const double kRotationHandleOffset = 28;

/// Where each of [annotation]'s grips actually renders on screen, in
/// *pixel* space -- the single source of truth [gripAt] and the painter
/// both consult, so a handle is never drawn somewhere other than where
/// it hit-tests.
///
/// For an unrotated shape this is just [gripsOf] mapped through
/// [transform]. For a rotated rectangle or circle, [gripsOf]'s corners
/// (the shape's *unrotated* stored corners) are rotated about the
/// mapped centre by [rotationOf] first -- the same pixel-space rotation
/// `_drawRotated` in `annotation_painter.dart` applies when actually
/// drawing the shape, so a handle always sits on the shape's true,
/// on-screen corner rather than the unrotated one WORK-0033 left this
/// as a gap (see WORK-0035's decision).
///
/// Rectangles and circles additionally offer [AnnotationGrip.rotate], a
/// fifth point placed [kRotationHandleOffset] pixels beyond the
/// bottom-right corner, continuing straight out along the centre-to-corner
/// diagonal -- a direction that rotates rigidly with the shape, so the
/// handle stays anchored to "outside that corner" at any angle rather
/// than drifting once the shape turns. Bottom-right specifically so it
/// stays clear of the floating delete/duplicate controls, which anchor
/// to the left side (WORK-0035's revised layout).
Map<AnnotationGrip, Offset> gripPositionsInPixels(
  Annotation annotation,
  Rect contentRect,
  ImageTransform transform,
) {
  // Text's real on-screen box only exists in pixel space (a
  // TextPainter layout pass) -- annotation.bounds is only ever a coarse
  // normalized estimate for this type (see TextAnnotation.bounds), so
  // corners are computed from textBoundsInPixels directly rather than
  // through gripsOf/mapRectToPixels the way every stored-rect type is.
  final Map<AnnotationGrip, Offset> mapped;
  final Offset center;
  if (annotation is TextAnnotation) {
    final box = textBoundsInPixels(annotation, contentRect, transform);
    mapped = {
      AnnotationGrip.topLeft: box.topLeft,
      AnnotationGrip.topRight: box.topRight,
      AnnotationGrip.bottomLeft: box.bottomLeft,
      AnnotationGrip.bottomRight: box.bottomRight,
    };
    center = box.center;
  } else {
    final grips = gripsOf(annotation);
    mapped = {
      for (final entry in grips.entries)
        entry.key: mapPointToPixels(entry.value, contentRect, transform),
    };
    center = mapRectToPixels(annotation.bounds, contentRect, transform).center;
  }

  final rotation = rotationOf(annotation);

  final positioned = rotation == 0.0
      ? mapped
      : {
          for (final entry in mapped.entries)
            entry.key: _rotateAround(
              entry.value,
              center,
              math.cos(rotation),
              math.sin(rotation),
            ),
        };

  final bottomRight = positioned[AnnotationGrip.bottomRight];
  if (bottomRight != null) {
    final outward = bottomRight - center;
    final length = outward.distance;
    final direction = length < 1e-9 ? const Offset(0, 1) : outward / length;
    positioned[AnnotationGrip.rotate] =
        bottomRight + direction * kRotationHandleOffset;
  }

  return positioned;
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

  gripPositionsInPixels(annotation, contentRect, transform).forEach((grip, at) {
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
///
/// **For an unrotated shape only.** [point] is applied directly as
/// [annotation]'s own (unrotated) coordinate space -- correct as-is when
/// `rotationOf(annotation) == 0.0`. For a *rotated* rectangle, circle,
/// or image, a caller must use [resizeRotatedAnnotation] instead, not
/// this function with a pre-computed point: resizing one corner of a
/// rotated shape while keeping the opposite corner fixed on screen
/// requires recomputing every corner (the shape's centre moves), which
/// this function's "only touch the dragged corner" contract cannot
/// express (WORK-0035, corrected as a follow-up after a real bug: an
/// earlier version tried exactly that and every corner drifted).
/// [AnnotationGrip.rotate] is not handled here at all -- see
/// [rotateAnnotation].
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

    case ImageAnnotation(:final rect):
      // Corner-drag changes only the placement rect, stretching or
      // shrinking the displayed image to fit -- the image's own
      // internal crop/mirror is a separate action via dedicated
      // controls, not a second meaning on this same gesture (WORK-0037).
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

    case TextAnnotation():
      // Text has no draggable corner-resize: its extent follows from
      // its content and `AnnotationStyle.fontSize`, not a dragged rect,
      // so there is nothing for a corner grip to do (text offers none
      // via `gripsOf` in the first place -- this case exists only to
      // keep the switch exhaustive).
      return null;
  }
}

/// Returns [annotation] with its `rotation` set so that its (rotated)
/// bottom-right corner points at [pixelPosition], or null for a type
/// that has no rotation.
///
/// Deliberately separate from [resizeAnnotation]: dragging
/// [AnnotationGrip.rotate] must change *only* `rotation`, leaving
/// `rect`'s `left`/`top`/`right`/`bottom` untouched (WORK-0035) -- a
/// shape does not change size because it turned.
///
/// Works entirely in pixel space, comparing the drag against the
/// shape's mapped (unrotated) centre and its unrotated bottom-right
/// corner, then taking the angle *between* them -- this stays correct
/// under an anisotropic crop for the same reason every other rotation
/// computation in this package does: an angle is only meaningful once
/// both points it is measured between have already been mapped through
/// the same (possibly anisotropic) pipeline.
Annotation? rotateAnnotation(
  Annotation annotation,
  Offset pixelPosition,
  Rect contentRect,
  ImageTransform transform,
) {
  // Text's unrotated box only exists in pixel space -- see
  // gripPositionsInPixels for the same reasoning.
  final mappedRect = annotation is TextAnnotation
      ? textBoundsInPixels(annotation, contentRect, transform)
      : mapRectToPixels(annotation.bounds, contentRect, transform);
  final center = mappedRect.center;
  final unrotatedCorner = mappedRect.bottomRight;

  final baseAngle = math.atan2(
    unrotatedCorner.dy - center.dy,
    unrotatedCorner.dx - center.dx,
  );
  final dragAngle = math.atan2(
    pixelPosition.dy - center.dy,
    pixelPosition.dx - center.dx,
  );
  final rotation = dragAngle - baseAngle;

  return switch (annotation) {
    RectangleAnnotation() => annotation.copyWith(rotation: rotation),
    CircleAnnotation() => annotation.copyWith(rotation: rotation),
    TextAnnotation() => annotation.copyWith(rotation: rotation),
    ImageAnnotation() => annotation.copyWith(rotation: rotation),
    ArrowAnnotation() || FreehandAnnotation() => null,
  };
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
    case AnnotationGrip.rotate:
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
