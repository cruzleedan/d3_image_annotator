import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../geometry/image_transform.dart';
import '../geometry/transformed_image_paint.dart';
import 'annotation.dart';
import 'annotation_handles.dart';
import 'annotation_style.dart';
import 'image_annotation_cache.dart';

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
  ImageAnnotationCache? imageCache,
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

  // Stroke width (and font size) is a fraction of the *whole image* as
  // currently displayed, not of the visible content rect -- see
  // shorterSidePixels for why.
  final shorterSide = shorterSidePixels(contentRect, transform);

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
      case RectangleAnnotation(:final rect, :final rotation):
        _drawRotated(
          canvas,
          mapRectToPixels(rect, contentRect, transform),
          rotation,
          (r) => canvas.drawRect(r, paint),
        );
      case CircleAnnotation(:final rect, :final rotation):
        _drawRotated(
          canvas,
          mapRectToPixels(rect, contentRect, transform),
          rotation,
          (r) => canvas.drawOval(r, paint),
        );
      case ArrowAnnotation(:final start, :final end):
        _paintArrow(
          canvas,
          mapPointToPixels(start, contentRect, transform),
          mapPointToPixels(end, contentRect, transform),
          paint,
        );
      case FreehandAnnotation(:final points):
        _paintFreehand(
          canvas,
          [
            for (final p in points) mapPointToPixels(p, contentRect, transform),
          ],
          paint,
        );
      case TextAnnotation(:final rotation):
        _drawRotated(
          canvas,
          textBoundsInPixels(annotation, contentRect, transform),
          rotation,
          (r) => _paintText(canvas, annotation, r, shorterSide),
        );
      case ImageAnnotation(:final rect, :final rotation):
        _drawRotated(
          canvas,
          mapRectToPixels(rect, contentRect, transform),
          rotation,
          (r) => _paintImage(canvas, annotation, r, imageCache),
        );
    }

    if (annotation.id == selectedId) {
      final selectionBounds = annotation is TextAnnotation
          ? textBoundsInPixels(annotation, contentRect, transform)
          : mapRectToPixels(annotation.bounds, contentRect, transform);
      _paintSelection(
        canvas,
        selectionBounds,
        rotationOf(annotation),
        paint,
      );
      _paintHandles(canvas, annotation, contentRect, transform);
    }
  }

  if (transform.cropRect != null) canvas.restore();
}

/// Draws [mapped] via [draw], rotated by [rotationRadians] about its own
/// centre (WORK-0033).
///
/// **Rotation happens here, in already-mapped pixel space -- never
/// applied to the normalized rect before mapping.** An earlier version
/// of this design rotated the shape's corners in normalized space and
/// let the existing crop/mirror/quarterTurn pipeline carry them
/// through, on the reasoning that it already handles every other
/// coordinate that way. That is wrong whenever a crop keeps a
/// non-square region: `ImageTransform.mapPoint`'s crop step scales x
/// and y independently, so a 45° rotation applied beforehand can come
/// out as a visually different angle after an anisotropic crop --
/// confirmed numerically (45° measured as 26.57° after a 2:1-aspect
/// crop) before this was written, not assumed safe. The mapping from
/// `mapPoint`'s output to widget pixels is isotropic by construction
/// (`contentRect`'s aspect always matches `ImageTransform.resultSize`'s
/// -- what already makes the unrotated case correct), so rotating after
/// that mapping, not before it, is the one place in the pipeline where
/// applying an angle cannot be distorted by crop.
void _drawRotated(
  Canvas canvas,
  Rect mapped,
  double rotationRadians,
  void Function(Rect) draw,
) {
  if (rotationRadians == 0.0) {
    draw(mapped);
    return;
  }
  final center = mapped.center;
  canvas.save();
  canvas.translate(center.dx, center.dy);
  canvas.rotate(rotationRadians);
  draw(Rect.fromCenter(
    center: Offset.zero,
    width: mapped.width,
    height: mapped.height,
  ));
  canvas.restore();
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

/// Draws [text] into [bounds] -- already the exact box a `TextPainter`
/// layout pass measured it to (via `textBoundsInPixels`), so this only
/// paints, it does not lay out a second time with different metrics
/// that could drift from what [bounds] itself was measured against.
///
/// **Rasterized here, on the root isolate, before any compositing
/// finishes** (WORK-0034's rendering decision): `PictureRecorder` is
/// root-isolate-only regardless of annotation type (documented in
/// `render_annotated_image.dart`), which is exactly where the root
/// isolate's already-loaded fonts resolve normally. By the time
/// `renderCompositedImage`'s background-isolate PNG encode path
/// (WORK-0030) ever sees a pixel buffer, this text is already baked
/// into it as ordinary RGBA -- the encode worker needs no font access
/// at all, for text or any other annotation type, because painting
/// (this function) always happens first, unconditionally, on the
/// isolate where fonts already work.
void _paintText(
  Canvas canvas,
  TextAnnotation text,
  Rect bounds,
  double shorterSidePixels,
) {
  // The exact same font-size resolution `textBoundsInPixels` used to
  // measure [bounds] -- painting at any other size here would drift
  // from the box the rest of the pipeline (hit-testing, handles,
  // selection outline) already agreed this text occupies.
  final fontSizePixels = text.style.resolveFontSize(shorterSidePixels);
  // [bounds] already includes the textfield-like padding
  // `textBoundsInPixels` adds around the glyphs -- a border/background
  // drawn at [bounds] itself sits at that outer, padded edge, and the
  // glyphs below are inset back in by the same amount so they land
  // exactly where they were measured, not flush against the border.
  final padding = textBoxPaddingInPixels(fontSizePixels);

  if (text.style.backgroundColor case final bg?) {
    _drawTextBoxShape(
      canvas,
      bounds,
      text.style,
      shorterSidePixels,
      Paint()..color = bg,
    );
  }

  final borderWidthPixels = text.style.resolveBorderWidth(shorterSidePixels);
  if (borderWidthPixels > 0) {
    final borderPaint = Paint()
      ..color = text.style.color
      ..strokeWidth = borderWidthPixels
      ..style = PaintingStyle.stroke;
    // Inset by half the stroke width, the same convention every other
    // stroked shape in this package follows, so the border's outer
    // edge -- not its centreline -- lands exactly on [bounds], matching
    // the selection outline drawn around the same rect.
    _drawTextBoxShape(
      canvas,
      bounds.deflate(borderWidthPixels / 2),
      text.style,
      shorterSidePixels,
      borderPaint,
    );
  }

  final painter = TextPainter(
    text: TextSpan(
      text: text.text,
      style: TextStyle(color: text.style.color, fontSize: fontSizePixels),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, bounds.topLeft + Offset(padding, padding));
}

/// Draws [bounds] as a plain rect, or a rounded one when
/// [AnnotationStyle.borderRadius] is set -- shared by the background
/// fill and the border outline so the two always agree on the box's
/// shape.
void _drawTextBoxShape(
  Canvas canvas,
  Rect bounds,
  AnnotationStyle style,
  double shorterSidePixels,
  Paint paint,
) {
  final radius = style.resolveBorderRadius(shorterSidePixels);
  if (radius <= 0) {
    canvas.drawRect(bounds, paint);
  } else {
    canvas.drawRRect(RRect.fromRectAndRadius(bounds, Radius.circular(radius)), paint);
  }
}

/// Draws [annotation]'s decoded image into [bounds] via its own
/// [ImageAnnotation.imageTransform], or a neutral placeholder while
/// undecoded/failed (WORK-0037).
///
/// `paintAnnotations` only ever *reads* from [cache] -- it never calls
/// `request` itself, since paint cannot await a decode. Placing or
/// loading an `ImageAnnotation` is what triggers that (see
/// `AnnotationController.add`/the constructor's initial-list loop);
/// this function paints whatever the cache currently holds, which may
/// be nothing at all if [cache] itself is null (a document with no
/// image annotations never needs one).
void _paintImage(
  Canvas canvas,
  ImageAnnotation annotation,
  Rect bounds,
  ImageAnnotationCache? cache,
) {
  final entry = cache?.entryFor(annotation.reference);
  final image = entry?.image;
  if (entry != null && entry.state == ImageAnnotationLoadState.ready && image != null) {
    drawTransformedImage(canvas, image, annotation.imageTransform, bounds);
    return;
  }

  // Undecoded or failed: a neutral filled placeholder with a loading
  // (or error) affordance -- never skipped entirely, so the annotation
  // stays visible (and, since hit-testing works from the placement rect
  // regardless of decode state, selectable) throughout.
  final failed = entry?.state == ImageAnnotationLoadState.failed;
  canvas.drawRect(
    bounds,
    Paint()..color = const Color(0xFF3A3A3C),
  );
  final icon = failed ? Icons.broken_image : Icons.image;
  final iconSize = math.min(bounds.width, bounds.height) * 0.4;
  final painter = TextPainter(
    text: TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        color: const Color(0xB3FFFFFF),
        fontSize: iconSize,
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(
    canvas,
    bounds.center - Offset(painter.width / 2, painter.height / 2),
  );
}

/// Draws a grab handle at each of the annotation's grips.
///
/// Handles are a constant *screen* size, unlike stroke width which
/// scales with the image. A handle is UI -- it has to stay finger-sized
/// however far the picture is zoomed -- whereas a stroke is part of the
/// picture. Both rules are deliberate; making either match the other
/// would be a regression.
void _paintHandles(
  Canvas canvas,
  Annotation annotation,
  Rect contentRect,
  ImageTransform transform,
) {
  final fill = Paint()..color = const Color(0xFFFFFFFF);
  final edge = Paint()
    ..color = const Color(0xDD000000)
    ..strokeWidth = 1.5
    ..style = PaintingStyle.stroke;
  // Distinct fill so the rotation handle reads as "does something
  // different" at a glance, not just another resize dot in a new spot
  // (WORK-0035).
  final rotateFill = Paint()..color = const Color(0xFF4A90D9);

  gripPositionsInPixels(annotation, contentRect, transform).forEach((
    grip,
    at,
  ) {
    if (grip == AnnotationGrip.rotate) {
      // Larger than a resize dot, and carries an actual rotate glyph
      // (not just a different fill colour) so it reads unambiguously as
      // "this one rotates" at a glance, distinct from the four plain
      // resize handles -- found necessary during on-device testing
      // (WORK-0035/0037): a colour-only difference on a small dot was
      // not enough to communicate a different function.
      canvas.drawCircle(at, kRotationHandleRadius, rotateFill);
      canvas.drawCircle(at, kRotationHandleRadius, edge);
      _paintRotateGlyph(canvas, at);
    } else {
      canvas.drawCircle(at, kHandleRadius, fill);
      canvas.drawCircle(at, kHandleRadius, edge);
    }
  });
}

/// Draws a small rotate/refresh icon centred at [center], sized to fit
/// inside a [kRotationHandleRadius] circle.
void _paintRotateGlyph(Canvas canvas, Offset center) {
  const icon = Icons.rotate_right;
  final painter = TextPainter(
    text: TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        color: const Color(0xFFFFFFFF),
        fontSize: kRotationHandleRadius * 1.3,
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, center - Offset(painter.width / 2, painter.height / 2));
}

void _paintSelection(
  Canvas canvas,
  Rect bounds,
  double rotationRadians,
  Paint source,
) {
  final handle = Paint()
    ..color = source.color.withValues(alpha: 0.9)
    ..strokeWidth = source.strokeWidth * 0.6
    ..style = PaintingStyle.stroke;

  final inflated = bounds.inflate(source.strokeWidth * 2);
  // Inflate first, in the shape's own unrotated frame, then rotate the
  // inflated corners -- inflating an already-rotated quadrilateral by a
  // uniform pixel amount is not the same shape as a rotated, uniformly
  // -inflated rectangle, and the latter is what "the outline sits a
  // constant distance outside the shape at every angle" actually means.
  final corners = rotatedCorners(inflated, rotationRadians);
  _paintDashedPolygon(canvas, corners, handle);
}

void _paintDashedPolygon(Canvas canvas, List<Offset> corners, Paint paint) {
  const dash = 8.0;
  const gap = 5.0;
  final path = Path()..addPolygon(corners, true);
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
  AnnotationPainter({
    required this.annotations,
    required this.contentRect,
    this.selectedId,
    this.transform = ImageTransform.identity,
    this.imageCache,
  }) : super(repaint: imageCache);

  final List<Annotation> annotations;
  final Rect contentRect;
  final String? selectedId;
  final ImageTransform transform;

  /// Decoded images for any `ImageAnnotation`s in [annotations]
  /// (WORK-0037). Passed as `CustomPainter`'s own `repaint` listenable,
  /// so a decode finishing (or failing) after this painter is built
  /// repaints automatically -- the painter itself never triggers a
  /// decode, only reads whatever the cache currently holds.
  final ImageAnnotationCache? imageCache;

  @override
  void paint(Canvas canvas, Size size) {
    paintAnnotations(
      canvas,
      contentRect,
      annotations,
      selectedId: selectedId,
      transform: transform,
      imageCache: imageCache,
    );
  }

  @override
  bool shouldRepaint(AnnotationPainter oldDelegate) {
    return oldDelegate.contentRect != contentRect ||
        oldDelegate.selectedId != selectedId ||
        oldDelegate.transform != transform ||
        oldDelegate.imageCache != imageCache ||
        !listEquals(oldDelegate.annotations, annotations);
  }
}
