import 'dart:ui' show Size;

import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter_test/flutter_test.dart';

/// A transform is only safe if a point survives the trip out and back.
/// A user draws on the *transformed* view; the mark is stored against
/// the *original* image. Get that wrong and every annotation lands
/// somewhere else the moment a photo is rotated.
void main() {
  group('identity', () {
    test('does nothing', () {
      const t = ImageTransform.identity;
      expect(t.isIdentity, isTrue);
      expect(t.swapsAxes, isFalse);

      final mapped = t.mapPoint(const NormalizedPoint(0.3, 0.7));
      expect(mapped.x, closeTo(0.3, 1e-9));
      expect(mapped.y, closeTo(0.7, 1e-9));
    });

    test('leaves the result size alone', () {
      expect(
        ImageTransform.identity.resultSize(const Size(3000, 4000)),
        const Size(3000, 4000),
      );
    });
  });

  group('rotation', () {
    test('a quarter turn moves top-left to top-right', () {
      // Rotating clockwise, the point that was in the top-left corner
      // ends up in the top-right.
      const t = ImageTransform(quarterTurns: 1);
      final mapped = t.mapPoint(const NormalizedPoint(0, 0));

      expect(mapped.x, closeTo(1, 1e-9));
      expect(mapped.y, closeTo(0, 1e-9));
    });

    test('odd quarter turns swap width and height', () {
      const portrait = Size(3000, 4000);

      expect(
        const ImageTransform(quarterTurns: 1).resultSize(portrait),
        const Size(4000, 3000),
      );
      expect(
        const ImageTransform(quarterTurns: 2).resultSize(portrait),
        portrait,
      );
    });

    test('four quarter turns return to the start', () {
      var t = ImageTransform.identity;
      for (var i = 0; i < 4; i++) {
        t = t.rotatedClockwise();
      }
      expect(t, ImageTransform.identity);
    });

    test('counter-clockwise from zero wraps to three, not minus one', () {
      expect(ImageTransform.identity.rotatedCounterClockwise().quarterTurns, 3);
    });
  });

  group('mirror', () {
    test('flips horizontally, leaving the vertical alone', () {
      const t = ImageTransform(mirrored: true);
      final mapped = t.mapPoint(const NormalizedPoint(0.25, 0.6));

      expect(mapped.x, closeTo(0.75, 1e-9));
      expect(mapped.y, closeTo(0.6, 1e-9));
    });

    test('mirroring twice is the identity', () {
      const t = ImageTransform(mirrored: true);
      final once = t.mapPoint(const NormalizedPoint(0.2, 0.4));
      final twice = t.mapPoint(NormalizedPoint(once.x, once.y));

      expect(twice.x, closeTo(0.2, 1e-9));
    });
  });

  group('crop', () {
    final centreHalf = NormalizedRect(
      left: 0.25,
      top: 0.25,
      right: 0.75,
      bottom: 0.75,
    );

    test('re-expresses points relative to the visible region', () {
      final t = ImageTransform(cropRect: centreHalf);

      // The crop's own centre is the centre of the result.
      final centre = t.mapPoint(const NormalizedPoint(0.5, 0.5));
      expect(centre.x, closeTo(0.5, 1e-9));

      // The crop's top-left corner becomes the result's origin.
      final origin = t.mapPoint(const NormalizedPoint(0.25, 0.25));
      expect(origin.x, closeTo(0, 1e-9));
      expect(origin.y, closeTo(0, 1e-9));
    });

    test('points outside the crop map outside [0,1] rather than clamping', () {
      // This is what makes clipping possible: a mark half outside the
      // crop keeps its visible half. Clamping here would drag the whole
      // annotation to the edge instead.
      final t = ImageTransform(cropRect: centreHalf);
      final outside = t.mapPoint(const NormalizedPoint(0.1, 0.5));

      expect(outside.x, lessThan(0));
    });

    test('shrinks the result size proportionally', () {
      final t = ImageTransform(cropRect: centreHalf);
      expect(t.resultSize(const Size(1000, 800)), const Size(500, 400));
    });

    test('a crop is reversible -- clearing it restores the full frame', () {
      // The reason crop is stored as a rect rather than by rewriting
      // annotations: widen it again and clipped marks come back intact.
      final cropped = ImageTransform(cropRect: centreHalf);
      final restored = cropped.withCrop(null);

      expect(restored.isIdentity, isTrue);
      final mapped = restored.mapPoint(const NormalizedPoint(0.1, 0.5));
      expect(mapped.x, closeTo(0.1, 1e-9));
    });
  });

  group('round trip: mapPoint then unmapPoint', () {
    /// The guarantee that matters. A user draws on the transformed
    /// view; the mark is stored against the original image. If these
    /// two disagree, every annotation shifts the moment a photo is
    /// rotated or cropped.
    void expectRoundTrip(ImageTransform t, NormalizedPoint original) {
      final mapped = t.mapPoint(original);
      final back = t.unmapPoint(mapped.x, mapped.y);

      expect(back.x, closeTo(original.x, 1e-9), reason: 'x drifted under $t');
      expect(back.y, closeTo(original.y, 1e-9), reason: 'y drifted under $t');
    }

    final transforms = <ImageTransform>[
      ImageTransform.identity,
      const ImageTransform(quarterTurns: 1),
      const ImageTransform(quarterTurns: 2),
      const ImageTransform(quarterTurns: 3),
      const ImageTransform(mirrored: true),
      const ImageTransform(quarterTurns: 1, mirrored: true),
      const ImageTransform(quarterTurns: 3, mirrored: true),
      ImageTransform(
        cropRect: NormalizedRect(
          left: 0.2,
          top: 0.1,
          right: 0.9,
          bottom: 0.8,
        ),
      ),
      ImageTransform(
        quarterTurns: 1,
        mirrored: true,
        cropRect: NormalizedRect(
          left: 0.25,
          top: 0.25,
          right: 0.75,
          bottom: 0.75,
        ),
      ),
    ];

    test('holds for every combination of rotation, mirror and crop', () {
      // Points inside the tightest crop used above, so none is clamped
      // on the way back.
      const points = [
        NormalizedPoint(0.3, 0.3),
        NormalizedPoint(0.5, 0.5),
        NormalizedPoint(0.7, 0.7),
        NormalizedPoint(0.35, 0.65),
      ];

      for (final t in transforms) {
        for (final p in points) {
          expectRoundTrip(t, p);
        }
      }
    });

    test('holds at the corners of an uncropped image', () {
      const corners = [
        NormalizedPoint(0, 0),
        NormalizedPoint(1, 0),
        NormalizedPoint(0, 1),
        NormalizedPoint(1, 1),
      ];

      for (final t in transforms.where((t) => t.cropRect == null)) {
        for (final p in corners) {
          expectRoundTrip(t, p);
        }
      }
    });
  });

  group('serialization', () {
    test('round-trips through JSON', () {
      final t = ImageTransform(
        quarterTurns: 3,
        mirrored: true,
        cropRect: NormalizedRect(
          left: 0.1,
          top: 0.2,
          right: 0.8,
          bottom: 0.9,
        ),
      );

      expect(ImageTransform.fromJson(t.toJson()), t);
    });

    test('an identity transform round-trips without a crop key', () {
      final json = ImageTransform.identity.toJson();

      expect(json.containsKey('crop'), isFalse);
      expect(ImageTransform.fromJson(json), ImageTransform.identity);
    });

    test('normalises out-of-range quarter turns on decode', () {
      final decoded = ImageTransform.fromJson(const {'quarterTurns': 7});
      expect(decoded.quarterTurns, 3);
    });
  });
}
