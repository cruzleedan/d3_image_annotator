import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter_test/flutter_test.dart';

/// The coordinate layer is the phase's central guarantee: an annotation
/// drawn at one size, fit mode, and resolution must land in exactly the
/// same place at another. These tests are the executable form of that
/// claim.
void main() {
  group('toNormalized', () {
    test('maps the content rect corners to [0,1] corners', () {
      const rect = Rect.fromLTWH(100, 50, 400, 300);

      expect(toNormalized(const Offset(100, 50), rect),
          const NormalizedPoint(0, 0));
      expect(toNormalized(const Offset(500, 350), rect),
          const NormalizedPoint(1, 1));
      expect(toNormalized(const Offset(300, 200), rect),
          const NormalizedPoint(0.5, 0.5));
    });

    test('is offset-invariant: the same relative spot normalizes alike', () {
      // The whole point of normalized storage -- a letterboxed rect and
      // a full-bleed one must agree about "the middle of the image".
      const letterboxed = Rect.fromLTWH(100, 50, 400, 300);
      const fullBleed = Rect.fromLTWH(0, 0, 1080, 810);

      expect(
        toNormalized(const Offset(300, 200), letterboxed),
        toNormalized(const Offset(540, 405), fullBleed),
      );
    });

    test('clamps points outside the content rect to its edges', () {
      // A drag that leaves the image has no meaningful coordinate --
      // there is no image there. Clamping keeps a stroke running off the
      // edge as a stroke along the edge.
      const rect = Rect.fromLTWH(100, 50, 400, 300);

      expect(toNormalized(const Offset(-50, 200), rect).x, 0);
      expect(toNormalized(const Offset(9999, 200), rect).x, 1);
      expect(toNormalized(const Offset(300, -80), rect).y, 0);
      expect(toNormalized(const Offset(300, 9999), rect).y, 1);
    });

    test('degenerate content rect does not divide by zero', () {
      expect(
        toNormalized(const Offset(10, 10), Rect.zero),
        const NormalizedPoint(0, 0),
      );
    });
  });

  group('fromNormalized', () {
    test('maps [0,1] corners back to the content rect corners', () {
      const rect = Rect.fromLTWH(100, 50, 400, 300);

      expect(fromNormalized(const NormalizedPoint(0, 0), rect),
          const Offset(100, 50));
      expect(fromNormalized(const NormalizedPoint(1, 1), rect),
          const Offset(500, 350));
    });
  });

  group('round trip', () {
    /// widget -> normalized -> widget must return the original, for any
    /// point inside the content rect. This is the property that makes
    /// "no drift between what's shown and what's saved" true rather
    /// than aspirational.
    void expectRoundTrip(Rect rect, Offset point) {
      final back = fromNormalized(toNormalized(point, rect), rect);
      expect(back.dx, closeTo(point.dx, 1e-9),
          reason: 'x drifted for $point in $rect');
      expect(back.dy, closeTo(point.dy, 1e-9),
          reason: 'y drifted for $point in $rect');
    }

    test('holds across fit modes, sizes, and offsets', () {
      // Content rects taken from the real fit-mode math: a contain rect
      // is letterboxed inside the widget, a cover rect overflows it.
      final rects = <Rect>[
        const Rect.fromLTWH(0, 0, 1080, 1440), // full-bleed 3:4
        const Rect.fromLTWH(84, 173, 912, 1621), // letterboxed 9:16
        const Rect.fromLTWH(-120, 0, 1320, 1080), // cover, overflowing left
        const Rect.fromLTWH(7.5, 11.25, 385, 289), // fractional
      ];

      for (final rect in rects) {
        for (final t in const [0.0, 0.13, 0.5, 0.87, 1.0]) {
          expectRoundTrip(
            rect,
            Offset(
              rect.left + rect.width * t,
              rect.top + rect.height * (1 - t),
            ),
          );
        }
      }
    });

    test('survives a resolution change: preview point == export point', () {
      // The concrete scenario the design exists for. A point tapped on
      // a 1080-wide preview must resolve to the same *fraction* of a
      // 4000-wide export, and therefore the same feature of the image.
      const preview = Rect.fromLTWH(0, 173, 1080, 1440);
      const export = Rect.fromLTWH(0, 0, 3000, 4000);

      final tapped = Offset(preview.left + 1080 * 0.25,
          preview.top + 1440 * 0.75);
      final normalized = toNormalized(tapped, preview);
      final onExport = fromNormalized(normalized, export);

      expect(onExport.dx, closeTo(3000 * 0.25, 1e-6));
      expect(onExport.dy, closeTo(4000 * 0.75, 1e-6));
    });
  });

  group('normalizedTolerance', () {
    test('scales widget pixels per axis', () {
      const rect = Rect.fromLTWH(0, 0, 400, 200);
      final t = normalizedTolerance(20, rect);

      expect(t.x, closeTo(0.05, 1e-9));
      expect(t.y, closeTo(0.10, 1e-9));
    });

    test('a fixed pixel slop shrinks in normalized terms as the image grows',
        () {
      // Why tolerance starts in pixels: the same finger-sized slop must
      // stay finger-sized regardless of image resolution.
      final small = normalizedTolerance(20, const Rect.fromLTWH(0, 0, 400, 400));
      final large =
          normalizedTolerance(20, const Rect.fromLTWH(0, 0, 4000, 4000));

      expect(large.x, lessThan(small.x));
    });

    test('degenerate rect yields zero tolerance rather than infinity', () {
      final t = normalizedTolerance(20, Rect.zero);
      expect(t.x, 0);
      expect(t.y, 0);
    });
  });

  group('interaction with computeImageContentRect', () {
    test('a point tapped on the rendered content maps back to itself', () {
      // Ties the annotation coordinate layer to the preview layout math
      // it must agree with -- these were written in different phases and
      // sharing computeImageContentRect is what keeps them aligned.
      const widgetSize = Size(1080, 2424);
      const contentSize = Size(3000, 4000);

      for (final fit in ImageFit.values) {
        final contentRect = computeImageContentRect(
          widgetSize: widgetSize,
          contentSize: contentSize,
          fit: fit,
        );
        final middle = Offset(
          contentRect.left + contentRect.width / 3,
          contentRect.top + contentRect.height / 3,
        );
        final back =
            fromNormalized(toNormalized(middle, contentRect), contentRect);

        expect(back.dx, closeTo(middle.dx, 1e-9), reason: 'fit: $fit');
        expect(back.dy, closeTo(middle.dy, 1e-9), reason: 'fit: $fit');
      }
    });

    test('contain letterboxes, cover overflows -- both round-trip', () {
      const widgetSize = Size(1000, 1000);
      const contentSize = Size(3000, 4000); // taller than the widget

      final contain = computeImageContentRect(
        widgetSize: widgetSize,
        contentSize: contentSize,
        fit: ImageFit.contain,
      );
      final cover = computeImageContentRect(
        widgetSize: widgetSize,
        contentSize: contentSize,
        fit: ImageFit.cover,
      );

      // Sanity: the two really are different geometries, so the
      // round-trip above is not passing trivially.
      expect(contain.height, lessThanOrEqualTo(widgetSize.height + 1e-9));
      expect(cover.height, greaterThan(widgetSize.height));
      expect(
        math.min(contain.width, contain.height),
        isNot(closeTo(math.min(cover.width, cover.height), 1e-6)),
      );
    });
  });
}
