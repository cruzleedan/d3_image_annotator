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
}
