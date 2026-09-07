import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  RectangleAnnotation rect() => RectangleAnnotation(
    id: 'r',
    style: const AnnotationStyle(),
    rect: NormalizedRect(left: 0.1, top: 0.1, right: 0.5, bottom: 0.5),
  );

  const text = TextAnnotation(
    id: 't',
    style: AnnotationStyle(),
    position: NormalizedPoint(0.2, 0.2),
    text: 'hello',
  );

  group('AnnotationResizing', () {
    test('rejects the rotate grip -- that is AnnotationRotating instead', () {
      expect(
        () => AnnotationResizing(
          id: 'r',
          original: rect(),
          grip: AnnotationGrip.rotate,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('accepts every other grip', () {
      for (final grip in [
        AnnotationGrip.topLeft,
        AnnotationGrip.topRight,
        AnnotationGrip.bottomLeft,
        AnnotationGrip.bottomRight,
        AnnotationGrip.start,
        AnnotationGrip.end,
      ]) {
        final state = AnnotationResizing(id: 'r', original: rect(), grip: grip);
        expect(state.grip, grip);
      }
    });
  });

  group('AnnotationEditing', () {
    test('rejects neither position nor existing being set', () {
      expect(
        () => AnnotationEditing(),
        throwsA(isA<AssertionError>()),
      );
    });

    test('rejects both position and existing being set', () {
      expect(
        () => AnnotationEditing(
          position: const NormalizedPoint(0.1, 0.1),
          existing: text,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('accepts position alone (placing a new annotation)', () {
      const state = AnnotationEditing(position: NormalizedPoint(0.3, 0.3));
      expect(state.position, const NormalizedPoint(0.3, 0.3));
      expect(state.existing, isNull);
    });

    test('accepts existing alone (re-editing)', () {
      const state = AnnotationEditing(existing: text);
      expect(state.existing, text);
      expect(state.position, isNull);
    });
  });

  group('AnnotationMoving.copyWith', () {
    test('replaces only textDragLastPixel, leaving every other field', () {
      final original = rect();
      final state = AnnotationMoving(
        id: 'r',
        original: original,
        anchor: const NormalizedPoint(0.2, 0.2),
        textDragStartPixel: const Offset(10, 10),
      );

      final updated = state.copyWith(textDragLastPixel: const Offset(20, 30));

      expect(updated.id, state.id);
      expect(updated.original, original);
      expect(updated.anchor, state.anchor);
      expect(updated.textDragStartPixel, state.textDragStartPixel);
      expect(updated.textDragLastPixel, const Offset(20, 30));
    });

    test('omitting textDragLastPixel keeps the previous value', () {
      const state = AnnotationMoving(
        id: 't',
        original: text,
        anchor: NormalizedPoint(0.2, 0.2),
        textDragStartPixel: Offset(5, 5),
        textDragLastPixel: Offset(7, 7),
      );

      final updated = state.copyWith();

      expect(updated.textDragLastPixel, const Offset(7, 7));
    });
  });
}
