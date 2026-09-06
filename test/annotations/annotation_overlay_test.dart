import 'dart:async';
import 'dart:typed_data';

import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// A 1000x1000 overlay showing a 500x1000 image. Under `contain` the
  /// image occupies a centred 500-wide column: content rect
  /// (250, 0) - (750, 1000). Deliberately not square, so a bug that
  /// confuses the axes shows up.
  const overlaySize = Size(1000, 1000);
  const imageSize = Size(500, 1000);
  const contentLeft = 250.0;
  const contentWidth = 500.0;

  Future<AnnotationController> pumpOverlay(
    WidgetTester tester, {
    required AnnotationTool tool,
    AnnotationController? controller,
  }) async {
    // The default 800x600 test surface would shrink the SizedBox below
    // and invalidate every coordinate in this file.
    tester.view.physicalSize = overlaySize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final c = controller ?? AnnotationController();
    var n = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: overlaySize.width,
            height: overlaySize.height,
            child: AnnotationOverlay(
              controller: c,
              imageSize: imageSize,
              tool: tool,
              idGenerator: () => 'id${n++}',
            ),
          ),
        ),
      ),
    );
    return c;
  }

  /// Widget coordinate for a normalized position within the content rect.
  Offset at(double nx, double ny) =>
      Offset(contentLeft + nx * contentWidth, ny * overlaySize.height);

  group('creating annotations by gesture', () {
    testWidgets('a drag creates a rectangle at the dragged normalized spot', (
      tester,
    ) async {
      final c = await pumpOverlay(tester, tool: AnnotationTool.rectangle);

      await tester.dragFrom(at(0.2, 0.2), at(0.6, 0.7) - at(0.2, 0.2));
      await tester.pumpAndSettle();

      expect(c.annotations, hasLength(1));
      final rect = (c.annotations.single as RectangleAnnotation).rect;
      expect(rect.left, closeTo(0.2, 1e-6));
      expect(rect.top, closeTo(0.2, 1e-6));
      expect(rect.right, closeTo(0.6, 1e-6));
      expect(rect.bottom, closeTo(0.7, 1e-6));
    });

    testWidgets('a backwards drag still yields a normalized rect', (
      tester,
    ) async {
      final c = await pumpOverlay(tester, tool: AnnotationTool.rectangle);

      await tester.dragFrom(at(0.7, 0.8), at(0.3, 0.2) - at(0.7, 0.8));
      await tester.pumpAndSettle();

      final rect = (c.annotations.single as RectangleAnnotation).rect;
      expect(rect.left, closeTo(0.3, 1e-6));
      expect(rect.right, closeTo(0.7, 1e-6));
      expect(rect.width, greaterThan(0));
      expect(rect.height, greaterThan(0));
    });

    testWidgets('arrow keeps direction: start is where the drag began', (
      tester,
    ) async {
      final c = await pumpOverlay(tester, tool: AnnotationTool.arrow);

      await tester.dragFrom(at(0.8, 0.8), at(0.2, 0.3) - at(0.8, 0.8));
      await tester.pumpAndSettle();

      final arrow = c.annotations.single as ArrowAnnotation;
      expect(arrow.start.x, closeTo(0.8, 1e-6));
      expect(arrow.end.x, closeTo(0.2, 1e-6));
    });

    testWidgets('circle uses the drag bounds', (tester) async {
      final c = await pumpOverlay(tester, tool: AnnotationTool.circle);

      await tester.dragFrom(at(0.25, 0.25), at(0.75, 0.75) - at(0.25, 0.25));
      await tester.pumpAndSettle();

      expect(c.annotations.single, isA<CircleAnnotation>());
    });

    testWidgets('freehand accumulates several points', (tester) async {
      final c = await pumpOverlay(tester, tool: AnnotationTool.freehand);

      final gesture = await tester.startGesture(at(0.2, 0.2));
      for (var i = 1; i <= 5; i++) {
        await gesture.moveTo(at(0.2 + i * 0.1, 0.2 + i * 0.1));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();

      final stroke = c.annotations.single as FreehandAnnotation;
      expect(stroke.points.length, greaterThan(2));
    });

    testWidgets('a zero-length drag creates nothing', (tester) async {
      // A degenerate shape would be invisible but still swallow hits.
      final c = await pumpOverlay(tester, tool: AnnotationTool.rectangle);

      await tester.tapAt(at(0.5, 0.5));
      await tester.pumpAndSettle();

      expect(c.annotations, isEmpty);
    });

    testWidgets('a drag outside the image clamps into it', (tester) async {
      // The letterbox bands are not image; a mark there has no
      // meaningful coordinate, so it clamps to the edge.
      final c = await pumpOverlay(tester, tool: AnnotationTool.rectangle);

      await tester.dragFrom(
        const Offset(10, 100), // left band, outside the content rect
        const Offset(400, 300),
      );
      await tester.pumpAndSettle();

      final rect = (c.annotations.single as RectangleAnnotation).rect;
      expect(rect.left, 0, reason: 'clamped to the image edge');
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(1));
    });

    testWidgets('an in-progress drag does not push undo steps', (
      tester,
    ) async {
      final c = await pumpOverlay(tester, tool: AnnotationTool.rectangle);

      final gesture = await tester.startGesture(at(0.2, 0.2));
      for (var i = 1; i <= 4; i++) {
        await gesture.moveTo(at(0.2 + i * 0.1, 0.5));
        await tester.pump();
      }
      // Still mid-drag: nothing committed yet.
      expect(c.annotations, isEmpty);
      expect(c.canUndo, isFalse);

      await gesture.up();
      await tester.pumpAndSettle();

      // One drag == one undoable step.
      expect(c.annotations, hasLength(1));
      c.undo();
      expect(c.annotations, isEmpty);
    });
  });

  group('tap-to-select from any tool (WORK-0032)', () {
    testWidgets('tapping an annotation selects it even with a drawing tool active',
        (tester) async {
      final controller = AnnotationController()
        ..add(
          RectangleAnnotation(
            id: 'target',
            style: const AnnotationStyle(),
            rect: NormalizedRect(
              left: 0.2,
              top: 0.2,
              right: 0.8,
              bottom: 0.8,
            ),
          ),
        );
      // Deliberately not the tool that drew the shape -- selection must
      // win the tap regardless of which drawing tool happens to be
      // active, which is the whole point of WORK-0032.
      await pumpOverlay(
        tester,
        tool: AnnotationTool.circle,
        controller: controller,
      );

      // On the top edge -- an outlined rect is hit near its border.
      await tester.dragFrom(at(0.5, 0.2), const Offset(0, 0));
      await tester.pumpAndSettle();

      expect(controller.selectedId, 'target');
    });

    testWidgets('tapping empty space clears the selection', (tester) async {
      final controller = AnnotationController()
        ..add(
          RectangleAnnotation(
            id: 'target',
            style: const AnnotationStyle(),
            rect: NormalizedRect(
              left: 0.1,
              top: 0.1,
              right: 0.2,
              bottom: 0.2,
            ),
          ),
        );
      controller.select('target');
      await pumpOverlay(
        tester,
        tool: AnnotationTool.freehand,
        controller: controller,
      );

      await tester.dragFrom(at(0.8, 0.8), const Offset(0, 0));
      await tester.pumpAndSettle();

      expect(controller.selectedId, isNull);
    });

    testWidgets('dragging a selected annotation moves it', (tester) async {
      final controller = AnnotationController()
        ..add(
          RectangleAnnotation(
            id: 'target',
            style: const AnnotationStyle(),
            rect: NormalizedRect(
              left: 0.2,
              top: 0.2,
              right: 0.4,
              bottom: 0.4,
            ),
          ),
        );
      await pumpOverlay(
        tester,
        tool: AnnotationTool.circle,
        controller: controller,
      );

      await tester.dragFrom(at(0.3, 0.2), at(0.5, 0.4) - at(0.3, 0.2));
      await tester.pumpAndSettle();

      final moved = controller.annotations.single as RectangleAnnotation;
      expect(moved.rect.left, greaterThan(0.2),
          reason: 'the rect should have shifted right');
    });

    testWidgets('a move that would leave the image is refused', (
      tester,
    ) async {
      // Refusing beats clamping each edge independently, which would
      // squash the shape against the boundary.
      final original = NormalizedRect(
        left: 0.7,
        top: 0.4,
        right: 0.95,
        bottom: 0.6,
      );
      final controller = AnnotationController()
        ..add(
          RectangleAnnotation(
            id: 'target',
            style: const AnnotationStyle(),
            rect: original,
          ),
        );
      await pumpOverlay(
        tester,
        tool: AnnotationTool.arrow,
        controller: controller,
      );

      // Grab the left edge and shove far right, past the boundary.
      await tester.dragFrom(at(0.7, 0.5), at(1.0, 0.5) - at(0.7, 0.5));
      await tester.pumpAndSettle();

      final rect = (controller.annotations.single as RectangleAnnotation).rect;
      expect(rect.width, closeTo(original.width, 1e-9),
          reason: 'the shape must not be squashed by an out-of-range move');
      expect(rect.right, lessThanOrEqualTo(1));
    });

    testWidgets(
        'a drag starting on empty space still draws, even crossing an existing shape',
        (tester) async {
      // The other half of "selection wins the tap": a gesture that does
      // *not* start on a shape must still draw normally, including when
      // the drag path later crosses over an existing annotation -- only
      // where a gesture *starts* decides selection vs. drawing.
      final controller = AnnotationController()
        ..add(
          RectangleAnnotation(
            id: 'existing',
            style: const AnnotationStyle(),
            rect: NormalizedRect(left: 0.4, top: 0.4, right: 0.6, bottom: 0.6),
          ),
        );
      await pumpOverlay(
        tester,
        tool: AnnotationTool.rectangle,
        controller: controller,
      );

      // Starts well outside 'existing', ends well inside it.
      await tester.dragFrom(at(0.05, 0.05), at(0.5, 0.5) - at(0.05, 0.05));
      await tester.pumpAndSettle();

      expect(controller.annotations, hasLength(2),
          reason: 'a new rectangle must have been added alongside the '
              'existing one, not merely selected/moved it');
      expect(controller.selectedId, isNull,
          reason: 'drawing a new shape does not select an existing one');
    });

    testWidgets('with nothing selected, drawing behaves exactly as before',
        (tester) async {
      // Regression guard: introducing the selection hit-test ahead of
      // drawing must not change plain drawing when there is nothing to
      // select in the first place.
      final controller = await pumpOverlay(
        tester,
        tool: AnnotationTool.rectangle,
      );

      await tester.dragFrom(at(0.2, 0.2), at(0.6, 0.6) - at(0.2, 0.2));
      await tester.pumpAndSettle();

      final rect = (controller.annotations.single as RectangleAnnotation).rect;
      expect(rect.left, closeTo(0.2, 0.02));
      expect(rect.top, closeTo(0.2, 0.02));
      expect(rect.right, closeTo(0.6, 0.02));
      expect(rect.bottom, closeTo(0.6, 0.02));
    });
  });

  group('the drift guarantee', () {
    testWidgets('an annotation stays put when the overlay is resized', (
      tester,
    ) async {
      // The core promise: geometry is stored normalized, so a layout
      // change moves where a mark is *drawn* without changing what part
      // of the image it marks.
      tester.view.physicalSize = overlaySize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = AnnotationController();

      Widget build(double side) => MaterialApp(
        home: Center(
          child: SizedBox(
            width: side,
            height: side,
            child: AnnotationOverlay(
              controller: controller,
              imageSize: imageSize,
              tool: AnnotationTool.rectangle,
              idGenerator: () => 'id',
            ),
          ),
        ),
      );

      await tester.pumpWidget(build(1000));
      await tester.dragFrom(at(0.2, 0.2), at(0.6, 0.6) - at(0.2, 0.2));
      await tester.pumpAndSettle();

      final before = (controller.annotations.single as RectangleAnnotation).rect;

      // Re-lay out at a different size; the stored geometry must not move.
      await tester.pumpWidget(build(400));
      await tester.pumpAndSettle();

      final after = (controller.annotations.single as RectangleAnnotation).rect;
      expect(after, before,
          reason: 'normalized geometry must survive a resize unchanged');
    });

    testWidgets('the same normalized mark maps onto a full-resolution image', (
      tester,
    ) async {
      final controller = await pumpOverlay(
        tester,
        tool: AnnotationTool.rectangle,
      );

      await tester.dragFrom(at(0.25, 0.5), at(0.75, 0.9) - at(0.25, 0.5));
      await tester.pumpAndSettle();

      final rect = (controller.annotations.single as RectangleAnnotation).rect;

      // Project onto a 3000x6000 export of the same 1:2 image.
      const exportRect = Rect.fromLTWH(0, 0, 3000, 6000);
      final onExport = rect.toRect(exportRect);

      expect(onExport.left, closeTo(3000 * 0.25, 1));
      expect(onExport.top, closeTo(6000 * 0.5, 1));
      expect(onExport.right, closeTo(3000 * 0.75, 1));
    });
  });

  group('resizing a selected annotation', () {
    RectangleAnnotation target() => RectangleAnnotation(
      id: 'target',
      style: const AnnotationStyle(),
      rect: NormalizedRect(left: 0.3, top: 0.3, right: 0.7, bottom: 0.7),
    );

    testWidgets('dragging a corner handle resizes rather than moves', (
      tester,
    ) async {
      // The priority rule: a handle sits on the shape's edge, so without
      // it every corner drag would hit the shape and translate it.
      final controller = AnnotationController()..add(target());
      controller.select('target');
      await pumpOverlay(
        tester,
        tool: AnnotationTool.freehand,
        controller: controller,
      );

      // Grab the top-left handle and pull it outward.
      await tester.dragFrom(at(0.3, 0.3), at(0.15, 0.15) - at(0.3, 0.3));
      await tester.pumpAndSettle();

      final rect = (controller.annotations.single as RectangleAnnotation).rect;
      expect(rect.left, lessThan(0.3), reason: 'the corner should have moved');
      expect(rect.right, closeTo(0.7, 0.02),
          reason: 'the opposite corner must stay put -- a move would '
              'have shifted it too');
    });

    testWidgets('dragging the body still moves the whole shape', (
      tester,
    ) async {
      final controller = AnnotationController()..add(target());
      controller.select('target');
      await pumpOverlay(
        tester,
        tool: AnnotationTool.circle,
        controller: controller,
      );

      final before =
          (controller.annotations.single as RectangleAnnotation).rect;

      // On the top edge, midway between the corners: an outlined rect
      // is hit near its border, not in its hollow middle, and this is
      // far enough from either handle to fall through to the body.
      await tester.dragFrom(at(0.5, 0.3), at(0.6, 0.4) - at(0.5, 0.3));
      await tester.pumpAndSettle();

      final after = (controller.annotations.single as RectangleAnnotation).rect;
      expect(after.width, closeTo(before.width, 1e-6),
          reason: 'moving must not resize');
      expect(after.left, greaterThan(before.left));
    });

    testWidgets('handles only respond on the selected annotation', (
      tester,
    ) async {
      // An unselected shape has no visible handles, so a drag at its
      // corner should select it, not silently resize it.
      final controller = AnnotationController()..add(target());
      await pumpOverlay(
        tester,
        tool: AnnotationTool.arrow,
        controller: controller,
      );

      final before =
          (controller.annotations.single as RectangleAnnotation).rect;

      await tester.dragFrom(at(0.3, 0.3), const Offset(0, 0));
      await tester.pumpAndSettle();

      expect(controller.selectedId, 'target');
      expect(
        (controller.annotations.single as RectangleAnnotation).rect,
        before,
      );
    });

    testWidgets('a resize is undoable back to the original geometry', (
      tester,
    ) async {
      final controller = AnnotationController()..add(target());
      controller.select('target');
      await pumpOverlay(
        tester,
        tool: AnnotationTool.freehand,
        controller: controller,
      );
      final before =
          (controller.annotations.single as RectangleAnnotation).rect;

      await tester.dragFrom(at(0.7, 0.7), at(0.9, 0.9) - at(0.7, 0.7));
      await tester.pumpAndSettle();
      expect(
        (controller.annotations.single as RectangleAnnotation).rect,
        isNot(before),
      );

      while (controller.canUndo) {
        controller.undo();
      }
      expect(controller.annotations, isEmpty,
          reason: 'undoing everything removes the annotation itself');
    });

    testWidgets('removing the selection deletes it', (tester) async {
      final controller = AnnotationController()..add(target());
      controller.select('target');
      await pumpOverlay(
        tester,
        tool: AnnotationTool.circle,
        controller: controller,
      );

      controller.remove('target');
      await tester.pumpAndSettle();

      expect(controller.annotations, isEmpty);
      expect(controller.selectedId, isNull);
    });
  });

  group('floating shape controls (WORK-0035)', () {
    RectangleAnnotation target() => RectangleAnnotation(
      id: 'target',
      style: const AnnotationStyle(),
      rect: NormalizedRect(left: 0.3, top: 0.3, right: 0.7, bottom: 0.7),
    );

    testWidgets('no floating controls when nothing is selected', (
      tester,
    ) async {
      final controller = AnnotationController()..add(target());
      await pumpOverlay(
        tester,
        tool: AnnotationTool.rectangle,
        controller: controller,
      );

      expect(find.byTooltip('Delete'), findsNothing);
      expect(find.byTooltip('Duplicate'), findsNothing);
    });

    testWidgets('the floating x deletes the selection as one undo step', (
      tester,
    ) async {
      final controller = AnnotationController()..add(target());
      controller.select('target');
      await pumpOverlay(
        tester,
        tool: AnnotationTool.rectangle,
        controller: controller,
      );

      expect(find.byTooltip('Delete'), findsOneWidget);
      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();

      expect(controller.annotations, isEmpty);
      expect(controller.selectedId, isNull);

      controller.undo();
      expect(controller.annotations.single.id, 'target',
          reason: 'delete must be a single undo step');
    });

    testWidgets(
      'the floating +1 duplicates the selection and selects the copy',
      (tester) async {
        final controller = AnnotationController()..add(target());
        controller.select('target');
        await pumpOverlay(
          tester,
          tool: AnnotationTool.rectangle,
          controller: controller,
        );

        expect(find.byTooltip('Duplicate'), findsOneWidget);
        await tester.tap(find.byTooltip('Duplicate'));
        await tester.pumpAndSettle();

        expect(controller.annotations, hasLength(2));
        expect(controller.selectedId, isNot('target'),
            reason: 'the new copy should be selected, not the original');

        controller.undo();
        expect(controller.annotations, hasLength(1),
            reason: 'duplicate must be a single undo step');
      },
    );

    testWidgets(
      'tapping the floating controls does not also draw or move a shape',
      (tester) async {
        // The controls are siblings of the drawing GestureDetector, not
        // descendants of it -- a tap that lands on the x/+1 must not
        // also register as a tap-to-select or a body drag underneath.
        final controller = AnnotationController()..add(target());
        controller.select('target');
        await pumpOverlay(
          tester,
          tool: AnnotationTool.rectangle,
          controller: controller,
        );

        final before =
            (controller.annotations.single as RectangleAnnotation).rect;
        await tester.tap(find.byTooltip('Duplicate'));
        await tester.pumpAndSettle();

        final original = controller.annotations.firstWhere(
          (a) => a.id == 'target',
        ) as RectangleAnnotation;
        expect(original.rect, before,
            reason: 'the original must not have moved or resized');
      },
    );
  });

  group('text annotations (WORK-0034)', () {
    testWidgets('tapping empty space with the text tool opens a field, '
        'not a drag draft', (tester) async {
      final c = await pumpOverlay(tester, tool: AnnotationTool.text);

      await tester.tapAt(at(0.3, 0.3));
      await tester.pump();

      expect(find.byType(TextField), findsOneWidget);
      expect(c.annotations, isEmpty,
          reason: 'nothing commits until the field is submitted');
    });

    testWidgets('submitting text commits a TextAnnotation and selects it', (
      tester,
    ) async {
      final c = await pumpOverlay(tester, tool: AnnotationTool.text);

      await tester.tapAt(at(0.3, 0.3));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(c.annotations, hasLength(1));
      final placed = c.annotations.single as TextAnnotation;
      expect(placed.text, 'hello');
      expect(placed.position.x, closeTo(0.3, 0.05));
      expect(placed.position.y, closeTo(0.3, 0.05));
      expect(c.selectedId, placed.id);
      expect(find.byType(TextField), findsNothing,
          reason: 'the field closes once committed');
    });

    testWidgets('an empty submit discards without creating an annotation', (
      tester,
    ) async {
      final c = await pumpOverlay(tester, tool: AnnotationTool.text);

      await tester.tapAt(at(0.3, 0.3));
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(c.annotations, isEmpty);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('a whitespace-only submit is treated as empty', (
      tester,
    ) async {
      final c = await pumpOverlay(tester, tool: AnnotationTool.text);

      await tester.tapAt(at(0.3, 0.3));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '   ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(c.annotations, isEmpty);
    });

    testWidgets(
      'committing text is undoable, and undoing removes it entirely',
      (tester) async {
        final c = await pumpOverlay(tester, tool: AnnotationTool.text);

        await tester.tapAt(at(0.3, 0.3));
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'hello');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();

        expect(c.annotations, hasLength(1));
        c.undo();
        expect(c.annotations, isEmpty);
      },
    );

    testWidgets(
      'tapping an already-selected text annotation re-opens the field '
      'pre-filled with its current text',
      (tester) async {
        const existing = TextAnnotation(
          id: 'target',
          style: AnnotationStyle(),
          position: NormalizedPoint(0.3, 0.3),
          text: 'original',
        );
        final controller = AnnotationController()..add(existing);
        controller.select('target');
        await pumpOverlay(
          tester,
          tool: AnnotationTool.rectangle,
          controller: controller,
        );

        await tester.tapAt(at(0.365, 0.309));
        await tester.pump();

        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.controller?.text, 'original');
      },
    );

    testWidgets(
      'submitting a re-edit updates the text as one undo step, keeping '
      'position and style',
      (tester) async {
        const existing = TextAnnotation(
          id: 'target',
          style: AnnotationStyle(color: Color(0xFF00FF00)),
          position: NormalizedPoint(0.3, 0.3),
          text: 'original',
        );
        final controller = AnnotationController()..add(existing);
        controller.select('target');
        await pumpOverlay(
          tester,
          tool: AnnotationTool.rectangle,
          controller: controller,
        );

        await tester.tapAt(at(0.365, 0.309));
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'updated');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();

        expect(controller.annotations, hasLength(1),
            reason: 'editing must not create a second annotation');
        final edited = controller.annotations.single as TextAnnotation;
        expect(edited.text, 'updated');
        expect(edited.position, existing.position);
        expect(edited.style, existing.style);

        controller.undo();
        expect(
          (controller.annotations.single as TextAnnotation).text,
          'original',
          reason: 'a re-edit must be a single undo step',
        );
      },
    );

    testWidgets('text can be deleted via the floating x, undoably', (
      tester,
    ) async {
      const existing = TextAnnotation(
        id: 'target',
        style: AnnotationStyle(),
        position: NormalizedPoint(0.3, 0.3),
        text: 'hello',
      );
      final controller = AnnotationController()..add(existing);
      controller.select('target');
      await pumpOverlay(
        tester,
        tool: AnnotationTool.rectangle,
        controller: controller,
      );

      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();

      expect(controller.annotations, isEmpty);
      controller.undo();
      expect(controller.annotations.single.id, 'target');
    });

    testWidgets('text can be rotated via the rotation handle', (
      tester,
    ) async {
      const existing = TextAnnotation(
        id: 'target',
        style: AnnotationStyle(),
        position: NormalizedPoint(0.3, 0.3),
        text: 'hello',
      );
      final controller = AnnotationController()..add(existing);
      controller.select('target');
      await pumpOverlay(
        tester,
        tool: AnnotationTool.rectangle,
        controller: controller,
      );

      final rotateHandle = gripPositionsInPixels(
        existing,
        Rect.fromLTWH(
          contentLeft,
          0,
          contentWidth,
          overlaySize.height,
        ),
        ImageTransform.identity,
      )[AnnotationGrip.rotate]!;

      final gesture = await tester.startGesture(rotateHandle);
      await gesture.moveBy(const Offset(0, -60));
      await gesture.up();
      await tester.pumpAndSettle();

      final rotated = controller.annotations.single as TextAnnotation;
      expect(rotated.rotation, isNot(0.0));
      expect(rotated.position, existing.position,
          reason: 'rotating must not move the anchor position');
    });
  });

  group('image annotations (WORK-0037)', () {
    ImageAnnotation image() => ImageAnnotation(
      id: 'target',
      style: const AnnotationStyle(),
      reference: 'never-resolved',
      rect: NormalizedRect(left: 0.3, top: 0.3, right: 0.7, bottom: 0.7),
    );

    testWidgets(
      'is selectable and movable with no ImageAnnotationCache at all',
      (tester) async {
        final controller = AnnotationController()..add(image());
        await pumpOverlay(
          tester,
          tool: AnnotationTool.rectangle,
          controller: controller,
        );

        await tester.tapAt(at(0.5, 0.5));
        await tester.pumpAndSettle();
        expect(controller.selectedId, 'target');

        await tester.dragFrom(at(0.5, 0.5), at(0.6, 0.6) - at(0.5, 0.5));
        await tester.pumpAndSettle();

        final moved = controller.annotations.single as ImageAnnotation;
        expect(moved.rect.left, greaterThan(0.3));
      },
    );

    testWidgets(
      'is selectable and movable while its image is still loading',
      (tester) async {
        final cache = ImageAnnotationCache(
          resolver: (ref) => Completer<Uint8List>().future, // never resolves
        );
        addTearDown(cache.dispose);
        final controller = AnnotationController(imageCache: cache)
          ..add(image());
        // The add() above already called cache.request(); confirm it is
        // genuinely still loading, not a test that accidentally proves
        // nothing.
        expect(
          cache.entryFor('never-resolved')?.state,
          ImageAnnotationLoadState.loading,
        );

        await pumpOverlay(
          tester,
          tool: AnnotationTool.rectangle,
          controller: controller,
        );

        await tester.tapAt(at(0.5, 0.5));
        await tester.pumpAndSettle();
        expect(controller.selectedId, 'target');

        await tester.dragFrom(at(0.5, 0.5), at(0.6, 0.6) - at(0.5, 0.5));
        await tester.pumpAndSettle();

        final moved = controller.annotations.single as ImageAnnotation;
        expect(moved.rect.left, greaterThan(0.3));
      },
    );

    testWidgets('corner-drag resizes the placement rect', (tester) async {
      final controller = AnnotationController()..add(image());
      controller.select('target');
      await pumpOverlay(
        tester,
        tool: AnnotationTool.rectangle,
        controller: controller,
      );

      // Top-left corner is at (0.3, 0.3).
      await tester.dragFrom(at(0.3, 0.3), at(0.1, 0.1) - at(0.3, 0.3));
      await tester.pumpAndSettle();

      final resized = controller.annotations.single as ImageAnnotation;
      expect(resized.rect.left, closeTo(0.1, 0.05));
      expect(resized.rect.right, closeTo(0.7, 1e-6),
          reason: 'the opposite corner must not move');
    });

    testWidgets('can be deleted via the floating x, undoably', (
      tester,
    ) async {
      final controller = AnnotationController()..add(image());
      controller.select('target');
      await pumpOverlay(
        tester,
        tool: AnnotationTool.rectangle,
        controller: controller,
      );

      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();

      expect(controller.annotations, isEmpty);
      controller.undo();
      expect(controller.annotations.single.id, 'target');
    });

    testWidgets('can be duplicated via the floating +1', (tester) async {
      final controller = AnnotationController()..add(image());
      controller.select('target');
      await pumpOverlay(
        tester,
        tool: AnnotationTool.rectangle,
        controller: controller,
      );

      await tester.tap(find.byTooltip('Duplicate'));
      await tester.pumpAndSettle();

      expect(controller.annotations, hasLength(2));
      final duplicate = controller.annotations.last as ImageAnnotation;
      expect(duplicate.reference, 'never-resolved');
    });
  });
}
