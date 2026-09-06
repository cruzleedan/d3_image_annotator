import 'dart:convert';
import 'dart:ui' show Color, Size;

import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter_test/flutter_test.dart';

/// Annotations are stored as data so they stay editable forever, which
/// only holds if the data survives a round trip exactly. These tests are
/// that guarantee.
void main() {
  const style = AnnotationStyle(
    color: Color(0xFF00A0FF),
    strokeWidth: 0.017,
    filled: true,
  );

  final samples = <String, Annotation>{
    'rectangle': RectangleAnnotation(
      id: 'r1',
      style: style,
      rect: NormalizedRect(left: 0.1, top: 0.2, right: 0.7, bottom: 0.8),
    ),
    'circle': CircleAnnotation(
      id: 'c1',
      style: const AnnotationStyle(),
      rect: NormalizedRect(left: 0, top: 0, right: 1, bottom: 1),
    ),
    'arrow': const ArrowAnnotation(
      id: 'a1',
      style: style,
      start: NormalizedPoint(0.05, 0.95),
      end: NormalizedPoint(0.95, 0.05),
    ),
    'freehand': FreehandAnnotation(
      id: 'f1',
      style: style,
      points: const [
        NormalizedPoint(0, 0),
        NormalizedPoint(0.5, 0.5),
        NormalizedPoint(1, 1),
      ],
    ),
  };

  group('round trip', () {
    samples.forEach((name, annotation) {
      test('$name survives encode/decode unchanged', () {
        final restored = annotationFromJson(annotationToJson(annotation));
        expect(restored, annotation);
      });

      test('$name survives a real JSON string round trip', () {
        // Through jsonEncode/jsonDecode, not just the maps -- that is
        // what a database column or sync payload actually does, and it
        // is where a non-encodable value would surface.
        final text = jsonEncode(annotationToJson(annotation));
        final restored = annotationFromJson(
          jsonDecode(text) as Map<String, Object?>,
        );
        expect(restored, annotation);
      });
    });

    test('edge-of-image geometry is preserved exactly', () {
      // 0 and 1 are the values most likely to be mangled by clamping or
      // rounding, and a mark on the edge is a normal thing to draw.
      final annotation = RectangleAnnotation(
        id: 'edge',
        style: const AnnotationStyle(),
        rect: NormalizedRect(left: 0, top: 0, right: 1, bottom: 1),
      );

      final restored =
          annotationFromJson(annotationToJson(annotation))
              as RectangleAnnotation;

      expect(restored.rect.left, 0);
      expect(restored.rect.right, 1);
    });

    test('a long freehand stroke keeps every point in order', () {
      final points = [
        for (var i = 0; i <= 500; i++) NormalizedPoint(i / 500, (i % 7) / 7),
      ];
      final stroke = FreehandAnnotation(
        id: 'long',
        style: const AnnotationStyle(),
        points: points,
      );

      final restored =
          annotationFromJson(annotationToJson(stroke)) as FreehandAnnotation;

      expect(restored.points, hasLength(points.length));
      expect(restored, stroke);
    });

    test('style round-trips including colour and fill', () {
      final restored =
          annotationFromJson(annotationToJson(samples['rectangle']!));

      expect(restored.style.color.toARGB32(), style.color.toARGB32());
      expect(restored.style.strokeWidth, style.strokeWidth);
      expect(restored.style.filled, isTrue);
    });
  });

  group('rotation (WORK-0033)', () {
    // No schema-version bump: the decode path already reads fields
    // individually rather than checking a full key set, so an optional
    // field with a defined default is compatible in both directions.
    // These tests are that guarantee, not just the happy path.

    test('a nonzero rotation survives encode/decode unchanged', () {
      final rotated = RectangleAnnotation(
        id: 'r1',
        style: style,
        rect: NormalizedRect(left: 0.1, top: 0.2, right: 0.7, bottom: 0.8),
        rotation: 0.7853981633974483, // pi/4
      );

      final restored = annotationFromJson(annotationToJson(rotated));

      expect(restored, rotated);
      expect((restored as RectangleAnnotation).rotation, rotated.rotation);
    });

    test('a rotated circle survives encode/decode unchanged', () {
      final rotated = CircleAnnotation(
        id: 'c1',
        style: style,
        rect: NormalizedRect(left: 0, top: 0, right: 1, bottom: 0.5),
        rotation: -1.2,
      );

      final restored = annotationFromJson(annotationToJson(rotated));

      expect(restored, rotated);
      expect((restored as CircleAnnotation).rotation, rotated.rotation);
    });

    test('a zero rotation is not written to JSON at all', () {
      // Keeps documents written before rotation existed byte-for-byte
      // comparable to ones written since, for the common unrotated case.
      final json = annotationToJson(samples['rectangle']!);
      expect(json.containsKey('rotation'), isFalse);
    });

    test('a document with no "rotation" key decodes as zero', () {
      // Simulates a document written before WORK-0033 -- no rotation
      // key present at all, not just a zero value.
      final json = <String, Object?>{
        'type': 'rectangle',
        'id': 'r1',
        'style': {'color': 0xFFFF0000, 'strokeWidth': 0.01, 'filled': false},
        'rect': {'left': 0.1, 'top': 0.1, 'right': 0.5, 'bottom': 0.5},
      };

      final restored = annotationFromJson(json) as RectangleAnnotation;

      expect(restored.rotation, 0.0);
    });

    test('a non-numeric "rotation" throws rather than silently defaulting',
        () {
      final json = <String, Object?>{
        'type': 'circle',
        'id': 'c1',
        'style': {'color': 0xFFFF0000, 'strokeWidth': 0.01, 'filled': false},
        'rect': {'left': 0.0, 'top': 0.0, 'right': 1.0, 'bottom': 1.0},
        'rotation': 'sideways',
      };

      expect(
        () => annotationFromJson(json),
        throwsA(isA<AnnotationDecodeException>()),
      );
    });

    test('copyWith preserves rotation when not explicitly changed', () {
      final rotated = RectangleAnnotation(
        id: 'r1',
        style: style,
        rect: NormalizedRect(left: 0.1, top: 0.1, right: 0.5, bottom: 0.5),
        rotation: 0.5,
      );

      final moved = rotated.copyWith(
        rect: NormalizedRect(left: 0.2, top: 0.2, right: 0.6, bottom: 0.6),
      );

      expect(moved.rotation, 0.5,
          reason: 'moving a rotated shape must not silently reset its '
              'rotation to zero');
    });

    test('copyWithStyle preserves rotation', () {
      final rotated = CircleAnnotation(
        id: 'c1',
        style: style,
        rect: NormalizedRect(left: 0.0, top: 0.0, right: 1.0, bottom: 1.0),
        rotation: 1.1,
      );

      final restyled = rotated.copyWithStyle(const AnnotationStyle());

      expect(restyled.rotation, 1.1,
          reason: 'restyling a rotated shape must not silently reset its '
              'rotation to zero');
    });
  });

  group('AnnotationDocument', () {
    test('round-trips a whole document through JSON', () {
      final document = AnnotationDocument(
        annotations: samples.values.toList(),
        sourceImageSize: const Size(3000, 4000),
      );

      final restored = AnnotationDocument.fromJson(
        jsonDecode(jsonEncode(document.toJson())) as Map<String, Object?>,
      );

      expect(restored, document);
      expect(restored.sourceImageSize, const Size(3000, 4000));
    });

    test('carries a schema version', () {
      final json = const AnnotationDocument(annotations: []).toJson();
      expect(json['schemaVersion'], kAnnotationSchemaVersion);
    });

    test('refuses a payload from a newer schema rather than dropping data', () {
      // Silently reading what it understands and ignoring the rest would
      // lose annotations without telling anyone.
      final json = <String, Object?>{
        'schemaVersion': kAnnotationSchemaVersion + 1,
        'annotations': const <Object?>[],
      };

      expect(
        () => AnnotationDocument.fromJson(json),
        throwsA(isA<AnnotationDecodeException>()),
      );
    });

    test('rejects something that is not an annotation payload', () {
      expect(
        () => AnnotationDocument.fromJson(const {'hello': 'world'}),
        throwsA(isA<AnnotationDecodeException>()),
      );
    });
  });

  group('decoding fails loudly', () {
    test('an unknown shape type throws rather than being skipped', () {
      // The forward-compatibility case: a newer app wrote a shape this
      // build has never heard of. A missing mark on an inspection report
      // is a defect that looks like nothing at all.
      expect(
        () => annotationFromJson({
          'type': 'hexagon',
          'id': 'x',
          'style': {'color': 0xFFFF0000, 'strokeWidth': 0.01, 'filled': false},
        }),
        throwsA(isA<AnnotationDecodeException>()),
      );
    });

    test('a missing id throws', () {
      expect(
        () => annotationFromJson({
          'type': 'rectangle',
          'style': {'color': 0xFFFF0000, 'strokeWidth': 0.01, 'filled': false},
          'rect': {'left': 0.0, 'top': 0.0, 'right': 1.0, 'bottom': 1.0},
        }),
        throwsA(isA<AnnotationDecodeException>()),
      );
    });

    test('malformed geometry throws', () {
      expect(
        () => annotationFromJson({
          'type': 'rectangle',
          'id': 'r',
          'style': {'color': 0xFFFF0000, 'strokeWidth': 0.01, 'filled': false},
          'rect': {'left': 'nope', 'top': 0.0, 'right': 1.0, 'bottom': 1.0},
        }),
        throwsA(isA<AnnotationDecodeException>()),
      );
    });

    test('an empty freehand stroke throws', () {
      expect(
        () => annotationFromJson({
          'type': 'freehand',
          'id': 'f',
          'style': {'color': 0xFFFF0000, 'strokeWidth': 0.01, 'filled': false},
          'points': <Object?>[],
        }),
        throwsA(isA<AnnotationDecodeException>()),
      );
    });
  });

  group('image binding', () {
    const document = AnnotationDocument(
      annotations: [],
      sourceImageSize: Size(3000, 4000),
    );

    test('matching dimensions bind cleanly', () {
      expect(
        classifyBinding(document, const Size(3000, 4000)),
        AnnotationBinding.ok,
      );
    });

    test('different dimensions are reported as a mismatch', () {
      // The file was replaced or re-cropped outside this package, so
      // every mark would land somewhere other than where it was drawn.
      expect(
        classifyBinding(document, const Size(1000, 1000)),
        AnnotationBinding.sizeMismatch,
      );
    });

    test('a missing image is its own state, not a mismatch', () {
      // The case that prompted recording dimensions at all: annotations
      // survived but the file did not. There is nothing to render
      // against, and a blank canvas would be a lie.
      expect(
        classifyBinding(document, null),
        AnnotationBinding.missingImage,
      );
    });

    test('no recorded hint binds cleanly rather than blocking', () {
      // Absence of evidence is not a mismatch -- refusing here would
      // break every payload written before hints existed.
      const noHint = AnnotationDocument(annotations: []);

      expect(
        classifyBinding(noHint, const Size(123, 456)),
        AnnotationBinding.ok,
      );
    });

    test('a mismatch is advisory: decoding still succeeds', () {
      // The package refuses to guess what a mismatch means -- an app may
      // be re-associating annotations deliberately.
      final json = jsonDecode(jsonEncode(document.toJson()));
      expect(
        () => AnnotationDocument.fromJson(json as Map<String, Object?>),
        returnsNormally,
      );
    });
  });
}
