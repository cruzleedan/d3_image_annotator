import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A 400x400 content rect at the origin, so normalized 0.5 is pixel 200
  // and the arithmetic stays checkable by hand.
  const contentRect = Rect.fromLTWH(0, 0, 400, 400);

  Future<List<NormalizedRect>> pumpCrop(
    WidgetTester tester, {
    required NormalizedRect initial,
  }) async {
    tester.view.physicalSize = const Size(400, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final changes = <NormalizedRect>[];
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 400,
          child: CropOverlay(
            contentRect: contentRect,
            initialCrop: initial,
            onChanged: changes.add,
          ),
        ),
      ),
    );
    return changes;
  }

  final full = NormalizedRect(left: 0, top: 0, right: 1, bottom: 1);
  final centre = NormalizedRect(
    left: 0.25,
    top: 0.25,
    right: 0.75,
    bottom: 0.75,
  );

  group('corner handles', () {
    testWidgets('dragging the top-left corner shrinks from that corner', (
      tester,
    ) async {
      final changes = await pumpCrop(tester, initial: full);

      // Grab (0,0) and drag inward by a quarter of the frame.
      await tester.dragFrom(Offset.zero, const Offset(100, 100));
      await tester.pumpAndSettle();

      expect(changes, isNotEmpty);
      final result = changes.last;
      expect(result.left, closeTo(0.25, 0.06));
      expect(result.top, closeTo(0.25, 0.06));
      expect(result.right, closeTo(1, 1e-9), reason: 'far edge must not move');
      expect(result.bottom, closeTo(1, 1e-9));
    });

    testWidgets('dragging the bottom-right corner moves only that corner', (
      tester,
    ) async {
      final changes = await pumpCrop(tester, initial: full);

      // A pixel inside the edge: (400,400) is exactly the widget
      // boundary and lands outside its hit area.
      await tester.dragFrom(const Offset(399, 399), const Offset(-100, -100));
      await tester.pumpAndSettle();

      final result = changes.last;
      expect(result.left, closeTo(0, 1e-9));
      expect(result.top, closeTo(0, 1e-9));
      expect(result.right, closeTo(0.75, 0.06));
      expect(result.bottom, closeTo(0.75, 0.06));
    });

    testWidgets('a corner cannot be dragged past the opposite edge', (
      tester,
    ) async {
      // Without a minimum the frame would invert or collapse to nothing,
      // leaving no image and no handle big enough to grab back.
      final changes = await pumpCrop(tester, initial: full);

      await tester.dragFrom(Offset.zero, const Offset(600, 600));
      await tester.pumpAndSettle();

      final result = changes.last;
      expect(result.width, greaterThan(0));
      expect(result.height, greaterThan(0));
      expect(result.left, lessThan(result.right));
    });

    testWidgets('a corner cannot be dragged outside the image', (
      tester,
    ) async {
      final changes = await pumpCrop(tester, initial: centre);

      await tester.dragFrom(const Offset(100, 100), const Offset(-300, -300));
      await tester.pumpAndSettle();

      final result = changes.last;
      expect(result.left, greaterThanOrEqualTo(0));
      expect(result.top, greaterThanOrEqualTo(0));
    });
  });

  group('moving the frame', () {
    testWidgets('dragging the interior moves it without resizing', (
      tester,
    ) async {
      final changes = await pumpCrop(tester, initial: centre);

      await tester.dragFrom(const Offset(200, 200), const Offset(40, 40));
      await tester.pumpAndSettle();

      final result = changes.last;
      expect(result.width, closeTo(centre.width, 1e-6),
          reason: 'moving must not resize');
      expect(result.height, closeTo(centre.height, 1e-6));
      expect(result.left, greaterThan(centre.left));
    });

    testWidgets('a move that would leave the image keeps its size', (
      tester,
    ) async {
      // Clamping each edge independently would squash the frame against
      // the boundary instead of stopping it.
      final changes = await pumpCrop(tester, initial: centre);

      await tester.dragFrom(const Offset(200, 200), const Offset(400, 400));
      await tester.pumpAndSettle();

      final result = changes.last;
      expect(result.width, closeTo(centre.width, 1e-6));
      expect(result.height, closeTo(centre.height, 1e-6));
      expect(result.right, lessThanOrEqualTo(1));
      expect(result.bottom, lessThanOrEqualTo(1));
    });
  });

  group('gesture ownership', () {
    testWidgets('a drag outside the frame does nothing', (tester) async {
      final changes = await pumpCrop(tester, initial: centre);

      // Well outside the centred frame, and away from its corners.
      await tester.dragFrom(const Offset(20, 380), const Offset(10, -10));
      await tester.pumpAndSettle();

      expect(changes, isEmpty);
    });

    testWidgets('the overlay reports every intermediate frame', (
      tester,
    ) async {
      // A host may want live dimensions while dragging, not just a
      // final value.
      final changes = await pumpCrop(tester, initial: full);

      final gesture = await tester.startGesture(Offset.zero);
      for (var i = 0; i < 4; i++) {
        await gesture.moveBy(const Offset(20, 20));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(changes.length, greaterThan(1));
    });
  });
}
