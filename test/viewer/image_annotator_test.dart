import 'dart:typed_data';

import 'package:d3_image_annotator/d3_image_annotator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 1x1 transparent PNG, so tests never touch the filesystem or
/// network. Only the geometry matters here, not the pixels.
final _pngBytes = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

void main() {
  // A 1000x1000 viewport showing a 500x1000 image: under contain the
  // image occupies a centred 500-wide column, content rect
  // (250,0)-(750,1000). Not square, so an axis mix-up would show.
  const viewport = Size(1000, 1000);
  const imageSize = Size(500, 1000);
  const contentLeft = 250.0;
  const contentWidth = 500.0;

  Offset at(double nx, double ny) =>
      Offset(contentLeft + nx * contentWidth, ny * viewport.height);

  Future<AnnotationController> pump(
    WidgetTester tester, {
    AnnotationTool tool = AnnotationTool.rectangle,
    TransformationController? transform,
    bool enableZoom = true,
    AnnotationController? controller,
  }) async {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Only dispose what this helper created; a caller-supplied
    // controller is the caller's to clean up.
    final AnnotationController c;
    if (controller != null) {
      c = controller;
    } else {
      c = AnnotationController();
      addTearDown(c.dispose);
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: viewport.width,
            height: viewport.height,
            child: D3ImageAnnotator(
              image: MemoryImage(_pngBytes),
              imageSize: imageSize,
              controller: c,
              tool: tool,
              enableZoom: enableZoom,
              transformationController: transform,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return c;
  }

  // Flutter's pan recognizer swallows the first ~18 logical pixels as
  // touch slop before reporting onStart, so a drag's recorded origin
  // trails its true origin by that much. That is real behaviour, not a
  // coordinate error -- these tests allow for it rather than pretending
  // it is absent. At 500px of content width it is 0.036 normalized.
  const slopTolerance = 0.05;

  group('drawing', () {
    testWidgets('one finger draws at the dragged normalized spot', (
      tester,
    ) async {
      final c = await pump(tester);

      await tester.dragFrom(at(0.2, 0.2), at(0.6, 0.7) - at(0.2, 0.2));
      await tester.pumpAndSettle();

      expect(c.annotations, hasLength(1));
      final rect = (c.annotations.single as RectangleAnnotation).rect;
      expect(rect.left, closeTo(0.2, slopTolerance));
      // The drag *end* is exact -- slop only delays the start.
      expect(rect.right, closeTo(0.6, 1e-6));
      expect(rect.bottom, closeTo(0.7, 1e-6));
    });

    testWidgets('drawing still works with zoom disabled', (tester) async {
      final c = await pump(tester, enableZoom: false);

      await tester.dragFrom(at(0.3, 0.3), at(0.7, 0.7) - at(0.3, 0.3));
      await tester.pumpAndSettle();

      expect(c.annotations, hasLength(1));
    });
  });

  group('zoom', () {
    testWidgets('two fingers zoom instead of drawing', (tester) async {
      // The whole point of the custom recognizer: a plain
      // GestureDetector would win the arena on the first pointer and
      // swallow the pinch, so this would draw a rectangle and never
      // zoom.
      final transform = TransformationController();
      addTearDown(transform.dispose);
      final c = await pump(tester, transform: transform);

      final centre = at(0.5, 0.5);
      final g1 = await tester.startGesture(centre - const Offset(50, 0));
      final g2 = await tester.startGesture(centre + const Offset(50, 0));
      await g1.moveBy(const Offset(-100, 0));
      await g2.moveBy(const Offset(100, 0));
      await tester.pump();
      await g1.up();
      await g2.up();
      await tester.pumpAndSettle();

      expect(
        transform.value.getMaxScaleOnAxis(),
        greaterThan(1.01),
        reason: 'a two-finger spread must zoom',
      );
      expect(
        c.annotations,
        isEmpty,
        reason: 'a pinch must not leave an annotation behind',
      );
    });

    testWidgets('a mark drawn while zoomed lands on the right image spot', (
      tester,
    ) async {
      // The claim the whole design rests on. Zoom in, draw, and the
      // stored geometry must describe the same feature of the *image*
      // regardless of what the viewport was showing.
      final transform = TransformationController();
      addTearDown(transform.dispose);

      // 2x about the origin: image-space (x,y) appears at (2x, 2y).
      transform.value = Matrix4.identity()..scaleByDouble(2.0, 2.0, 1.0, 1.0);
      final c = await pump(tester, transform: transform);

      // Tap where image-normalized (0.15, 0.15) now appears on screen.
      final start = at(0.15, 0.15) * 2;
      final end = at(0.3, 0.3) * 2;
      await tester.dragFrom(start, end - start);
      await tester.pumpAndSettle();

      expect(c.annotations, hasLength(1));
      final rect = (c.annotations.single as RectangleAnnotation).rect;
      // The end point is exact and is the real evidence here: under a
      // 2x transform the drag ended where image-normalized 0.3 appears
      // on screen, and 0.3 is what got stored.
      expect(rect.right, closeTo(0.3, 1e-6),
          reason: 'zoom must not shift where the mark is stored');
      expect(rect.left, closeTo(0.15, slopTolerance));
    });

    testWidgets('existing annotations survive a zoom unchanged', (
      tester,
    ) async {
      final transform = TransformationController();
      addTearDown(transform.dispose);
      final c = await pump(tester, transform: transform);

      await tester.dragFrom(at(0.2, 0.2), at(0.6, 0.6) - at(0.2, 0.2));
      await tester.pumpAndSettle();
      final before = (c.annotations.single as RectangleAnnotation).rect;

      transform.value = Matrix4.identity()..scaleByDouble(3.0, 3.0, 1.0, 1.0);
      await tester.pumpAndSettle();

      final after = (c.annotations.single as RectangleAnnotation).rect;
      expect(after, before,
          reason: 'geometry is normalized; zooming is a view change only');
    });
  });

  group('gesture ownership', () {
    testWidgets('there is no InteractiveViewer to compete for pointers', (
      tester,
    ) async {
      // Pins the architecture, because the behavioural version of this
      // is exactly the test that gave a false pass: two recognizers
      // cannot share these pointers, so the overlay owns them all and
      // the transform is driven from the forwarded scale callbacks.
      await pump(tester);

      expect(find.byType(InteractiveViewer), findsNothing);
      expect(find.byType(AnnotationOverlay), findsOneWidget);
    });
  });

  group('image placement and annotation placement agree', () {
    test('computeImageContentRect matches what BoxFit.contain produces', () {
      // The viewer paints the image with BoxFit and places annotations
      // with computeImageContentRect. If those disagree about where the
      // image sits, every mark lands off-target. Checked against the
      // BoxFit maths directly rather than trusting they coincide.
      const viewportSize = Size(1000, 1000);
      const image = Size(500, 1000);

      final rect = computeImageContentRect(
        widgetSize: viewportSize,
        contentSize: image,
        fit: ImageFit.contain,
      );

      final applied = applyBoxFit(BoxFit.contain, image, viewportSize);
      expect(rect.width, closeTo(applied.destination.width, 1e-6));
      expect(rect.height, closeTo(applied.destination.height, 1e-6));
      // ...and centred, which is what BoxFit does with the leftover.
      expect(rect.center.dx, closeTo(viewportSize.width / 2, 1e-6));
      expect(rect.center.dy, closeTo(viewportSize.height / 2, 1e-6));
    });
  });

  group('annotations scale with the image, not the screen', () {
    test('stroke width is a fraction of the image, so it scales', () {
      // A mark is a property of the photo: its weight relative to the
      // thing it marks must not change with zoom. Resolving against a
      // larger canvas yields a proportionally larger stroke.
      const style = AnnotationStyle(strokeWidth: 0.01);

      expect(style.resolveStrokeWidth(1000), closeTo(10, 1e-9));
      expect(style.resolveStrokeWidth(4000), closeTo(40, 1e-9));
      expect(
        style.resolveStrokeWidth(4000) / style.resolveStrokeWidth(1000),
        closeTo(4, 1e-9),
        reason: 'stroke must scale with the canvas, not stay pixel-constant',
      );
    });
  });

  group('drawing on a transformed image', () {
    /// The guarantee that makes rotate/crop safe: a user draws on the
    /// *transformed* view, and the mark must be stored against the
    /// *original* image. If these disagree, every annotation shifts the
    /// moment a photo is rotated.
    testWidgets('a mark drawn on a rotated view stores original coords', (
      tester,
    ) async {
      final rotated = AnnotationController()..rotateClockwise();
      addTearDown(rotated.dispose);
      await pump(tester, controller: rotated);

      // Drag across the middle of the rotated view.
      await tester.dragFrom(at(0.3, 0.3), at(0.7, 0.7) - at(0.3, 0.3));
      await tester.pumpAndSettle();

      expect(rotated.annotations, hasLength(1));
      final rect = (rotated.annotations.single as RectangleAnnotation).rect;

      // Stored geometry must be valid original-image coordinates, not
      // view coordinates: still in range, and a real area.
      expect(rect.left, inInclusiveRange(0, 1));
      expect(rect.right, inInclusiveRange(0, 1));
      expect(rect.width, greaterThan(0));
      expect(rect.height, greaterThan(0));
    });

    testWidgets('what is drawn on a rotated view round-trips to the view', (
      tester,
    ) async {
      final rotated = AnnotationController()..rotateClockwise();
      addTearDown(rotated.dispose);
      await pump(tester, controller: rotated);

      await tester.dragFrom(at(0.25, 0.25), at(0.6, 0.6) - at(0.25, 0.25));
      await tester.pumpAndSettle();

      final stored = (rotated.annotations.single as RectangleAnnotation).rect;

      // Mapping the stored corners forward through the same transform
      // should land back near where the drag ended in view space.
      final mappedEnd = rotated.transform.mapPoint(
        NormalizedPoint(stored.right, stored.bottom),
      );
      final mappedStart = rotated.transform.mapPoint(
        NormalizedPoint(stored.left, stored.top),
      );

      // The drag covered view-space 0.25..0.6 on both axes; the mapped
      // corners should span roughly that, in some corner order.
      final xs = [mappedStart.x, mappedEnd.x]..sort();
      expect(xs.first, closeTo(0.25, 0.08));
      expect(xs.last, closeTo(0.6, 0.08));
    });

    testWidgets('existing marks are unchanged by rotating', (tester) async {
      final c = AnnotationController();
      addTearDown(c.dispose);
      await pump(tester, controller: c);

      await tester.dragFrom(at(0.2, 0.2), at(0.6, 0.6) - at(0.2, 0.2));
      await tester.pumpAndSettle();
      final before = (c.annotations.single as RectangleAnnotation).rect;

      c.rotateClockwise();
      await tester.pumpAndSettle();

      final after = (c.annotations.single as RectangleAnnotation).rect;
      expect(after, before,
          reason: 'geometry is stored against the original image');
    });

    testWidgets('cropping does not delete marks outside the crop', (
      tester,
    ) async {
      // Clipping, not deleting: widening the crop must bring them back.
      final c = AnnotationController();
      addTearDown(c.dispose);
      await pump(tester, controller: c);

      await tester.dragFrom(at(0.05, 0.05), at(0.2, 0.2) - at(0.05, 0.05));
      await tester.pumpAndSettle();
      expect(c.annotations, hasLength(1));

      c.crop(NormalizedRect(left: 0.6, top: 0.6, right: 1, bottom: 1));
      await tester.pumpAndSettle();
      expect(c.annotations, hasLength(1),
          reason: 'a mark outside the crop is clipped, never removed');

      c.crop(null);
      await tester.pumpAndSettle();
      expect(c.annotations, hasLength(1));
    });
  });
}
