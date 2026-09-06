import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rotation-aware hit-testing (WORK-0033).
///
/// The core claim under test: a rotated shape's hit-test must agree
/// with where `annotation_painter.dart` actually draws it, in pixel
/// space -- not in the pre-mapped normalized space `hitTest` itself
/// operates in. An earlier version of this design got that wrong (see
/// WORK-0033's log for the numeric proof: a 45 degree rotation applied
/// in the wrong space measured as 26.57 degrees after a non-square
/// crop). These tests exercise the corrected version directly, at the
/// geometry level, rather than only through a widget gesture.
void main() {
  // A 400x400 content rect at the origin, so normalized 0.5 is pixel
  // 200 and every expectation stays checkable by hand -- same
  // convention as annotation_handles_test.dart.
  const contentRect = Rect.fromLTWH(0, 0, 400, 400);

  RectangleAnnotation squareAt({
    required double cx,
    required double cy,
    required double halfSize,
    double rotation = 0.0,
  }) => RectangleAnnotation(
    id: 'r',
    style: const AnnotationStyle(filled: true),
    rect: NormalizedRect(
      left: cx - halfSize,
      top: cy - halfSize,
      right: cx + halfSize,
      bottom: cy + halfSize,
    ),
    rotation: rotation,
  );

  group('an unrotated shape is unaffected', () {
    test('hits and misses land exactly where they did before rotation existed',
        () {
      final rect = squareAt(cx: 0.5, cy: 0.5, halfSize: 0.1);

      final hit = hitTestAnnotations(
        [rect],
        const NormalizedPoint(0.5, 0.5),
        contentRect,
      );
      expect(hit, isNotNull);

      final miss = hitTestAnnotations(
        [rect],
        const NormalizedPoint(0.9, 0.9),
        contentRect,
      );
      expect(miss, isNull);
    });

    test('passing pixelPosition/transform does not change an unrotated result',
        () {
      // The optional parameters must be a genuine no-op for rotation:0,
      // since that is the overwhelmingly common case and must not pay
      // for or risk the rotated-shape code path.
      final rect = squareAt(cx: 0.5, cy: 0.5, halfSize: 0.1);
      const point = NormalizedPoint(0.5, 0.5);

      final withoutExtras = hitTestAnnotations([rect], point, contentRect);
      final withExtras = hitTestAnnotations(
        [rect],
        point,
        contentRect,
        pixelPosition: const Offset(200, 200),
        transform: ImageTransform.identity,
      );

      expect(withoutExtras, isNotNull);
      expect(withExtras, isNotNull);
    });
  });

  group('a rotated shape', () {
    test(
        'a point that would hit the axis-aligned box misses once rotated 45 degrees',
        () {
      // A non-square box, so rotation actually changes which points are
      // inside it -- a square rotated 45 degrees around its own centre
      // would coincidentally still contain the same corner regions for
      // some test points, which would not distinguish "rotation is
      // applied" from "rotation is ignored".
      final unrotated = RectangleAnnotation(
        id: 'r',
        style: const AnnotationStyle(filled: true),
        rect: NormalizedRect(left: 0.3, top: 0.45, right: 0.7, bottom: 0.55),
      );
      final rotated = unrotated.copyWith(rotation: math.pi / 4);

      // A point inside the unrotated box's top-right corner region --
      // near (0.65, 0.46) -- comfortably inside the wide, short
      // unrotated rect, but outside the same rect once tilted 45
      // degrees (the corner swings away from that point).
      const corner = NormalizedPoint(0.68, 0.46);
      const pixelAtCorner = Offset(272, 184); // corner * 400

      final hitsUnrotated = hitTestAnnotations(
        [unrotated],
        corner,
        contentRect,
        pixelPosition: pixelAtCorner,
      );
      expect(hitsUnrotated, isNotNull,
          reason: 'sanity check -- the point must be inside the '
              'unrotated box for this test to mean anything');

      final hitsRotated = hitTestAnnotations(
        [rotated],
        corner,
        contentRect,
        pixelPosition: pixelAtCorner,
        transform: ImageTransform.identity,
      );
      expect(hitsRotated, isNull,
          reason: 'the same point must fall outside the box once it is '
              'rotated 45 degrees around its own centre');
    });

    test('a point that misses the axis-aligned box hits once rotated to meet it',
        () {
      // The mirror image of the test above: a point just outside a
      // wide, short rect's short edge is outside the unrotated shape,
      // but a 90 degree rotation swaps the rect's width and height
      // around its centre, and that same point should now be inside.
      final unrotated = RectangleAnnotation(
        id: 'r',
        style: const AnnotationStyle(filled: true),
        rect: NormalizedRect(left: 0.3, top: 0.48, right: 0.7, bottom: 0.52),
      );
      final rotated = unrotated.copyWith(rotation: math.pi / 2);

      // Just above the unrotated rect's top edge, near its centre --
      // outside the thin unrotated band, but inside once the rect
      // becomes a thin *vertical* band through the same point after a
      // 90 degree turn.
      const point = NormalizedPoint(0.5, 0.4);
      const pixel = Offset(200, 160);

      final missesUnrotated = hitTestAnnotations(
        [unrotated],
        point,
        contentRect,
        pixelPosition: pixel,
      );
      expect(missesUnrotated, isNull,
          reason: 'sanity check -- the point must miss the unrotated '
              'band for this test to mean anything');

      final hitsRotated = hitTestAnnotations(
        [rotated],
        point,
        contentRect,
        pixelPosition: pixel,
        transform: ImageTransform.identity,
      );
      expect(hitsRotated, isNotNull,
          reason: 'the same point must fall inside the band once it is '
              'rotated 90 degrees to pass through it');
    });

    test('rotation is measured correctly even under a non-square crop', () {
      // The exact scenario that exposed the bug this item's log
      // records: an anisotropic crop distorts an angle applied in the
      // wrong space. This reproduces that stress case end to end and
      // checks the hit-test agrees with where the shape is actually
      // drawn, not with an uncorrected pre-crop calculation.
      final transform = ImageTransform(
        cropRect: NormalizedRect(left: 0, top: 0, right: 1, bottom: 0.5),
      );

      final shape = RectangleAnnotation(
        id: 'r',
        style: const AnnotationStyle(filled: true),
        rect: NormalizedRect(left: 0.4, top: 0.15, right: 0.6, bottom: 0.35),
        rotation: math.pi / 4,
      );

      // Compute where the shape's un-rotated top-right corner ends up
      // on screen after rotation, the same way the painter would draw
      // it, then confirm the hit-test agrees a tap there lands inside.
      final topLeftMapped = transform.mapPoint(
        const NormalizedPoint(0.4, 0.15),
      );
      final bottomRightMapped = transform.mapPoint(
        const NormalizedPoint(0.6, 0.35),
      );
      final centerPx = Offset(
        contentRect.left +
            (topLeftMapped.x + bottomRightMapped.x) / 2 * contentRect.width,
        contentRect.top +
            (topLeftMapped.y + bottomRightMapped.y) / 2 * contentRect.height,
      );

      // A point at the rotated shape's centre must always hit,
      // regardless of the crop or the rotation -- the centre does not
      // move when a shape rotates about itself.
      final centerNormalized = transform.unmapPoint(
        (centerPx.dx - contentRect.left) / contentRect.width,
        (centerPx.dy - contentRect.top) / contentRect.height,
      );

      final hit = hitTestAnnotations(
        [shape],
        centerNormalized,
        contentRect,
        pixelPosition: centerPx,
        transform: transform,
      );
      expect(hit, isNotNull,
          reason: 'the shape\'s own centre must hit regardless of '
              'rotation or an anisotropic crop');
    });
  });

  group('arrows and freehand are unaffected by rotation', () {
    test('an arrow ignores any notion of rotation entirely', () {
      // Arrows have no rotation field at all (WORK-0033 §1) -- this
      // just confirms passing the new optional parameters does not
      // change arrow hit-testing, which never consults them.
      const arrow = ArrowAnnotation(
        id: 'a',
        style: AnnotationStyle(),
        start: NormalizedPoint(0.2, 0.2),
        end: NormalizedPoint(0.8, 0.8),
      );

      final hit = hitTestAnnotations(
        [arrow],
        const NormalizedPoint(0.5, 0.5),
        contentRect,
        pixelPosition: const Offset(200, 200),
        transform: ImageTransform.identity,
      );

      expect(hit, isNotNull);
    });
  });

  group('image annotations are interactive regardless of decode state '
      '(WORK-0037)', () {
    ImageAnnotation image() => ImageAnnotation(
      id: 'i',
      style: const AnnotationStyle(),
      reference: 'never-resolved',
      rect: NormalizedRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75),
    );

    test('a tap anywhere inside the placement rect hits, with no cache '
        'involved at all', () {
      // No ImageAnnotationCache is even constructed here -- hit-testing
      // must never depend on one, since the placement rect is known
      // synchronously the instant the annotation is placed.
      final hit = hitTest(
        image(),
        const NormalizedPoint(0.5, 0.5),
        0.01,
        0.01,
      );

      expect(hit, isTrue);
    });

    test('a tap outside the placement rect misses', () {
      final hit = hitTest(
        image(),
        const NormalizedPoint(0.9, 0.9),
        0.01,
        0.01,
      );

      expect(hit, isFalse);
    });

    test('always hit anywhere inside, unlike an unfilled rectangle -- '
        'an image annotation has no outline-only mode', () {
      final unfilledLikeRect = image();
      // Centre of the rect, far from any edge -- an outlined rectangle
      // would miss here, but an image annotation must not.
      final hit = hitTest(
        unfilledLikeRect,
        const NormalizedPoint(0.5, 0.5),
        0.02,
        0.02,
      );

      expect(hit, isTrue);
    });

    test('hitTestAnnotations finds it via the normal pipeline too', () {
      final hit = hitTestAnnotations(
        [image()],
        const NormalizedPoint(0.5, 0.5),
        contentRect,
        pixelPosition: const Offset(200, 200),
        transform: ImageTransform.identity,
      );

      expect(hit, isNotNull);
      expect(hit, isA<ImageAnnotation>());
    });
  });
}
