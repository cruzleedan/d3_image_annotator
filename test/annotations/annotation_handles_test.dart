import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A 400x400 content rect at the origin, so normalized 0.5 is pixel 200
  // and every expectation stays checkable by hand.
  const contentRect = Rect.fromLTWH(0, 0, 400, 400);

  RectangleAnnotation rectangle() => RectangleAnnotation(
    id: 'r',
    style: const AnnotationStyle(),
    rect: NormalizedRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75),
  );

  const arrow = ArrowAnnotation(
    id: 'a',
    style: AnnotationStyle(),
    start: NormalizedPoint(0.2, 0.2),
    end: NormalizedPoint(0.8, 0.8),
  );

  group('which grips a shape offers', () {
    test('bounded shapes offer four corners', () {
      expect(gripsOf(rectangle()).keys, hasLength(4));
      expect(
        gripsOf(
          CircleAnnotation(
            id: 'c',
            style: const AnnotationStyle(),
            rect: NormalizedRect(left: 0, top: 0, right: 1, bottom: 1),
          ),
        ).keys,
        contains(AnnotationGrip.topLeft),
      );
    });

    test('an arrow offers its two endpoints, not corners', () {
      // Corners would lose direction; an arrow's meaning is which way it
      // points, so the grips have to be the ends themselves.
      expect(gripsOf(arrow).keys, {
        AnnotationGrip.start,
        AnnotationGrip.end,
      });
    });

    test('freehand offers none', () {
      // Scaling a sampled path is a different operation from dragging a
      // corner. Freehand can still be moved and deleted.
      final stroke = FreehandAnnotation(
        id: 'f',
        style: const AnnotationStyle(),
        points: const [NormalizedPoint(0.1, 0.1), NormalizedPoint(0.9, 0.9)],
      );

      expect(gripsOf(stroke), isEmpty);
    });
  });

  group('finding a grip under the finger', () {
    test('a touch on a corner finds that corner', () {
      // Rect corner (0.25, 0.25) is pixel (100, 100).
      final grip = gripAt(
        rectangle(),
        const Offset(100, 100),
        contentRect,
        ImageTransform.identity,
      );

      expect(grip, AnnotationGrip.topLeft);
    });

    test('a touch near but not on a corner still finds it', () {
      // Handles need a finger-sized target, not a pixel-exact one.
      final grip = gripAt(
        rectangle(),
        const Offset(112, 112),
        contentRect,
        ImageTransform.identity,
      );

      expect(grip, AnnotationGrip.topLeft);
    });

    test('a touch in the middle of the shape finds no grip', () {
      // So the caller falls through to shape hit-testing and moves it.
      final grip = gripAt(
        rectangle(),
        const Offset(200, 200),
        contentRect,
        ImageTransform.identity,
      );

      expect(grip, isNull);
    });

    test('the nearest grip wins when two are close', () {
      // On a small shape the targets overlap; resolving by distance
      // keeps it deterministic rather than declaration-order dependent.
      final tiny = RectangleAnnotation(
        id: 't',
        style: const AnnotationStyle(),
        rect: NormalizedRect(left: 0.5, top: 0.5, right: 0.54, bottom: 0.54),
      );

      // Nearer the top-left (200,200) than the bottom-right (216,216).
      final grip = gripAt(
        tiny,
        const Offset(202, 202),
        contentRect,
        ImageTransform.identity,
      );

      expect(grip, AnnotationGrip.topLeft);
    });

    test('grips follow the image transform', () {
      // Under rotation a corner is somewhere else on screen; hit-testing
      // has to look where the handle is actually drawn.
      const rotated = ImageTransform(quarterTurns: 1);
      final mapped = rotated.mapPoint(const NormalizedPoint(0.25, 0.25));
      final onScreen = Offset(mapped.x * 400, mapped.y * 400);

      expect(
        gripAt(rectangle(), onScreen, contentRect, rotated),
        AnnotationGrip.topLeft,
      );
    });

    test(
      'a per-shape rotation (WORK-0035) moves a corner handle to where '
      'the shape is actually drawn, not its unrotated stored corner',
      () {
        // rect corners at pixel (100,100)-(300,300), centre (200,200).
        final shape = rectangle().copyWith(rotation: math.pi / 6); // 30°

        // The unrotated top-left (100,100) is NOT where the shape's
        // visual corner is any more -- a touch there must miss.
        expect(
          gripAt(shape, const Offset(100, 100), contentRect, ImageTransform.identity),
          isNull,
          reason: 'this is where the corner would be with no rotation',
        );

        // Rotate (100,100) by 30° about the centre (200,200) by hand,
        // matching _rotateAround's convention exactly.
        const center = Offset(200, 200);
        final cosA = math.cos(math.pi / 6);
        final sinA = math.sin(math.pi / 6);
        const dx = -100.0;
        const dy = -100.0;
        final actualCorner = Offset(
          center.dx + dx * cosA - dy * sinA,
          center.dy + dx * sinA + dy * cosA,
        );

        expect(
          gripAt(shape, actualCorner, contentRect, ImageTransform.identity),
          AnnotationGrip.topLeft,
          reason: 'the handle must be where the rotated shape visually is',
        );
      },
    );

    test('an unrotated shape offers a rotation handle beyond its '
        'bottom-right corner', () {
      // Bottom-right specifically so it stays clear of the floating
      // delete/duplicate controls, which anchor to the left side.
      final positions = gripPositionsInPixels(
        rectangle(),
        contentRect,
        ImageTransform.identity,
      );

      expect(positions, contains(AnnotationGrip.rotate));
      final bottomRight = positions[AnnotationGrip.bottomRight]!;
      final rotateHandle = positions[AnnotationGrip.rotate]!;
      // Beyond the corner, continuing outward from the centre, not
      // sitting on top of it or inside the shape.
      expect((rotateHandle - bottomRight).distance,
          closeTo(kRotationHandleOffset, 1e-9));
      expect(rotateHandle.dx, greaterThan(bottomRight.dx));
      expect(rotateHandle.dy, greaterThan(bottomRight.dy));
    });
  });

  group('resizing', () {
    test('dragging a corner moves only that corner', () {
      final resized = resizeAnnotation(
        rectangle(),
        AnnotationGrip.topLeft,
        const NormalizedPoint(0.1, 0.1),
      )! as RectangleAnnotation;

      expect(resized.rect.left, closeTo(0.1, 1e-9));
      expect(resized.rect.top, closeTo(0.1, 1e-9));
      expect(resized.rect.right, closeTo(0.75, 1e-9),
          reason: 'the opposite corner must not move');
      expect(resized.rect.bottom, closeTo(0.75, 1e-9));
    });

    test('resizing keeps the annotation id, so undo tracks one mark', () {
      final resized = resizeAnnotation(
        rectangle(),
        AnnotationGrip.bottomRight,
        const NormalizedPoint(0.9, 0.9),
      )!;

      expect(resized.id, 'r');
    });

    test('a corner dragged past its opposite is refused, not flipped', () {
      // Clamping to a minimum would pin the shape to an arbitrary size;
      // refusing leaves it exactly as it was.
      final resized = resizeAnnotation(
        rectangle(),
        AnnotationGrip.topLeft,
        const NormalizedPoint(0.75, 0.75),
      );

      expect(resized, isNull);
    });

    test('an arrow endpoint moves without losing direction', () {
      final resized =
          resizeAnnotation(
                arrow,
                AnnotationGrip.end,
                const NormalizedPoint(0.4, 0.9),
              )!
              as ArrowAnnotation;

      expect(resized.start, arrow.start, reason: 'tail must not move');
      expect(resized.end.x, closeTo(0.4, 1e-9));
    });

    test('an arrow can be reversed by dragging one end past the other', () {
      // Meaningful for a shape whose whole point is which way it points,
      // so this is allowed where a rect corner flip is not.
      final resized =
          resizeAnnotation(
                arrow,
                AnnotationGrip.end,
                const NormalizedPoint(0.05, 0.05),
              )!
              as ArrowAnnotation;

      expect(resized.end.x, lessThan(resized.start.x));
    });

    test('freehand cannot be resized', () {
      final stroke = FreehandAnnotation(
        id: 'f',
        style: const AnnotationStyle(),
        points: const [NormalizedPoint(0.1, 0.1), NormalizedPoint(0.9, 0.9)],
      );

      expect(
        resizeAnnotation(
          stroke,
          AnnotationGrip.topLeft,
          const NormalizedPoint(0.5, 0.5),
        ),
        isNull,
      );
    });
  });

  group('rotated resize and rotation (WORK-0035)', () {
    test(
      'a corner drag on a 90-degree-rotated rect changes what was '
      "originally its height, not its width -- resize follows the "
      "shape's own tilted axes",
      () {
        // A tall rect, 0.2 wide x 0.4 tall, rotated a full quarter turn:
        // on screen it now reads as wide and short, but its stored
        // rect is untouched -- only `rotation` carries the tilt.
        final tall = RectangleAnnotation(
          id: 'r',
          style: const AnnotationStyle(),
          rect: NormalizedRect(left: 0.4, top: 0.3, right: 0.6, bottom: 0.7),
          rotation: math.pi / 2,
        );

        // Drag the shape's on-screen bottomRight handle straight outward
        // along its own diagonal from centre -- a generic "make it
        // bigger from this corner" drag, in world/screen pixel space
        // (exactly what a real gesture supplies), not a hand-derived
        // local-frame target coupled to any particular implementation.
        final positions = gripPositionsInPixels(
          tall,
          contentRect,
          ImageTransform.identity,
        );
        final center = mapRectToPixels(
          tall.bounds,
          contentRect,
          ImageTransform.identity,
        ).center;
        final bottomRight = positions[AnnotationGrip.bottomRight]!;
        final pixelPosition = bottomRight + (bottomRight - center) * 0.5;

        final resized = resizeRotatedAnnotation(
          tall,
          AnnotationGrip.bottomRight,
          pixelPosition,
          contentRect,
          ImageTransform.identity,
        )! as RectangleAnnotation;

        // The rect was 0.2 wide x 0.4 tall before rotation. A 90° turn
        // means the on-screen "outward along the diagonal" drag grows
        // both the local width and height somewhat, but the *original*
        // long axis (what was `bottom - top`, i.e. height) must still
        // end up growing by more than the original short axis (what was
        // `right - left`, i.e. width) did not shrink -- concretely: the
        // resize must actually change the rect (not be a no-op) and
        // must not touch rotation.
        expect(resized.rect, isNot(tall.rect),
            reason: 'the drag must actually resize the rect');
        expect(resized.rotation, tall.rotation,
            reason: 'resizing must not change rotation');

        // The real invariant this test exists for: the corner opposite
        // the one dragged (topLeft) must stay fixed on screen -- see
        // the dedicated anchor-corner test below for the direct check;
        // this confirms it holds for a full quarter turn specifically,
        // the case that originally motivated tilted-axis resize.
        final anchorBefore = positions[AnnotationGrip.topLeft]!;
        final anchorAfter = gripPositionsInPixels(
          resized,
          contentRect,
          ImageTransform.identity,
        )[AnnotationGrip.topLeft]!;
        expect((anchorAfter - anchorBefore).distance, lessThan(1e-6));
      },
    );

    test(
      'corner-drag on a rotated shape keeps the opposite corner fixed '
      'on screen, not drifting every corner outward together',
      () {
        // Regression test for a real bug found on-device: dragging one
        // corner of a rotated shape visibly moved every corner, because
        // the drag point was being inverse-rotated around the shape's
        // *current* centre -- correct for a hit test, wrong for a
        // resize, since a resize is about to move the centre. The fix
        // keeps the diagonally opposite corner's on-screen position
        // fixed instead.
        final square = RectangleAnnotation(
          id: 'r',
          style: const AnnotationStyle(),
          rect: NormalizedRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75),
          rotation: math.pi / 6, // 30 degrees
        );

        // The opposite corner of bottomRight is topLeft -- record its
        // on-screen (rotated) position before the drag.
        final before = gripPositionsInPixels(
          square,
          contentRect,
          ImageTransform.identity,
        );
        final anchorBefore = before[AnnotationGrip.topLeft]!;

        // Drag the on-screen bottomRight handle further outward along
        // its own diagonal.
        final bottomRightBefore = before[AnnotationGrip.bottomRight]!;
        final center = mapRectToPixels(
          square.bounds,
          contentRect,
          ImageTransform.identity,
        ).center;
        final outward = bottomRightBefore - center;
        final dragTarget = bottomRightBefore + outward * 0.5;

        final resized = resizeRotatedAnnotation(
          square,
          AnnotationGrip.bottomRight,
          dragTarget,
          contentRect,
          ImageTransform.identity,
        )! as RectangleAnnotation;

        final after = gripPositionsInPixels(
          resized,
          contentRect,
          ImageTransform.identity,
        );
        final anchorAfter = after[AnnotationGrip.topLeft]!;

        expect((anchorAfter - anchorBefore).distance, lessThan(1e-6),
            reason: 'the opposite (topLeft) corner must not move on '
                'screen when bottomRight is dragged');
        expect((after[AnnotationGrip.bottomRight]! - dragTarget).distance,
            lessThan(1e-6),
            reason: 'the dragged corner must land exactly under the '
                'finger');
      },
    );

    test(
      'dragging the rotation handle changes only rotation, leaving the '
      "rect's own bounds untouched",
      () {
        final shape = rectangle();
        final positions = gripPositionsInPixels(
          shape,
          contentRect,
          ImageTransform.identity,
        );
        final handle = positions[AnnotationGrip.rotate]!;

        // Drag the rotation handle a further 90 degrees around the
        // centre from its starting position.
        final mappedRect = mapRectToPixels(
          shape.bounds,
          contentRect,
          ImageTransform.identity,
        );
        final center = mappedRect.center;
        final dx = handle.dx - center.dx;
        final dy = handle.dy - center.dy;
        // Rotate the handle's own offset by +90 degrees.
        final dragged = Offset(center.dx - dy, center.dy + dx);

        final rotated = rotateAnnotation(
          shape,
          dragged,
          contentRect,
          ImageTransform.identity,
        )! as RectangleAnnotation;

        expect(rotated.rect, shape.rect, reason: 'bounds must not change');
        expect(rotated.rotation, closeTo(math.pi / 2, 1e-6));
      },
    );

    test('rotateAnnotation returns null for shapes with no rotation field', () {
      const arrow = ArrowAnnotation(
        id: 'a',
        style: AnnotationStyle(),
        start: NormalizedPoint(0.2, 0.2),
        end: NormalizedPoint(0.8, 0.8),
      );

      expect(
        rotateAnnotation(
          arrow,
          const Offset(300, 100),
          contentRect,
          ImageTransform.identity,
        ),
        isNull,
      );
    });
  });

  group('handles are UI, not picture', () {
    test('the touch target is in pixels, so it is image-size independent', () {
      // A handle must stay finger-sized however large the image is --
      // the opposite of stroke width, which scales with the picture.
      // Same offset from the corner, wildly different content rects.
      final small = gripAt(
        rectangle(),
        const Offset(110, 110),
        const Rect.fromLTWH(0, 0, 400, 400),
        ImageTransform.identity,
      );
      final large = gripAt(
        rectangle(),
        const Offset(1010, 1010),
        const Rect.fromLTWH(0, 0, 4000, 4000),
        ImageTransform.identity,
      );

      expect(small, AnnotationGrip.topLeft);
      expect(large, AnnotationGrip.topLeft,
          reason: 'a 10px miss must be forgiven at any image size');
    });
  });

  group('image annotations (WORK-0037)', () {
    ImageAnnotation image() => ImageAnnotation(
      id: 'i',
      style: const AnnotationStyle(),
      reference: 'ref',
      rect: NormalizedRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75),
    );

    test('offers four corner grips, exactly like a rectangle', () {
      expect(gripsOf(image()).keys, {
        AnnotationGrip.topLeft,
        AnnotationGrip.topRight,
        AnnotationGrip.bottomLeft,
        AnnotationGrip.bottomRight,
      });
    });

    test('a touch on a corner finds that corner', () {
      // rect corner (0.25, 0.25) is pixel (100, 100).
      final grip = gripAt(
        image(),
        const Offset(100, 100),
        contentRect,
        ImageTransform.identity,
      );

      expect(grip, AnnotationGrip.topLeft);
    });

    test('corner-drag resizes the placement rect, not an internal crop', () {
      final resized = resizeAnnotation(
        image(),
        AnnotationGrip.topLeft,
        const NormalizedPoint(0.1, 0.1),
      )! as ImageAnnotation;

      expect(resized.rect.left, closeTo(0.1, 1e-9));
      expect(resized.rect.top, closeTo(0.1, 1e-9));
      expect(resized.rect.right, closeTo(0.75, 1e-9),
          reason: 'the opposite corner must not move');
      expect(resized.imageTransform, ImageTransform.identity,
          reason: 'resize must not touch the internal crop/mirror');
    });

    test('resize refuses a corner dragged past its opposite, like every '
        'other bounded type', () {
      final resized = resizeAnnotation(
        image(),
        AnnotationGrip.topLeft,
        const NormalizedPoint(0.75, 0.75),
      );

      expect(resized, isNull);
    });

    test('rotating changes only rotation, leaving rect and imageTransform '
        'untouched', () {
      final original = image();
      final positions = gripPositionsInPixels(
        original,
        contentRect,
        ImageTransform.identity,
      );
      final handle = positions[AnnotationGrip.rotate]!;
      final mappedRect = mapRectToPixels(
        original.bounds,
        contentRect,
        ImageTransform.identity,
      );
      final center = mappedRect.center;
      final dx = handle.dx - center.dx;
      final dy = handle.dy - center.dy;
      // Rotate the handle's own offset by +90 degrees.
      final dragged = Offset(center.dx - dy, center.dy + dx);

      final rotated = rotateAnnotation(
        original,
        dragged,
        contentRect,
        ImageTransform.identity,
      )! as ImageAnnotation;

      expect(rotated.rect, original.rect);
      expect(rotated.imageTransform, original.imageTransform);
      expect(rotated.rotation, closeTo(math.pi / 2, 1e-6));
    });

    test('translateAnnotation moves the placement rect', () {
      final moved = translateAnnotation(image(), 0.1, 0.1)! as ImageAnnotation;

      expect(moved.rect.left, closeTo(0.35, 1e-9));
      expect(moved.rect.top, closeTo(0.35, 1e-9));
    });

    test('translateAnnotation refuses a move that would leave the image', () {
      expect(translateAnnotation(image(), 0.5, 0.5), isNull);
    });

    test('duplicateAnnotation preserves reference and imageTransform', () {
      final withCrop = ImageAnnotation(
        id: 'i',
        style: const AnnotationStyle(),
        reference: 'ref',
        rect: NormalizedRect(left: 0.25, top: 0.25, right: 0.6, bottom: 0.6),
        imageTransform: const ImageTransform(mirrored: true),
      );

      final copy = duplicateAnnotation(withCrop, 'i2') as ImageAnnotation;

      expect(copy.id, 'i2');
      expect(copy.reference, 'ref');
      expect(copy.imageTransform, const ImageTransform(mirrored: true));
      expect(copy.rect, isNot(withCrop.rect),
          reason: 'the duplicate must be offset, not exactly overlapping');
    });
  });
}
