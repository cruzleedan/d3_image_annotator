import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter_test/flutter_test.dart';

RectangleAnnotation _rect(String id, {double left = 0.1}) {
  return RectangleAnnotation(
    id: id,
    style: const AnnotationStyle(),
    rect: NormalizedRect(left: left, top: 0.1, right: 0.5, bottom: 0.5),
  );
}

void main() {
  group('AnnotationController mutations', () {
    test('add appends in paint order', () {
      final c = AnnotationController();
      c.add(_rect('a'));
      c.add(_rect('b'));

      expect(c.annotations.map((a) => a.id), ['a', 'b']);
    });

    test('annotations getter is unmodifiable', () {
      // Callers must go through the controller so undo stays correct.
      final c = AnnotationController()..add(_rect('a'));

      expect(() => c.annotations.add(_rect('b')), throwsUnsupportedError);
    });

    test('update replaces in place, preserving order', () {
      final c = AnnotationController()
        ..add(_rect('a'))
        ..add(_rect('b'));

      c.update('a', _rect('a', left: 0.4));

      expect(c.annotations.map((a) => a.id), ['a', 'b']);
      expect((c.annotations.first as RectangleAnnotation).rect.left, 0.4);
    });

    test('update with an unknown id is a no-op, not an append', () {
      // A stale reference must not silently duplicate content.
      final c = AnnotationController()..add(_rect('a'));

      c.update('missing', _rect('missing'));

      expect(c.annotations.length, 1);
    });

    test('remove drops the annotation and clears selection of it', () {
      final c = AnnotationController()..add(_rect('a'));
      c.select('a');

      c.remove('a');

      expect(c.annotations, isEmpty);
      expect(c.selectedId, isNull);
    });

    test('clear on an empty controller does not push an undo step', () {
      final c = AnnotationController();
      c.clear();

      expect(c.canUndo, isFalse);
    });

    test('notifies listeners on mutation', () {
      final c = AnnotationController();
      var notifications = 0;
      c.addListener(() => notifications++);

      c.add(_rect('a'));
      c.remove('a');

      expect(notifications, 2);
    });
  });

  group('AnnotationController undo/redo', () {
    test('undo restores the previous list', () {
      final c = AnnotationController()
        ..add(_rect('a'))
        ..add(_rect('b'));

      c.undo();

      expect(c.annotations.map((a) => a.id), ['a']);
      expect(c.canRedo, isTrue);
    });

    test('redo reapplies what undo removed', () {
      final c = AnnotationController()..add(_rect('a'));
      c.undo();
      c.redo();

      expect(c.annotations.map((a) => a.id), ['a']);
    });

    test('a new edit clears the redo branch', () {
      // Standard editor behaviour: redo must not resurrect annotations
      // from a history that no longer leads here.
      final c = AnnotationController()..add(_rect('a'));
      c.undo();
      expect(c.canRedo, isTrue);

      c.add(_rect('b'));

      expect(c.canRedo, isFalse);
      expect(c.annotations.map((a) => a.id), ['b']);
    });

    test('undo/redo on an empty stack is a safe no-op', () {
      final c = AnnotationController();

      c.undo();
      c.redo();

      expect(c.annotations, isEmpty);
      expect(c.canUndo, isFalse);
    });

    test('undo history is bounded by maxUndoSteps', () {
      final c = AnnotationController(maxUndoSteps: 3);
      for (var i = 0; i < 10; i++) {
        c.add(_rect('a$i'));
      }

      var undos = 0;
      while (c.canUndo) {
        c.undo();
        undos++;
        expect(undos, lessThanOrEqualTo(3), reason: 'stack must stay bounded');
      }

      expect(undos, 3);
    });

    test('undo restores a cleared list', () {
      final c = AnnotationController()
        ..add(_rect('a'))
        ..add(_rect('b'));

      c.clear();
      expect(c.annotations, isEmpty);

      c.undo();
      expect(c.annotations.map((a) => a.id), ['a', 'b']);
    });

    test('undoing past an annotation drops a selection of it', () {
      final c = AnnotationController()..add(_rect('a'));
      c.select('a');

      c.undo();

      expect(c.selectedId, isNull,
          reason: 'selection cannot point at an annotation that is gone');
    });

    test('selection changes are not undoable', () {
      // Selection is view state -- undoing a draw should not also
      // restore whatever happened to be selected at the time.
      final c = AnnotationController()..add(_rect('a'));
      c.select('a');
      c.select(null);

      expect(c.canUndo, isTrue);
      c.undo();
      expect(c.annotations, isEmpty, reason: 'undo should reverse the add');
    });
  });

  group('AnnotationController style', () {
    test('style changes notify but are not undoable', () {
      final c = AnnotationController();
      var notifications = 0;
      c.addListener(() => notifications++);

      c.style = const AnnotationStyle(strokeWidth: 0.02);

      expect(notifications, 1);
      expect(c.canUndo, isFalse);
    });

    test('setting an identical style does not notify', () {
      final c = AnnotationController();
      var notifications = 0;
      c.addListener(() => notifications++);

      c.style = const AnnotationStyle();

      expect(notifications, 0);
    });
  });

  group('image transform', () {
    test('rotate, mirror and crop are each one undoable step', () {
      final c = AnnotationController();

      c.rotateClockwise();
      expect(c.transform.quarterTurns, 1);

      c.undo();
      expect(c.transform, ImageTransform.identity);

      c.redo();
      expect(c.transform.quarterTurns, 1);
    });

    test('undo restores annotations and transform together', () {
      // The reason snapshots capture both: undoing a rotation must not
      // leave behind marks drawn after it, and vice versa.
      final c = AnnotationController();
      c.add(_rect('a'));
      c.rotateClockwise();
      c.add(_rect('b'));

      c.undo(); // removes 'b'
      expect(c.annotations.map((a) => a.id), ['a']);
      expect(c.transform.quarterTurns, 1, reason: 'rotation should remain');

      c.undo(); // undoes the rotation
      expect(c.transform, ImageTransform.identity);
      expect(c.annotations.map((a) => a.id), ['a'],
          reason: 'undoing a rotation must not disturb annotations');
    });

    test('annotation geometry is untouched by a transform', () {
      // Marks stay in the original image's space; the transform is
      // composed at paint time. Rewriting them would accumulate error
      // and make crop destructive.
      final c = AnnotationController();
      c.add(_rect('a'));
      final before = (c.annotations.single as RectangleAnnotation).rect;

      c.rotateClockwise();
      c.toggleMirror();
      c.crop(NormalizedRect(left: 0.2, top: 0.2, right: 0.8, bottom: 0.8));

      final after = (c.annotations.single as RectangleAnnotation).rect;
      expect(after, before);
    });

    test('a crop is reversible and brings clipped marks back', () {
      final c = AnnotationController();
      c.add(_rect('a'));

      c.crop(NormalizedRect(left: 0.6, top: 0.6, right: 1, bottom: 1));
      expect(c.transform.cropRect, isNotNull);

      c.crop(null);
      expect(c.transform.isIdentity, isTrue);
      expect(c.annotations, hasLength(1),
          reason: 'the mark was never deleted, only clipped');
    });

    test('four rotations return to the identity', () {
      final c = AnnotationController();
      for (var i = 0; i < 4; i++) {
        c.rotateClockwise();
      }
      expect(c.transform, ImageTransform.identity);
    });

    test('setting the same crop twice does not push a second undo step', () {
      final c = AnnotationController();
      final rect = NormalizedRect(
        left: 0.1,
        top: 0.1,
        right: 0.9,
        bottom: 0.9,
      );

      c.crop(rect);
      c.crop(rect);
      c.undo();

      expect(c.transform.isIdentity, isTrue);
    });

    test('resetTransform on an identity transform is a no-op', () {
      final c = AnnotationController();
      c.resetTransform();
      expect(c.canUndo, isFalse);
    });

    test('transform changes notify listeners', () {
      final c = AnnotationController();
      var notifications = 0;
      c.addListener(() => notifications++);

      c.rotateClockwise();
      c.toggleMirror();

      expect(notifications, 2);
    });
  });
}
